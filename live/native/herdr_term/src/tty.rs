//! Host tty ownership: raw mode, startup probe, input reader, restore.
//!
//! `Inner` is shared by the NIF resource and the kernel threads it owns. The
//! threads hold an `Arc<Inner>`, so teardown is explicit: `TtyResource`'s
//! `Drop` restores the terminal, raises `shutdown`, and joins the threads,
//! each of which re-checks `shutdown` at least every `POLL_MS`.

use crate::probe::{self, ProbeState};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Every blocking wait on the fd is bounded by this, so threads notice `shutdown`.
const POLL_MS: i32 = 100;
/// Total time budget for writing the open or restore sequence.
const WRITE_BUDGET: Duration = Duration::from_millis(100);
const PROBE_TIMEOUT: Duration = Duration::from_millis(250);
/// Input kept while nobody is subscribed (and probe leftovers).
const MAX_PENDING_INPUT: usize = 64 * 1024;
const READ_CHUNK: usize = 4096;

const ENTER: &[u8] = b"\x1b[?1049h\x1b[?7l\x1b[?25l";
const PROBE_QUERY: &[u8] = b"\x1b[?u\x1b[c";
const KITTY_POP: &[u8] = b"\x1b[<u";
const RESTORE: &[u8] = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1016l\x1b[?2004l\x1b[?1004l\x1b]8;;\x1b\\\x1b[0m\x1b[0 q\x1b[?25h\x1b[?7h\x1b[?1049l";

/// Events delivered to the subscriber.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// `{:tty_input, binary}`
    Input(Vec<u8>),
    /// `{:exit, :tty, :hangup}`: EOF or EIO on the tty.
    Hangup,
    /// `{:exit, :tty, {:panic, binary}}`: a kernel thread panicked.
    Panic(String),
}

/// Where events go: an Erlang pid in production, a channel in tests.
pub trait Sink: Send {
    fn send(&mut self, event: Event);
}

impl Sink for mpsc::Sender<Event> {
    fn send(&mut self, event: Event) {
        // A dropped receiver just means nobody listens any more.
        let _ = mpsc::Sender::send(self, event);
    }
}

pub type Subscriber = Option<Box<dyn Sink>>;

#[derive(Default)]
struct Subscription {
    sink: Subscriber,
    pending: Vec<u8>,
    exit: Option<Event>,
}

impl Subscription {
    fn deliver(&mut self, event: Event) {
        if let Some(sink) = self.sink.as_mut() {
            sink.send(event);
            return;
        }
        match event {
            Event::Input(bytes) => {
                // ponytail: input beyond 64 KiB before subscribe is dropped; a
                // client subscribes right after open, so this cap is never hit live.
                let room = MAX_PENDING_INPUT.saturating_sub(self.pending.len());
                self.pending
                    .extend_from_slice(&bytes[..bytes.len().min(room)]);
            }
            exit => self.exit = Some(exit),
        }
    }
}

pub struct Inner {
    file: File,
    saved: libc::termios,
    kitty: Option<u16>,
    kitty_pushed: bool,
    restored: AtomicBool,
    shutdown: AtomicBool,
    sub: Mutex<Subscription>,
    threads: Mutex<Vec<JoinHandle<()>>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panicking thread already reported itself; keep using the data.
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn cvt(rc: libc::c_int) -> io::Result<()> {
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Polls `fd` for `events`; `Ok(false)` on timeout. EINTR counts as a timeout.
#[cfg(not(target_os = "macos"))]
pub(crate) fn poll_fd(fd: RawFd, events: libc::c_short, timeout_ms: i32) -> io::Result<bool> {
    let mut pfd = libc::pollfd {
        fd,
        events,
        revents: 0,
    };
    // SAFETY: one valid pollfd.
    let rc = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
    if rc < 0 {
        return interrupted_is_timeout(io::Error::last_os_error());
    }
    if rc > 0 && pfd.revents & libc::POLLNVAL != 0 {
        return Err(io::Error::from_raw_os_error(libc::EBADF));
    }
    Ok(rc > 0)
}

/// Polls `fd` for `events`; `Ok(false)` on timeout. EINTR counts as a timeout.
///
/// macOS poll(2) reports POLLNVAL for `/dev/tty`, so this uses select(2). The
/// `$DARWIN_EXTSN` variant accepts fds at or above FD_SETSIZE when the set is
/// sized for them, which matters inside the BEAM's large fd table.
#[cfg(target_os = "macos")]
pub(crate) fn poll_fd(fd: RawFd, events: libc::c_short, timeout_ms: i32) -> io::Result<bool> {
    extern "C" {
        #[link_name = "select$DARWIN_EXTSN"]
        fn select_extsn(
            nfds: libc::c_int,
            readfds: *mut u32,
            writefds: *mut u32,
            errorfds: *mut u32,
            timeout: *mut libc::timeval,
        ) -> libc::c_int;
    }
    let index = usize::try_from(fd).map_err(|_| io::Error::from_raw_os_error(libc::EBADF))?;
    // Darwin fd_set: 32-bit words, bit `fd % 32` of word `fd / 32`.
    let mut set = vec![0u32; index / 32 + 1];
    set[index / 32] |= 1 << (index % 32);
    let mut timeout = libc::timeval {
        tv_sec: libc::time_t::from(timeout_ms / 1000),
        tv_usec: (timeout_ms % 1000) * 1000,
    };
    let none = std::ptr::null_mut();
    let (read, write) = if events & libc::POLLOUT != 0 {
        (none, set.as_mut_ptr())
    } else {
        (set.as_mut_ptr(), none)
    };
    // SAFETY: `set` covers `fd + 1` bits and outlives the call.
    let rc = unsafe { select_extsn(fd + 1, read, write, none, &mut timeout) };
    if rc < 0 {
        return interrupted_is_timeout(io::Error::last_os_error());
    }
    Ok(rc > 0)
}

fn interrupted_is_timeout(err: io::Error) -> io::Result<bool> {
    if err.kind() == io::ErrorKind::Interrupted {
        Ok(false)
    } else {
        Err(err)
    }
}

fn ms_until(deadline: Instant) -> Option<i32> {
    let left = deadline.checked_duration_since(Instant::now())?;
    Some(left.as_millis().clamp(1, POLL_MS as u128) as i32)
}

/// Writes all of `bytes` to the non-blocking `file` before `deadline`.
fn write_by(file: &File, mut bytes: &[u8], deadline: Instant) -> io::Result<()> {
    while !bytes.is_empty() {
        match (&*file).write(bytes) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => bytes = &bytes[n..],
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                let ms = ms_until(deadline).ok_or(io::ErrorKind::TimedOut)?;
                poll_fd(file.as_raw_fd(), libc::POLLOUT, ms)?;
            }
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

impl Inner {
    /// Opens `path`, enters raw mode and the alternate screen, probes kitty
    /// keyboard support (pushing `kitty_flags` when confirmed and non-zero),
    /// and starts the reader thread. Blocks for up to the probe timeout.
    pub fn open_path(path: &str, kitty_flags: u16, sub: Subscriber) -> io::Result<Arc<Inner>> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOCTTY | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)?;
        let fd = file.as_raw_fd();
        // SAFETY: zeroed termios is a valid out-parameter for tcgetattr.
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out-pointer.
        cvt(unsafe { libc::tcgetattr(fd, &mut saved) })?;
        let mut raw = saved;
        // SAFETY: raw is a valid termios.
        unsafe { libc::cfmakeraw(&mut raw) };
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        // SAFETY: valid fd and termios.
        cvt(unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) })?;

        let (probe, leftover) = match Self::probe(&file) {
            Ok(found) => found,
            Err(err) => {
                // SAFETY: valid fd and the termios saved above.
                unsafe { libc::tcsetattr(fd, libc::TCSANOW, &saved) };
                return Err(err);
            }
        };
        let kitty = probe.flags;
        let kitty_pushed = kitty.is_some() && kitty_flags != 0;
        if kitty_pushed {
            let push = format!("\x1b[>{kitty_flags}u");
            // Best effort: a host that just answered the probe is reading.
            let _ = write_by(&file, push.as_bytes(), Instant::now() + WRITE_BUDGET);
        }

        let mut subscription = Subscription {
            sink: sub,
            ..Subscription::default()
        };
        if !leftover.is_empty() {
            subscription.deliver(Event::Input(leftover));
        }
        let inner = Arc::new(Inner {
            file,
            saved,
            kitty,
            kitty_pushed,
            restored: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
            sub: Mutex::new(subscription),
            threads: Mutex::new(Vec::new()),
        });
        let reader = Arc::clone(&inner);
        let spawned = std::thread::Builder::new()
            .name("herdr-tty-reader".into())
            .spawn(move || reader.run_guarded(Inner::read_loop));
        match spawned {
            Ok(handle) => lock(&inner.threads).push(handle),
            Err(err) => {
                let _ = inner.restore();
                return Err(err);
            }
        }
        Ok(inner)
    }

    /// Writes the enter sequence and probe, then collects replies until DA1
    /// or the timeout. Returns the probe result and the non-reply bytes.
    fn probe(file: &File) -> io::Result<(ProbeState, Vec<u8>)> {
        let mut out = ENTER.to_vec();
        out.extend_from_slice(PROBE_QUERY);
        write_by(file, &out, Instant::now() + WRITE_BUDGET)?;

        let deadline = Instant::now() + PROBE_TIMEOUT;
        let mut state = ProbeState::default();
        let mut buf = Vec::new();
        let mut chunk = [0u8; READ_CHUNK];
        while !state.da1_seen && buf.len() < MAX_PENDING_INPUT {
            let Some(ms) = ms_until(deadline) else { break };
            if !poll_fd(file.as_raw_fd(), libc::POLLIN, ms)? {
                continue;
            }
            match (&*file).read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    probe::parse(&mut buf, &mut state);
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) => {}
                // EIO and friends: let the reader thread report the hangup.
                Err(_) => break,
            }
        }
        Ok((state, buf))
    }

    /// Runs a thread body; a panic is reported to the subscriber.
    fn run_guarded(&self, body: fn(&Inner)) {
        if let Err(payload) = catch_unwind(AssertUnwindSafe(|| body(self))) {
            let reason = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".to_owned());
            lock(&self.sub).deliver(Event::Panic(reason));
        }
    }

    fn read_loop(&self) {
        let fd = self.file.as_raw_fd();
        let mut chunk = [0u8; READ_CHUNK];
        while !self.shutdown.load(Ordering::Acquire) {
            match poll_fd(fd, libc::POLLIN, POLL_MS) {
                Ok(true) => {}
                Ok(false) => continue,
                Err(_) => {
                    self.hangup();
                    break;
                }
            }
            match (&self.file).read(&mut chunk) {
                Ok(0) => {
                    self.hangup();
                    break;
                }
                Ok(n) => lock(&self.sub).deliver(Event::Input(chunk[..n].to_vec())),
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) => {}
                Err(_) => {
                    self.hangup();
                    break;
                }
            }
        }
    }

    fn hangup(&self) {
        if !self.shutdown.load(Ordering::Acquire) {
            lock(&self.sub).deliver(Event::Hangup);
        }
    }

    /// Replaces the subscriber. Input (and an exit) that arrived while
    /// nobody was subscribed is handed to `early` first, under the same lock,
    /// so it stays ahead of anything the reader delivers to `sink`. `early`
    /// exists because the NIF must send from the calling scheduler thread.
    pub fn subscribe(&self, sink: Box<dyn Sink>, mut early: impl FnMut(Event)) {
        let mut sub = lock(&self.sub);
        if !sub.pending.is_empty() {
            early(Event::Input(std::mem::take(&mut sub.pending)));
        }
        if let Some(exit) = sub.exit.take() {
            early(exit);
        }
        sub.sink = Some(sink);
    }

    pub fn kitty(&self) -> Option<u16> {
        self.kitty
    }

    /// `(cols, rows, xpixel, ypixel)` from TIOCGWINSZ.
    pub fn size(&self) -> io::Result<(u16, u16, u16, u16)> {
        // SAFETY: zeroed winsize is a valid out-parameter.
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out-pointer.
        cvt(unsafe { libc::ioctl(self.file.as_raw_fd(), libc::TIOCGWINSZ, &mut ws) })?;
        Ok((ws.ws_col, ws.ws_row, ws.ws_xpixel, ws.ws_ypixel))
    }

    /// Restores the host terminal once; later calls do nothing.
    pub fn restore(&self) -> io::Result<()> {
        if self.restored.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.reset_terminal()
    }

    /// Writes the restore sequence (best effort, `WRITE_BUDGET`) and resets
    /// termios to the saved state. Does not claim `restored`, so suspend can
    /// reuse it.
    pub(crate) fn reset_terminal(&self) -> io::Result<()> {
        let mut out = Vec::with_capacity(KITTY_POP.len() + RESTORE.len());
        if self.kitty_pushed {
            out.extend_from_slice(KITTY_POP);
        }
        out.extend_from_slice(RESTORE);
        // Best effort: a host that stopped reading must not keep us in raw mode.
        let _ = write_by(&self.file, &out, Instant::now() + WRITE_BUDGET);
        // SAFETY: valid fd and the termios saved at open.
        cvt(unsafe { libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &self.saved) })
    }

    /// Restores, stops the kernel threads, and joins them (bounded by `POLL_MS`).
    fn shutdown(&self) {
        let _ = self.restore();
        self.shutdown.store(true, Ordering::Release);
        let threads = std::mem::take(&mut *lock(&self.threads));
        for handle in threads {
            // Thread bodies run under catch_unwind; a join error cannot carry news.
            let _ = handle.join();
        }
    }
}

