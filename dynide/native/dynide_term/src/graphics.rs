//! Kitty graphics ops for the blitter, ported from herdr's
//! `src/kitty_graphics.rs` (encodings), `src/client/frame_output.rs` (probe,
//! `t=t` rewrite) and `src/platform/unix_image_files.rs` (temp-file ledger).
//!
//! Policy-free: the ops say what to upload, place and delete. The one choice
//! made here is the mechanism fallback: a `File` upload goes direct while the
//! temp-file transport is not known to work.

use std::collections::HashMap;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const CHUNK_BYTES: usize = 3072;
/// A file the host has not consumed by then disables the transport.
const CONSUMPTION_TIMEOUT: Duration = Duration::from_secs(10);
/// Unconsumed bytes we keep in /tmp; beyond it uploads go direct.
const MAX_PENDING_BYTES: usize = 64 << 20;
/// herdr's per-image cap for `t=t`; larger images go direct.
const MAX_IMAGE_BYTES: usize = 16 << 20;
const FILE_PREFIX: &str = "tty-graphics-protocol-";
/// Per-process subdir of the per-user dir: `dynide-gfx-<pid>`.
const DIR_PREFIX: &str = "dynide-gfx-";
/// The writer unlinks its files older than this, consumed or not.
const MAX_FILE_AGE: Duration = Duration::from_secs(60);
/// Ghostty accepts `t=t` only under /tmp, whatever TMPDIR says.
pub const ROOT: &str = "/tmp";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Medium {
    Direct,
    File,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Upload {
        id: u32,
        /// Kitty `f=`: 24 rgb, 32 rgba, 100 png.
        format: u32,
        width: u32,
        height: u32,
        data: Vec<u8>,
        medium: Medium,
    },
    Place {
        id: u32,
        placement: u32,
        x: u16,
        y: u16,
        cols: u32,
        rows: u32,
        src: (u32, u32, u32, u32),
        off: (u32, u32),
        z: i32,
    },
    DeletePlacement(u32, u32),
    DeleteImage(u32),
    DeleteAll,
}

/// `Tty.stats/1` `file_transport`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, rustler::NifUnitEnum)]
pub enum Transport {
    #[default]
    Unknown,
    Probing,
    Ok,
    Disabled,
}

/// Standard base64 with padding.
pub fn base64(out: &mut Vec<u8>, data: &[u8]) {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = u32::from(b[0]) << 16 | u32::from(b[1]) << 8 | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize]);
            } else {
                out.push(b'=');
            }
        }
    }
}

fn write_apc(out: &mut Vec<u8>, control: &str, payload: &[u8]) {
    let _ = write!(out, "\x1b_G{control};");
    base64(out, payload);
    out.extend_from_slice(b"\x1b\\");
}

/// herdr `write_kitty_data`: the control on the first chunk, `m=1` on all
/// but the last.
fn write_chunked(out: &mut Vec<u8>, control: &str, data: &[u8]) {
    let count = data.len().div_ceil(CHUNK_BYTES);
    for (i, chunk) in data.chunks(CHUNK_BYTES).enumerate() {
        let more = u8::from(i + 1 < count);
        if i == 0 {
            write_apc(out, &format!("{control},m={more}"), chunk);
        } else {
            write_apc(out, &format!("m={more}"), chunk);
        }
    }
}

/// Merges a superseded frame's ops into the replacing frame's, dropping
/// superseded ops a later op makes moot, so a stalled host keeps a bounded
/// backlog. Dropped: superseded ops before the last `DeleteAll`; superseded
/// places when the new frame places (places replay every frame); a
/// superseded upload of X together with the next delete of X (the image
/// never reached the host; relies on uploads of X only while X is absent
/// there, as Render's cache does). Order is kept.
/// ponytail: the upload backlog is bounded only by distinct live images.
pub fn coalesce(mut old: Vec<Op>, mut new: Vec<Op>) -> Vec<Op> {
    let superseded = old.len();
    let new_places = new.iter().any(|op| matches!(op, Op::Place { .. }));
    old.append(&mut new);
    let mut keep = vec![true; old.len()];
    let mut later_delete_all = false;
    // Image id -> index of the nearest later DeleteImage not yet paired.
    let mut next_delete = HashMap::new();
    for (i, op) in old.iter().enumerate().rev() {
        let is_old = i < superseded;
        match op {
            Op::DeleteAll => {
                keep[i] = !(is_old && later_delete_all);
                later_delete_all = true;
            }
            _ if is_old && later_delete_all => keep[i] = false,
            Op::Place { .. } => keep[i] = !(is_old && new_places),
            Op::DeleteImage(id) => {
                next_delete.insert(*id, i);
            }
            Op::Upload { id, .. } => {
                if let Some(j) = next_delete.remove(id) {
                    if is_old {
                        keep[i] = false;
                        keep[j] = false;
                    }
                }
            }
            Op::DeletePlacement(..) => {}
        }
    }
    old.into_iter()
        .zip(keep)
        .filter_map(|(op, keep)| keep.then_some(op))
        .collect()
}

