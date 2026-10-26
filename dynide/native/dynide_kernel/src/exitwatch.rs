//! Exit watching for a process that is not (or may not be) our child: adopted panes after
//! a VM restart. Never reaps; init/launchd (or the old VM) does that.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

fn last_err() -> io::Error {
    io::Error::last_os_error()
}

/// A registered exit watch on one pid. `ESRCH` from `watch` means the process is gone.
pub struct Watch {
    #[cfg(target_os = "macos")]
    pid: libc::pid_t,
    /// kqueue (macOS) or pidfd (Linux).
    fd: OwnedFd,
}

/// Retries `f` while it fails with EINTR.
fn retry(mut f: impl FnMut() -> libc::c_int) -> io::Result<libc::c_int> {
    loop {
        let r = f();
        if r >= 0 {
            return Ok(r);
        }
        let e = last_err();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

#[cfg(target_os = "macos")]
fn proc_event(pid: libc::pid_t, flags: u16) -> libc::kevent {
    libc::kevent {
        ident: pid as libc::uintptr_t,
        filter: libc::EVFILT_PROC,
        flags,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    }
}

#[cfg(target_os = "macos")]
pub fn watch(pid: u32) -> io::Result<Watch> {
    let pid = pid as libc::pid_t;
    // SAFETY: plain syscall; the returned fd is owned below.
    let kq = unsafe { libc::kqueue() };
    if kq < 0 {
        return Err(last_err());
    }
    // SAFETY: kqueue(2) just returned this fd and nothing else owns it.
    let fd = unsafe { OwnedFd::from_raw_fd(kq) };
    let change = proc_event(pid, libc::EV_ADD | libc::EV_ONESHOT);
    // SAFETY: one valid changelist entry, no eventlist. ESRCH: the process is gone.
    retry(|| unsafe {
        libc::kevent(
            fd.as_raw_fd(),
            &change,
            1,
            std::ptr::null_mut(),
            0,
            std::ptr::null(),
        )
    })?;
    Ok(Watch { pid, fd })
}

#[cfg(target_os = "macos")]
impl Watch {
    /// Blocks until the process exits.
    pub fn wait(&self) {
        let mut ev = proc_event(0, 0);
        // SAFETY: no changelist; one writable eventlist entry; no timeout.
        let _ = retry(|| unsafe {
            libc::kevent(
                self.fd.as_raw_fd(),
                std::ptr::null(),
                0,
                &mut ev,
                1,
                std::ptr::null(),
            )
        });
    }

    // ponytail: kill(2) by pid has a tiny pid-reuse race between exit and the watcher
    // noticing; macOS has no pidfd. Acceptable for interactive panes.
    pub fn signal(&self, signo: i32) -> io::Result<()> {
        // SAFETY: plain syscall.
        retry(|| unsafe { libc::kill(self.pid, signo) }).map(drop)
    }
}

#[cfg(target_os = "linux")]
pub fn watch(pid: u32) -> io::Result<Watch> {
    let pid = pid as libc::pid_t;
    // SAFETY: plain syscall; pidfd_open always sets O_CLOEXEC. ESRCH: the process is gone
    // (a zombie still opens, and polls readable at once).
    let r = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if r < 0 {
        return Err(last_err());
    }
    // SAFETY: pidfd_open just returned this fd and nothing else owns it.
    let fd = unsafe { OwnedFd::from_raw_fd(r as libc::c_int) };
    Ok(Watch { fd })
}

#[cfg(target_os = "linux")]
impl Watch {
    /// Blocks until the process exits (the pidfd polls readable).
    pub fn wait(&self) {
        let mut p = libc::pollfd {
            fd: self.fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one valid, exclusively borrowed pollfd; no timeout.
        let _ = retry(|| unsafe { libc::poll(&mut p, 1, -1) });
    }

    /// Signals through the pidfd, so a recycled pid is never hit.
    pub fn signal(&self, signo: i32) -> io::Result<()> {
        let fd = self.fd.as_raw_fd();
        // SAFETY: plain syscall with a pidfd we own and a null siginfo.
        retry(|| unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                fd,
                signo,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            ) as libc::c_int
        })
        .map(drop)
    }
}

/// When `pid` started, as an opaque number that changes when the pid is reused: a handoff
/// carries it so the next owner never watches or signals a recycled pid. `ESRCH`: gone.
#[cfg(target_os = "macos")]
pub fn start_time(pid: u32) -> io::Result<u64> {
    // SAFETY: zeroed proc_bsdinfo is a valid out-buffer for proc_pidinfo.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: the buffer is valid and exactly `size` bytes.
    let r = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    if r != size {
        let e = last_err();
        return Err(match e.raw_os_error() {
            Some(0) | None => io::Error::from_raw_os_error(libc::ESRCH),
            _ => e,
        });
    }
    Ok(info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
}

/// Field 22 of `/proc/<pid>/stat` (start time in clock ticks since boot).
#[cfg(target_os = "linux")]
pub fn start_time(pid: u32) -> io::Result<u64> {
    let stat = match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Ok(s) => s,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Err(io::Error::from_raw_os_error(libc::ESRCH))
        }
        Err(e) => return Err(e),
    };
    // comm (field 2) may contain spaces and parens: fields resume after the last ')'.
    stat.rsplit_once(')')
        .and_then(|(_, rest)| rest.split_whitespace().nth(22 - 3))
        .and_then(|f| f.parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "bad /proc stat"))
}