/// The NIF resource. Dropping it (BEAM GC of the last reference) restores the
/// terminal and stops the threads.
pub struct TtyResource {
    pub inner: Arc<Inner>,
}

impl TtyResource {
    pub fn new(inner: Arc<Inner>) -> Self {
        TtyResource { inner }
    }
}

impl Drop for TtyResource {
    fn drop(&mut self) {
        self.inner.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    struct Pty {
        master: File,
        slave: File,
        path: String,
    }

    fn pty() -> Pty {
        let (mut m, mut s) = (0, 0);
        // SAFETY: openpty writes two fds; name/termios/winsize may be null.
        let rc = unsafe {
            libc::openpty(
                &mut m,
                &mut s,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(rc, 0, "openpty: {}", io::Error::last_os_error());
        // SAFETY: openpty returned owned fds.
        let (master, slave) = unsafe { (File::from_raw_fd(m), File::from_raw_fd(s)) };
        // SAFETY: ttyname returns a NUL-terminated static buffer or null.
        let name = unsafe { libc::ttyname(slave.as_raw_fd()) };
        assert!(!name.is_null());
        // SAFETY: non-null C string from ttyname.
        let path = unsafe { std::ffi::CStr::from_ptr(name) }
            .to_string_lossy()
            .into_owned();
        Pty {
            master,
            slave,
            path,
        }
    }

    fn termios(f: &File) -> libc::termios {
        // SAFETY: zeroed termios is a valid out-parameter.
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out-pointer.
        assert_eq!(unsafe { libc::tcgetattr(f.as_raw_fd(), &mut t) }, 0);
        t
    }

    fn same_termios(a: &libc::termios, b: &libc::termios) -> bool {
        a.c_iflag == b.c_iflag
            && a.c_oflag == b.c_oflag
            && a.c_cflag == b.c_cflag
            // PENDIN is kernel bookkeeping the BSD tty layer sets when ICANON is
        // re-enabled and clears on the next read; it is not configuration.
        && a.c_lflag & !libc::PENDIN == b.c_lflag & !libc::PENDIN
            && a.c_cc == b.c_cc
    }

    /// Reads from `f` until `want` appears or `timeout` passes; returns everything read.
    fn read_until(f: &File, want: &[u8], timeout: Duration) -> Vec<u8> {
        let deadline = Instant::now() + timeout;
        let mut out = Vec::new();
        while !out.windows(want.len().max(1)).any(|w| w == want) || want.is_empty() {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            match poll_fd(f.as_raw_fd(), libc::POLLIN, left.as_millis() as i32 + 1) {
                Ok(true) => {}
                _ => break,
            }
            let mut buf = [0u8; 4096];
            match (&*f).read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => out.extend_from_slice(&buf[..n]),
            }
        }
        out
    }

    fn contains(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }

    fn channel() -> (Box<dyn Sink>, mpsc::Receiver<Event>) {
        let (tx, rx) = mpsc::channel();
        (Box::new(tx), rx)
    }

    fn recv_input(rx: &mpsc::Receiver<Event>, want: &[u8]) -> Vec<u8> {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut got = Vec::new();
        while !contains(&got, want) {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            match rx.recv_timeout(left) {
                Ok(Event::Input(b)) => got.extend(b),
                Ok(other) => panic!("unexpected event {other:?}"),
                Err(_) => break,
            }
        }
        got
    }

    #[test]
    fn open_sets_raw_mode() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        let t = termios(&p.slave);
        assert_eq!(t.c_lflag & (libc::ICANON | libc::ECHO), 0);
        let out = read_until(&p.master, b"\x1b[c", Duration::from_secs(1));
        assert!(contains(&out, b"\x1b[?1049h"), "{out:?}");
        assert!(contains(&out, b"\x1b[?u\x1b[c"), "{out:?}");
        drop(tty);
    }

    #[test]
    fn probe_reads_kitty_flags() {
        let p = pty();
        let master = p.master.try_clone().unwrap();
        let replier = std::thread::spawn(move || {
            read_until(&master, b"\x1b[c", Duration::from_secs(1));
            (&master).write_all(b"\x1b[?15u\x1b[?62;22c").unwrap();
            master
        });
        let tty = TtyResource::new(Inner::open_path(&p.path, 1, None).unwrap());
        let master = replier.join().unwrap();
        assert_eq!(tty.inner.kitty(), Some(15));
        let out = read_until(&master, b"\x1b[>1u", Duration::from_secs(1));
        assert!(contains(&out, b"\x1b[>1u"), "{out:?}");
        drop(tty);
        let out = read_until(&master, b"\x1b[?1049l", Duration::from_secs(1));
        assert!(
            out.starts_with(b"\x1b[<u"),
            "pushed flags are popped: {out:?}"
        );
    }

    #[test]
    fn probe_times_out_without_reply() {
        let p = pty();
        let start = Instant::now();
        let tty = TtyResource::new(Inner::open_path(&p.path, 1, None).unwrap());
        assert!(start.elapsed() < Duration::from_millis(400));
        assert_eq!(tty.inner.kitty(), None);
        let out = read_until(&p.master, b"\x1b[>", Duration::from_millis(200));
        assert!(!contains(&out, b"\x1b[>"), "nothing pushed: {out:?}");
    }

    #[test]
    fn probe_keeps_user_bytes() {
        let p = pty();
        let master = p.master.try_clone().unwrap();
        let replier = std::thread::spawn(move || {
            read_until(&master, b"\x1b[c", Duration::from_secs(1));
            // Brief vector `\x1b[c` is the query, not a DA1 reply; replies carry `?`.
            (&master).write_all(b"ab\x1b[?1u\x1b[?62cZ").unwrap();
        });
        let (sink, rx) = channel();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, Some(sink)).unwrap());
        replier.join().unwrap();
        assert_eq!(tty.inner.kitty(), Some(1));
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(1)).ok(),
            Some(Event::Input(b"abZ".to_vec()))
        );
    }

    #[test]
    fn bytes_before_subscribe_are_delivered_first() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        (&p.master).write_all(b"early").unwrap();
        std::thread::sleep(Duration::from_millis(250));
        let (tx, rx) = mpsc::channel();
        let early = tx.clone();
        tty.inner.subscribe(Box::new(tx), |e| {
            let _ = early.send(e);
        });
        (&p.master).write_all(b"late").unwrap();
        assert_eq!(recv_input(&rx, b"earlylate"), b"earlylate");
    }

    #[test]
    fn input_reaches_subscriber() {
        let p = pty();
        let (sink, rx) = channel();
        let _tty = TtyResource::new(Inner::open_path(&p.path, 0, Some(sink)).unwrap());
        (&p.master).write_all(b"hello").unwrap();
        assert_eq!(recv_input(&rx, b"hello"), b"hello");
    }

    #[test]
    fn hangup_on_master_close() {
        let p = pty();
        let (sink, rx) = channel();
        let _tty = TtyResource::new(Inner::open_path(&p.path, 0, Some(sink)).unwrap());
        drop(p.master);
        drop(p.slave);
        let ev = rx.recv_timeout(Duration::from_secs(2));
        assert_eq!(ev.ok(), Some(Event::Hangup));
    }

    #[test]
    fn size_reports_winsize() {
        let p = pty();
        let ws = libc::winsize {
            ws_row: 30,
            ws_col: 100,
            ws_xpixel: 800,
            ws_ypixel: 600,
        };
        // SAFETY: valid fd and winsize pointer.
        assert_eq!(
            unsafe { libc::ioctl(p.master.as_raw_fd(), libc::TIOCSWINSZ, &ws) },
            0
        );
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        assert_eq!(tty.inner.size().unwrap(), (100, 30, 800, 600));
    }

    #[test]
    fn restore_is_idempotent() {
        let p = pty();
        let before = termios(&p.slave);
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        read_until(&p.master, b"\x1b[c", Duration::from_secs(1));
        tty.inner.restore().unwrap();
        assert!(same_termios(&termios(&p.slave), &before));
        let out = read_until(&p.master, b"\x1b[?1049l", Duration::from_secs(1));
        assert!(out.starts_with(b"\x1b[?1000l"), "no kitty pop: {out:?}");
        assert!(out.ends_with(b"\x1b[?1049l"), "{out:?}");
        tty.inner.restore().unwrap();
        drop(tty);
        let again = read_until(&p.master, b"", Duration::from_millis(200));
        assert!(
            again.is_empty(),
            "second restore and drop write nothing: {again:?}"
        );
        assert!(same_termios(&termios(&p.slave), &before));
    }

    #[test]
    fn drop_restores() {
        let p = pty();
        let before = termios(&p.slave);
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        let start = Instant::now();
        drop(tty);
        assert!(start.elapsed() < Duration::from_millis(400));
        assert!(same_termios(&termios(&p.slave), &before));
        let out = read_until(&p.master, b"\x1b[?1049l", Duration::from_secs(1));
        assert!(contains(&out, b"\x1b[?1049l"), "{out:?}");
    }

    #[test]
    fn open_rejects_missing_path() {
        assert!(Inner::open_path("/nonexistent", 0, None).is_err());
    }
}