/// Encodes `ops` in order. `now` is injected for the consumption timeout.
pub fn encode(out: &mut Vec<u8>, ops: &[Op], files: &mut Files, now: Instant) {
    for op in ops {
        match op {
            Op::Upload {
                id,
                format,
                width,
                height,
                data,
                medium,
            } => {
                let control = format!("a=t,t=d,f={format},s={width},v={height},i={id},q=2");
                let path = match medium {
                    Medium::File => files.prepare(out, data, now),
                    Medium::Direct => None,
                };
                match path {
                    Some(path) => write_apc(
                        out,
                        &control.replace(",t=d,", ",t=t,"),
                        path.as_os_str().as_encoded_bytes(),
                    ),
                    None => write_chunked(out, &control, data),
                }
            }
            Op::Place {
                id,
                placement,
                x,
                y,
                cols,
                rows,
                src: (sx, sy, sw, sh),
                off: (xo, yo),
                z,
            } => {
                let _ = write!(out, "\x1b[{};{}H", u32::from(*y) + 1, u32::from(*x) + 1);
                let _ = write!(
                    out,
                    "\x1b_Ga=p,i={id},p={placement},c={cols},r={rows},z={z},C=1,q=2"
                );
                for (key, value) in [
                    ("x", sx),
                    ("y", sy),
                    ("w", sw),
                    ("h", sh),
                    ("X", xo),
                    ("Y", yo),
                ] {
                    if *value > 0 {
                        let _ = write!(out, ",{key}={value}");
                    }
                }
                out.extend_from_slice(b";\x1b\\");
            }
            Op::DeletePlacement(id, placement) => {
                let _ = write!(out, "\x1b_Ga=d,d=i,i={id},p={placement},q=2;\x1b\\");
            }
            Op::DeleteImage(id) => {
                let _ = write!(out, "\x1b_Ga=d,d=I,i={id},q=2;\x1b\\");
            }
            Op::DeleteAll => out.extend_from_slice(b"\x1b_Ga=d,d=A,q=2;\x1b\\"),
        }
    }
}

/// Names are unique across every ledger in the process.
static NEXT_FILE: AtomicU64 = AtomicU64::new(0);

/// Temp-file transport (`t=t`): files we wrote that the host deletes once
/// read. A vanished file is consumed; one that lingers past
/// `CONSUMPTION_TIMEOUT`, or any I/O error, disables the transport.
pub struct Files {
    root: PathBuf,
    dir: Option<PathBuf>,
    state: Transport,
    /// The probe while `Probing`, then every published file not yet consumed.
    pending: Vec<(PathBuf, usize, Instant)>,
}

impl Default for Files {
    fn default() -> Self {
        Self::at(ROOT)
    }
}

impl Files {
    pub fn at(root: impl Into<PathBuf>) -> Self {
        Files {
            root: root.into(),
            dir: None,
            state: Transport::Unknown,
            pending: Vec::new(),
        }
    }

    pub fn state(&self) -> Transport {
        self.state
    }

