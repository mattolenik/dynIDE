//! The VM side of the broker socket: one unix stream carrying `dynide_fdpass` frames.
//! A reader thread hands each received frame to a `LinkSink`, then reports the close once.

use std::io;
use std::net::Shutdown;
use std::os::fd::{AsFd, BorrowedFd};
use std::os::unix::net::UnixStream;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

pub use dynide_fdpass::Frame;
use dynide_fdpass::{recv_frame, send_frame};

use crate::pty::panic_msg;
use crate::vt::lock;

pub const SEND_TIMEOUT: Duration = Duration::from_secs(5);

/// Receives what the reader thread reads.
pub trait LinkSink: Send + 'static {
    fn frame(&self, f: Frame);
    /// Called exactly once, last. `None` is a clean EOF; `Some` an io error or a panic.
    fn closed(&self, reason: Option<String>);
}

pub struct Link {
    sock: UnixStream,
    /// Serializes whole frames so concurrent senders never interleave.
    send: Mutex<()>,
}

impl Link {
    /// Connects (CLOEXEC, via std) with `send_timeout` per `sendmsg` (`SEND_TIMEOUT` in the
    /// VM); receives have none.
    pub fn connect(path: &Path, send_timeout: Duration) -> io::Result<Link> {
        let sock = UnixStream::connect(path)?;
        sock.set_write_timeout(Some(send_timeout))?;
        no_sigpipe(sock.as_fd())?;
        Ok(Link {
            sock,
            send: Mutex::new(()),
        })
    }

    /// Starts the reader thread on a dup of the socket.
    pub fn start(&self, sink: impl LinkSink) -> io::Result<()> {
        let sock = self.sock.try_clone()?;
        std::thread::Builder::new()
            .name("dynide-link-reader".into())
            .spawn(move || {
                let reason = catch_unwind(AssertUnwindSafe(|| loop {
                    match recv_frame(sock.as_fd()) {
                        Ok(Some(f)) => sink.frame(f),
                        Ok(None) => return None,
                        Err(e) => return Some(e.to_string()),
                    }
                }))
                .unwrap_or_else(|p| Some(format!("panic: {}", panic_msg(p))));
                // A bad frame ends the stream: later sends fail too, never half-open.
                let _ = sock.shutdown(Shutdown::Both);
                let _ = catch_unwind(AssertUnwindSafe(|| sink.closed(reason)));
            })
            .map(drop)
    }

    /// Sends one frame. An io error may have left a partial frame on the stream, so it closes
    /// the link (the reader then reports the close); a frame rejected as too large before any
    /// write (`InvalidInput`) does not.
    // ponytail: senders queue on one mutex, each bounded by the timeout per sendmsg (not per
    // frame); a send queue on a writer thread if callers must never wait behind a big frame.
    pub fn send(&self, kind: u8, body: &[u8], fds: &[BorrowedFd<'_>]) -> io::Result<()> {
        let _g = lock(&self.send);
        send_frame(self.sock.as_fd(), kind, body, fds).inspect_err(|e| {
            if e.kind() != io::ErrorKind::InvalidInput {
                self.close();
            }
        })
    }

    /// Shuts the socket down both ways; the reader then sees EOF. Idempotent.
    pub fn close(&self) {
        let _ = self.sock.shutdown(Shutdown::Both);
    }
}

// Linux sends with MSG_NOSIGNAL (in dynide_fdpass); macOS needs the socket option.
#[cfg(target_os = "macos")]
fn no_sigpipe(sock: BorrowedFd<'_>) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let on: libc::c_int = 1;
    // SAFETY: `on` is a valid c_int for the duration of the call.
    let r = unsafe {
        libc::setsockopt(
            sock.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            &on as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    match r {
        0 => Ok(()),
        _ => Err(io::Error::last_os_error()),
    }
}

#[cfg(not(target_os = "macos"))]
fn no_sigpipe(_sock: BorrowedFd<'_>) -> io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use dynide_fdpass::{kind, recv_frame, send_frame};
    use std::io::{Read, Write};
    use std::os::fd::AsFd;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::sync::mpsc;
    use std::time::Duration;

    enum Seen {
        Frame(u8, Vec<u8>, usize),
        Closed(Option<String>),
    }

    struct TestSink(Mutex<mpsc::Sender<Seen>>);

    impl LinkSink for TestSink {
        fn frame(&self, f: Frame) {
            let _ = lock(&self.0).send(Seen::Frame(f.kind, f.body, f.fds.len()));
        }
        fn closed(&self, reason: Option<String>) {
            let _ = lock(&self.0).send(Seen::Closed(reason));
        }
    }

    fn listener(name: &str) -> (UnixListener, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!("hl-{name}-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        (UnixListener::bind(&path).unwrap(), path)
    }

    #[test]
    fn frames_and_fds_reach_the_sink() {
        let (l, path) = listener("frames");
        let link = Link::connect(&path, SEND_TIMEOUT).unwrap();
        let (tx, rx) = mpsc::channel();
        link.start(TestSink(Mutex::new(tx))).unwrap();
        let (peer, _) = l.accept().unwrap();
        std::fs::remove_file(&path).unwrap();

        let (p1, p2) = (UnixStream::pair().unwrap(), UnixStream::pair().unwrap());
        send_frame(
            peer.as_fd(),
            kind::ADOPT,
            b"k",
            &[p1.0.as_fd(), p2.0.as_fd()],
        )
        .unwrap();
        send_frame(peer.as_fd(), kind::FRESH, b"", &[]).unwrap();
        let t = Duration::from_secs(5);
        match rx.recv_timeout(t).unwrap() {
            Seen::Frame(k, b, n) => assert_eq!((k, b.as_slice(), n), (kind::ADOPT, &b"k"[..], 2)),
            Seen::Closed(r) => panic!("closed early: {r:?}"),
        }
        match rx.recv_timeout(t).unwrap() {
            Seen::Frame(k, b, n) => assert_eq!((k, b.len(), n), (kind::FRESH, 0, 0)),
            Seen::Closed(r) => panic!("closed early: {r:?}"),
        }

        let pipe = UnixStream::pair().unwrap();
        link.send(kind::HOLD, b"x", &[pipe.1.as_fd()]).unwrap();
        let f = recv_frame(peer.as_fd()).unwrap().unwrap();
        assert_eq!(
            (f.kind, f.body.as_slice(), f.fds.len()),
            (kind::HOLD, &b"x"[..], 1)
        );
        let mut w = UnixStream::from(f.fds.into_iter().next().unwrap());
        w.write_all(b"z").unwrap();
        let mut byte = [0u8];
        (&pipe.0).read_exact(&mut byte).unwrap();
        assert_eq!(&byte, b"z");

        drop(peer);
        assert!(matches!(rx.recv_timeout(t).unwrap(), Seen::Closed(None)));
        assert!(rx.recv_timeout(Duration::from_millis(100)).is_err());
    }

    #[test]
    fn failed_send_closes_the_link() {
        let (l, path) = listener("stall");
        let link = Link::connect(&path, Duration::from_millis(100)).unwrap();
        let (tx, rx) = mpsc::channel();
        link.start(TestSink(Mutex::new(tx))).unwrap();
        let (_peer, _) = l.accept().unwrap();
        std::fs::remove_file(&path).unwrap();

        // The peer never reads: 16 MiB overflows the socket buffer, so the send times out
        // part-way through the frame.
        let body = vec![0u8; 16 << 20];
        assert!(link.send(kind::HOLD, &body, &[]).is_err());
        let closed = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(matches!(closed, Seen::Closed(_)));
        assert!(link.send(kind::FRESH, b"", &[]).is_err());
    }
}
