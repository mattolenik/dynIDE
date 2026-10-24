//! herdr_broker: parent of every herdr-live VM. Holds PTY master dups and
//! per-pane blobs, keeps a warm standby, and hands both to a new VM on VM
//! death or `kernel-restart`.
//!
//! herdr_broker run [--runtime-dir DIR] -- <vm argv...>
//! herdr_broker kernel-restart [--runtime-dir DIR]
//! herdr_broker status [--runtime-dir DIR]

mod broker;
mod ctl;
mod log;
mod tty;
mod vm;

use crate::log::log;
use std::ffi::OsString;
use std::os::fd::IntoRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};

const USAGE: &str = "usage: herdr_broker run [--runtime-dir DIR] -- <vm argv...>\n       herdr_broker kernel-restart|status [--runtime-dir DIR]";

fn main() {
    std::process::exit(real_main());
}

fn real_main() -> i32 {
    let mut args = std::env::args_os().skip(1);
    let cmd = args.next().unwrap_or_default();
    let mut dir = None;
    let mut vm = Vec::new();
    while let Some(a) = args.next() {
        if a == "--runtime-dir" {
            dir = args.next().map(PathBuf::from);
        } else if a == "--" {
            vm = args.by_ref().collect();
        } else {
            eprintln!("{USAGE}");
            return 2;
        }
    }
    let dir = dir.unwrap_or_else(default_runtime_dir);
    let sock = dir.join("broker.sock");
    match cmd.to_str() {
        Some("run") if !vm.is_empty() => run(&dir, sock, vm),
        Some("kernel-restart") => ctl::restart(&sock),
        Some("status") => ctl::status(&sock),
        _ => {
            eprintln!("{USAGE}");
            2
        }
    }
}

/// `$HERDR_LIVE_RUNTIME_DIR`, else `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/herdr-live-<uid>`.
fn default_runtime_dir() -> PathBuf {
    let env = |k| std::env::var_os(k).filter(|v| !v.is_empty());
    if let Some(d) = env("HERDR_LIVE_RUNTIME_DIR") {
        return d.into();
    }
    let base = env("XDG_RUNTIME_DIR")
        .or_else(|| env("TMPDIR"))
        .unwrap_or_else(|| "/tmp".into());
    // SAFETY: getuid cannot fail.
    PathBuf::from(base).join(format!("herdr-live-{}", unsafe { libc::getuid() }))
}

fn run(dir: &Path, sock: PathBuf, argv: Vec<OsString>) -> i32 {
    if UnixStream::connect(&sock).is_ok() {
        eprintln!("herdr-live: broker already running at {}", sock.display());
        return 2;
    }
    let made = std::fs::create_dir_all(dir)
        .and_then(|()| std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)));
    if let Err(e) = made {
        log!("runtime dir {}: {e}", dir.display());
        return 1;
    }
    let _ = std::fs::remove_file(&sock);
    let sig = match install_signals() {
        Ok(s) => s,
        Err(e) => {
            log!("signal setup: {e}");
            return 1;
        }
    };
    let guard = tty::Guard::open_path("/dev/tty");
    let cfg = broker::Config::new(sock.clone());
    let spawner = vm::Real { argv, sock };
    let outcome = broker::Broker::new(cfg, spawner, sig).and_then(|mut b| b.run());
    let (code, crashed) = match outcome {
        Ok(o) => (o.code, o.crashed),
        Err(e) => {
            log!("fatal: {e}");
            (1, true)
        }
    };
    if let Some(g) = guard {
        g.restore(crashed);
    }
    log!("stopped");
    code
}

static SIG_FD: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(sig: libc::c_int) {
    let b: u8 = if sig == libc::SIGCHLD { b'C' } else { b'T' };
    // Async-signal-safe: one write to a non-blocking socket. A full buffer
    // already holds a wakeup, so a failed write loses nothing.
    // SAFETY: plain write(2) of one byte from a live stack slot.
    unsafe { libc::write(SIG_FD.load(Ordering::Relaxed), (&b as *const u8).cast(), 1) };
}

/// Self-pipe: the handlers write `C` (SIGCHLD) or `T` (TERM/INT/HUP).
fn install_signals() -> std::io::Result<UnixStream> {
    let (r, w) = UnixStream::pair()?;
    w.set_nonblocking(true)?;
    // The write end lives for the whole process.
    SIG_FD.store(w.into_raw_fd(), Ordering::Relaxed);
    for sig in [libc::SIGCHLD, libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // SAFETY: zeroed sigaction plus an empty mask and a handler that only writes.
        let rc = unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
            sa.sa_flags = libc::SA_RESTART | libc::SA_NOCLDSTOP;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(sig, &sa, std::ptr::null_mut())
        };
        if rc != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(r)
}