    /// The path to send with `t=t`, or `None` to send this upload direct.
    /// The first call writes the probe APC to `out`.
    fn prepare(&mut self, out: &mut Vec<u8>, data: &[u8], now: Instant) -> Option<PathBuf> {
        self.reap(now);
        match self.state {
            Transport::Unknown => {
                // herdr's probe: a 1x1 rgba query the host answers nothing to (q=2).
                match self.init().and_then(|()| self.write_file(&[0; 4], now)) {
                    Ok(probe) => {
                        write_apc(
                            out,
                            "a=q,t=t,f=32,s=1,v=1,i=1,q=2",
                            probe.as_os_str().as_encoded_bytes(),
                        );
                        self.state = Transport::Probing;
                    }
                    Err(_) => self.state = Transport::Disabled,
                }
                None
            }
            Transport::Ok => {
                let queued: usize = self.pending.iter().map(|(_, n, _)| n).sum();
                if data.is_empty()
                    || data.len() > MAX_IMAGE_BYTES
                    || queued + data.len() > MAX_PENDING_BYTES
                {
                    return None;
                }
                match self.write_file(data, now) {
                    Ok(path) => Some(path),
                    Err(_) => {
                        // Do not retry failing I/O on every upload.
                        self.state = Transport::Disabled;
                        None
                    }
                }
            }
            Transport::Probing | Transport::Disabled => None,
        }
    }

    fn reap(&mut self, now: Instant) {
        // Permission or I/O errors are not evidence of consumption.
        self.pending.retain(|(path, _, _)| {
            !matches!(fs::symlink_metadata(path), Err(e) if e.kind() == io::ErrorKind::NotFound)
        });
        if self.state == Transport::Probing && self.pending.is_empty() {
            self.state = Transport::Ok;
        }
        if self
            .pending
            .iter()
            .any(|(_, _, at)| now.saturating_duration_since(*at) >= CONSUMPTION_TIMEOUT)
        {
            self.state = Transport::Disabled;
        }
        // After the timeout check, so an old file still disables the transport first.
        self.pending.retain(|(path, _, at)| {
            let old = now.saturating_duration_since(*at) >= MAX_FILE_AGE;
            if old {
                let _ = fs::remove_file(path);
            }
            !old
        });
    }

    /// Creates (or checks) `<root>/dynide-kitty-<euid>/dynide-gfx-<pid>/`.
    fn init(&mut self) -> io::Result<()> {
        let user = user_dir(&self.root);
        trusted(&user, true)?;
        let dir = process_dir(&self.root);
        trusted(&dir, true)?;
        self.dir = Some(dir);
        Ok(())
    }

    fn write_file(&mut self, data: &[u8], now: Instant) -> io::Result<PathBuf> {
        let dir = self
            .dir
            .as_deref()
            .ok_or_else(|| io::Error::other("no dir"))?;
        let path = dir.join(format!(
            "{FILE_PREFIX}{}-{}",
            std::process::id(),
            NEXT_FILE.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&path)?;
        if let Err(e) = file.write_all(data) {
            drop(file);
            let _ = fs::remove_file(&path);
            return Err(e);
        }
        self.pending.push((path.clone(), data.len(), now));
        Ok(path)
    }
}

impl Drop for Files {
    fn drop(&mut self) {
        for (path, _, _) in self.pending.drain(..) {
            let _ = fs::remove_file(path);
        }
        // Only when empty: another ledger of this process may share the dir.
        if let Some(dir) = &self.dir {
            let _ = fs::remove_dir(dir);
        }
    }
}

fn user_dir(root: &Path) -> PathBuf {
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    root.join(format!("dynide-kitty-{euid}"))
}

fn process_dir(root: &Path) -> PathBuf {
    user_dir(root).join(format!("{DIR_PREFIX}{}", std::process::id()))
}

/// `dir` is a real directory, ours, mode 0700 (created so when `create`).
fn trusted(dir: &Path, create: bool) -> io::Result<()> {
    if create {
        match DirBuilder::new().mode(0o700).create(dir) {
            Err(e) if e.kind() != io::ErrorKind::AlreadyExists => return Err(e),
            _ => {}
        }
    }
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    let meta = fs::symlink_metadata(dir)?;
    if !meta.is_dir() || meta.uid() != euid || meta.mode() & 0o777 != 0o700 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "untrusted image directory",
        ));
    }
    Ok(())
}

/// Client start: removes what processes that are gone left in the per-user dir
/// under `root` (their `dynide-gfx-<pid>` dirs, and loose files of older clients).
pub fn sweep(root: &Path) {
    let user = user_dir(root);
    let Ok(entries) = trusted(&user, false).and_then(|()| fs::read_dir(&user)) else {
        return;
    };
    for entry in entries.flatten() {
        if !leftover(&entry.file_name().to_string_lossy()) {
            continue;
        }
        // file_type does not follow symlinks; remove_dir_all does not either
        let _ = match entry.file_type() {
            Ok(t) if t.is_dir() => fs::remove_dir_all(entry.path()),
            _ => fs::remove_file(entry.path()),
        };
    }
}

