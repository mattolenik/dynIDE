//! Host tty guard: save the termios at start, put it back at exit, and write
//! the restore sequence only when the last primary VM did not exit 0. Attached
//! launches also run behind `dynide/scripts/tty_guard.sh`, which backs up this
//! restore when the broker itself is killed.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

/// tty_guard.sh's sequence: alt-screen sandwich around a kitty pop, mouse,
/// paste and focus off, link/SGR/cursor reset, autowrap on, leave alt screen.
pub const RESTORE: &[u8] = b"\x1b[?1049h\x1b[<u\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1016l\x1b[?2004l\x1b[?1004l\x1b]8;;\x1b\\\x1b[0m\x1b[0 q\x1b[?25h\x1b[?7h\x1b[?1049l";

pub struct Guard {
    tty: File,
    saved: libc::termios,
}

impl Guard {
    /// `None` when there is no terminal (headless): the guard then does nothing.
    pub fn open_path(path: impl AsRef<Path>) -> Option<Guard> {
        // std adds O_CLOEXEC.
        let tty = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOCTTY)
            .open(path)
            .ok()?;
        // SAFETY: zeroed termios is a valid out-parameter for tcgetattr.
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out pointer.
        if unsafe { libc::tcgetattr(tty.as_raw_fd(), &mut saved) } != 0 {
            return None;
        }
        Some(Guard { tty, saved })
    }

    pub fn restore(&self, crashed: bool) {
        // SAFETY: valid fd and a termios read from the same tty.
        unsafe { libc::tcsetattr(self.tty.as_raw_fd(), libc::TCSANOW, &self.saved) };
        if crashed {
            let _ = (&self.tty).write_all(RESTORE);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    use std::io::Read;
    use std::os::fd::FromRawFd;

    fn lflag(f: &File) -> libc::tcflag_t {
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::tcgetattr(f.as_raw_fd(), &mut t) }, 0);
        // The kernel sets PENDIN itself when canonical mode comes back.
        t.c_lflag & !libc::PENDIN
    }

    fn make_raw(f: &File) {
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        unsafe {
            libc::tcgetattr(f.as_raw_fd(), &mut t);
            libc::cfmakeraw(&mut t);
            libc::tcsetattr(f.as_raw_fd(), libc::TCSANOW, &t);
        }
    }

    /// Everything the master can read right now.
    fn drain(master: &mut File) -> Vec<u8> {
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            let mut p = libc::pollfd {
                fd: master.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            if unsafe { libc::poll(&mut p, 1, 200) } <= 0 {
                return out;
            }
            let n = master.read(&mut buf).unwrap();
            out.extend(&buf[..n]);
        }
    }

    #[test]
    fn tty_guard_restores_termios() {
        let mut master = unsafe {
            let fd = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
            assert!(fd >= 0);
            assert_eq!(libc::grantpt(fd), 0);
            assert_eq!(libc::unlockpt(fd), 0);
            File::from_raw_fd(fd)
        };
        let path = unsafe { CStr::from_ptr(libc::ptsname(master.as_raw_fd())) }
            .to_str()
            .unwrap()
            .to_string();
        let slave = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOCTTY)
            .open(&path)
            .unwrap();
        let before = lflag(&slave);
        let g = Guard::open_path(&path).unwrap();

        make_raw(&slave);
        assert_ne!(lflag(&slave), before);
        g.restore(false);
        assert_eq!(lflag(&slave), before);
        assert!(drain(&mut master).is_empty());

        make_raw(&slave);
        g.restore(true);
        assert_eq!(lflag(&slave), before);
        assert_eq!(drain(&mut master), RESTORE);

        assert!(Guard::open_path("/nonexistent/tty").is_none());
    }
}
