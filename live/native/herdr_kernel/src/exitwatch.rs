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