/// Client exit: removes this process's dir under `root` with whatever is left in it.
pub fn remove_process_dir(root: &Path) {
    let _ = fs::remove_dir_all(process_dir(root));
}

/// `dynide-gfx-<pid>` or `tty-graphics-protocol-<pid>-<n>` of a process that no
/// longer exists.
fn leftover(name: &str) -> bool {
    let pid = match name.strip_prefix(DIR_PREFIX) {
        Some(pid) => Some(pid),
        None => name
            .strip_prefix(FILE_PREFIX)
            .and_then(|rest| rest.split_once('-'))
            .map(|(pid, _)| pid),
    };
    let Some(pid) = pid.and_then(|pid| pid.parse::<libc::pid_t>().ok()) else {
        return false;
    };
    // SAFETY: signal 0 only checks that the pid exists.
    pid > 0
        && unsafe { libc::kill(pid, 0) } == -1
        && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;

    fn s(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes).into_owned()
    }

    fn b64(data: &[u8]) -> String {
        let mut out = Vec::new();
        base64(&mut out, data);
        s(&out)
    }

    /// Inverse of `base64`, for round trips.
    fn unb64(text: &str) -> Vec<u8> {
        let val = |c: u8| match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            _ => 63,
        };
        let mut out = Vec::new();
        for quad in text.as_bytes().chunks(4) {
            let n = quad.iter().fold(0u32, |n, &c| {
                n << 6 | u32::from(if c == b'=' { 0 } else { val(c) })
            });
            let keep = quad.iter().filter(|&&c| c != b'=').count() - 1;
            out.extend_from_slice(&n.to_be_bytes()[1..1 + keep]);
        }
        out
    }

    fn root(name: &str) -> PathBuf {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("target/test-graphics")
            .join(format!("{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn upload(data: Vec<u8>, medium: Medium) -> Op {
        Op::Upload {
            id: 7,
            format: 32,
            width: 2,
            height: 3,
            data,
            medium,
        }
    }

    /// The base64 payload of every APC in `out`, in order.
    fn payloads(out: &str) -> Vec<(String, String)> {
        out.split("\x1b_G")
            .skip(1)
            .map(|apc| {
                let apc = apc.split("\x1b\\").next().unwrap();
                let (control, payload) = apc.split_once(';').unwrap();
                (control.to_owned(), payload.to_owned())
            })
            .collect()
    }

    #[test]
    fn base64_vectors() {
        for (input, want) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(b64(input.as_bytes()), want);
        }
        let all: Vec<u8> = (0..=255).collect();
        assert_eq!(unb64(&b64(&all)), all);
        assert!(b64(&[0xfb, 0xff]).contains('+') && b64(&[0xff, 0xff]).contains('/'));
    }

    #[test]
    fn direct_upload_chunks_and_round_trips() {
        let data: Vec<u8> = (0..CHUNK_BYTES * 2 + 7).map(|i| i as u8).collect();
        let mut out = Vec::new();
        encode(
            &mut out,
            &[upload(data.clone(), Medium::Direct)],
            &mut Files::at("/nonexistent"),
            Instant::now(),
        );
        let apcs = payloads(&s(&out));
        let controls: Vec<&str> = apcs.iter().map(|(c, _)| c.as_str()).collect();
        assert_eq!(controls, ["a=t,t=d,f=32,s=2,v=3,i=7,q=2,m=1", "m=1", "m=0"]);
        let joined: Vec<u8> = apcs.iter().flat_map(|(_, p)| unb64(p)).collect();
        assert_eq!(joined, data);
    }

    #[test]
    fn place_omits_zero_keys_and_deletes() {
        let place = |src, off| Op::Place {
            id: 10_001,
            placement: 5,
            x: 3,
            y: 0,
            cols: 4,
            rows: 2,
            src,
            off,
            z: -1,
        };
        let mut out = Vec::new();
        let ops = [
            place((0, 0, 0, 0), (0, 0)),
            place((1, 2, 3, 4), (5, 6)),
            Op::DeletePlacement(9, 8),
            Op::DeleteImage(9),
            Op::DeleteAll,
        ];
        encode(
            &mut out,
            &ops,
            &mut Files::at("/nonexistent"),
            Instant::now(),
        );
        assert_eq!(
            s(&out),
            "\x1b[1;4H\x1b_Ga=p,i=10001,p=5,c=4,r=2,z=-1,C=1,q=2;\x1b\\\
             \x1b[1;4H\x1b_Ga=p,i=10001,p=5,c=4,r=2,z=-1,C=1,q=2,x=1,y=2,w=3,h=4,X=5,Y=6;\x1b\\\
             \x1b_Ga=d,d=i,i=9,p=8,q=2;\x1b\\\
             \x1b_Ga=d,d=I,i=9,q=2;\x1b\\\
             \x1b_Ga=d,d=A,q=2;\x1b\\"
        );
    }

    #[test]
    fn file_medium_probes_first_then_uses_files() {
        let root = root("probe");
        let mut files = Files::at(&root);
        let now = Instant::now();
        let data = vec![42u8; 100];

        let mut out = Vec::new();
        encode(
            &mut out,
            &[upload(data.clone(), Medium::File)],
            &mut files,
            now,
        );
        let apcs = payloads(&s(&out));
        assert_eq!(apcs[0].0, "a=q,t=t,f=32,s=1,v=1,i=1,q=2");
        let probe = PathBuf::from(String::from_utf8(unb64(&apcs[0].1)).unwrap());
        assert!(probe.exists() && probe.starts_with(&root));
        assert!(probe.to_string_lossy().contains("tty-graphics-protocol"));
        assert_eq!(apcs[1].0, "a=t,t=d,f=32,s=2,v=3,i=7,q=2,m=0", "sent direct");
        assert_eq!(files.state(), Transport::Probing);

        // Still probing: direct, no second probe.
        let mut out = Vec::new();
        encode(
            &mut out,
            &[upload(data.clone(), Medium::File)],
            &mut files,
            now,
        );
        assert_eq!(payloads(&s(&out)).len(), 1);
        assert!(s(&out).contains("t=d"));

        // The host consumed the probe.
        fs::remove_file(&probe).unwrap();
        let mut out = Vec::new();
        encode(
            &mut out,
            &[upload(data.clone(), Medium::File)],
            &mut files,
            now,
        );
        assert_eq!(files.state(), Transport::Ok);
        let apcs = payloads(&s(&out));
        assert_eq!(apcs.len(), 1);
        assert_eq!(apcs[0].0, "a=t,t=t,f=32,s=2,v=3,i=7,q=2");
        let path = PathBuf::from(String::from_utf8(unb64(&apcs[0].1)).unwrap());
        assert_eq!(fs::read(&path).unwrap(), data);
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&path), 0o600);
        assert_eq!(path.parent().unwrap(), process_dir(&root));
        assert_eq!(mode(path.parent().unwrap()), 0o700);
        assert_eq!(mode(&user_dir(&root)), 0o700);

        // Drop removes what the host never consumed, then the empty dir.
        drop(files);
        assert!(!path.exists());
        assert!(!process_dir(&root).exists() && user_dir(&root).exists());
    }

    #[test]
    fn files_older_than_a_minute_are_unlinked_on_the_next_write() {
        let root = root("age");
        let mut files = Files::at(&root);
        let now = Instant::now();
        let op = [upload(vec![1; 10], Medium::File)];
        let mut out = Vec::new();
        encode(&mut out, &op, &mut files, now);
        let probe = PathBuf::from(String::from_utf8(unb64(&payloads(&s(&out))[0].1)).unwrap());
        assert!(probe.exists());
        // the host never reads it: disabled at 10 s, unlinked at 60 s
        encode(&mut Vec::new(), &op, &mut files, now + CONSUMPTION_TIMEOUT);
        assert_eq!(files.state(), Transport::Disabled);
        assert!(probe.exists());
        encode(&mut Vec::new(), &op, &mut files, now + MAX_FILE_AGE);
        assert!(!probe.exists());
    }

    #[test]
    fn exit_removes_the_process_dir() {
        let root = root("exit");
        let mut files = Files::at(&root);
        let mut out = Vec::new();
        encode(
            &mut out,
            &[upload(vec![1], Medium::File)],
            &mut files,
            Instant::now(),
        );
        assert!(fs::read_dir(process_dir(&root)).unwrap().count() == 1);
        remove_process_dir(&root);
        assert!(!process_dir(&root).exists() && user_dir(&root).exists());
    }

    #[test]
    fn unconsumed_probe_disables_after_timeout() {
        let root = root("timeout");
        let mut files = Files::at(&root);
        let now = Instant::now();
        let op = [upload(vec![1; 10], Medium::File)];
        encode(&mut Vec::new(), &op, &mut files, now);
        encode(
            &mut Vec::new(),
            &op,
            &mut files,
            now + Duration::from_secs(9),
        );
        assert_eq!(files.state(), Transport::Probing);
        let mut out = Vec::new();
        encode(&mut out, &op, &mut files, now + CONSUMPTION_TIMEOUT);
        assert_eq!(files.state(), Transport::Disabled);
        assert!(s(&out).contains("t=d") && !s(&out).contains("a=q"));
    }

    #[test]
    fn untrusted_or_missing_dir_disables() {
        let root = root("untrusted");
        let euid = unsafe { libc::geteuid() };
        let dir = root.join(format!("dynide-kitty-{euid}"));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        let mut files = Files::at(&root);
        let mut out = Vec::new();
        encode(
            &mut out,
            &[upload(vec![1], Medium::File)],
            &mut files,
            Instant::now(),
        );
        assert_eq!(files.state(), Transport::Disabled);
        assert!(s(&out).contains("t=d") && !s(&out).contains("a=q"));

        let mut files = Files::at(root.join("missing"));
        encode(
            &mut Vec::new(),
            &[upload(vec![1], Medium::File)],
            &mut files,
            Instant::now(),
        );
        assert_eq!(files.state(), Transport::Disabled);
    }

    #[test]
    fn sweep_removes_leftovers_of_dead_processes_only() {
        let root = root("leftover");
        let dir = user_dir(&root);
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        // pid_t max is far below this on Linux and macOS: never alive.
        let dead = dir.join(format!("{FILE_PREFIX}999999999-0"));
        let live = dir.join(format!("{FILE_PREFIX}{}-999999", std::process::id()));
        let other = dir.join("unrelated");
        for p in [&dead, &live, &other] {
            fs::write(p, b"x").unwrap();
        }
        let dead_dir = dir.join(format!("{DIR_PREFIX}999999999"));
        let dynide_dir = process_dir(&root);
        for d in [&dead_dir, &dynide_dir] {
            fs::create_dir(d).unwrap();
            fs::write(d.join(format!("{FILE_PREFIX}1-0")), b"x").unwrap();
        }
        // a dead-pid name that is a symlink: the link goes, its target stays
        let target = root.join("target-dir");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("keep"), b"x").unwrap();
        let link = dir.join(format!("{DIR_PREFIX}999999998"));
        std::os::unix::fs::symlink(&target, &link).unwrap();

        sweep(&root);
        assert!(!dead.exists() && live.exists() && other.exists());
        assert!(!dead_dir.exists() && dynide_dir.exists());
        assert!(fs::symlink_metadata(&link).is_err() && target.join("keep").exists());

        // an untrusted user dir is left alone
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        fs::create_dir(&dead_dir).unwrap();
        sweep(&root);
        assert!(dead_dir.exists());
    }

    #[test]
    fn images_over_the_file_cap_go_direct() {
        let root = root("cap");
        let mut files = Files::at(&root);
        let now = Instant::now();
        let mut out = Vec::new();
        encode(&mut out, &[upload(vec![1], Medium::File)], &mut files, now);
        let probe = payloads(&s(&out))[0].1.clone();
        fs::remove_file(String::from_utf8(unb64(&probe)).unwrap()).unwrap();
        let mut out = Vec::new();
        let big = upload(vec![1; MAX_IMAGE_BYTES + 1], Medium::File);
        encode(&mut out, &[big], &mut files, now);
        assert_eq!(files.state(), Transport::Ok);
        assert!(s(&out[..64]).contains("t=d"), "direct");
        let mut out = Vec::new();
        let max = upload(vec![1; MAX_IMAGE_BYTES], Medium::File);
        encode(&mut out, &[max], &mut files, now);
        assert!(s(&out).contains("t=t"), "at the cap: file");
    }
}
