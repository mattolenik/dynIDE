//! Length-prefixed frames with SCM_RIGHTS fds over a unix stream socket.
//! Frame: `len: u32 BE` (bytes after it) | `kind: u8` | `nfds: u8` | body.

use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::time::Duration;

pub const MAX_BODY: usize = 64 << 20;
pub const MAX_FDS: usize = 64;
const HEADER: usize = 6;

pub mod kind {
    pub const HELLO: u8 = 0x01;
    pub const HOLD: u8 = 0x02;
    pub const UPDATE: u8 = 0x03;
    pub const DROP: u8 = 0x04;
    pub const RESTORED: u8 = 0x05;
    pub const PREPARED: u8 = 0x06;
    pub const REPLY: u8 = 0x07;
    pub const FRESH: u8 = 0x41;
    pub const ADOPT: u8 = 0x42;
    pub const ADOPT_END: u8 = 0x43;
    pub const PREPARE: u8 = 0x44;
    pub const RELEASE: u8 = 0x45;
    pub const THAW: u8 = 0x46;
    pub const REQUEST: u8 = 0x47;
    pub const CTL_RESTART: u8 = 0x81;
    pub const CTL_STATUS: u8 = 0x82;
    pub const CTL_REQUEST: u8 = 0x83;
    pub const CTL_RESULT: u8 = 0xC1;
    pub const CTL_STATUS_REPLY: u8 = 0xC2;
    pub const CTL_REPLY: u8 = 0xC3;
}

#[derive(Debug)]
pub struct Frame {
    pub kind: u8,
    pub body: Vec<u8>,
    pub fds: Vec<OwnedFd>,
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.to_string())
}

#[cfg(target_os = "linux")]
const SEND_FLAGS: libc::c_int = libc::MSG_NOSIGNAL;
#[cfg(not(target_os = "linux"))]
const SEND_FLAGS: libc::c_int = 0;

#[cfg(target_os = "linux")]
const RECV_FLAGS: libc::c_int = libc::MSG_CMSG_CLOEXEC;
#[cfg(not(target_os = "linux"))]
const RECV_FLAGS: libc::c_int = 0;

#[cfg(target_os = "linux")]
fn cloexec(_fd: RawFd) {}
#[cfg(not(target_os = "linux"))]
fn cloexec(fd: RawFd) {
    // SAFETY: plain fcntl on an fd we just received.
    unsafe {
        let f = libc::fcntl(fd, libc::F_GETFD);
        if f >= 0 {
            libc::fcntl(fd, libc::F_SETFD, f | libc::FD_CLOEXEC);
        }
    }
}

/// Blocking send of one frame. The fds ride on the first `sendmsg`.
pub fn send_frame(
    sock: BorrowedFd<'_>,
    kind: u8,
    body: &[u8],
    fds: &[BorrowedFd<'_>],
) -> io::Result<()> {
    if fds.len() > MAX_FDS || body.len() > MAX_BODY {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "frame too large",
        ));
    }
    let mut buf = Vec::with_capacity(HEADER + body.len());
    buf.extend(((body.len() + 2) as u32).to_be_bytes());
    buf.push(kind);
    buf.push(fds.len() as u8);
    buf.extend(body);

    let raw: Vec<RawFd> = fds.iter().map(|f| f.as_raw_fd()).collect();
    let fd_bytes = std::mem::size_of_val(raw.as_slice());
    // SAFETY: CMSG_SPACE is a pure size computation.
    let mut control = vec![0u8; unsafe { libc::CMSG_SPACE(fd_bytes as u32) } as usize];
    let mut sent = 0;
    let mut first = true;
    while sent < buf.len() {
        let iov = libc::iovec {
            iov_base: buf[sent..].as_ptr() as *mut libc::c_void,
            iov_len: buf.len() - sent,
        };
        // SAFETY: zeroed msghdr is valid; pointers below outlive the call.
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &iov as *const _ as *mut libc::iovec;
        msg.msg_iovlen = 1;
        if first && !raw.is_empty() {
            msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
            msg.msg_controllen = control.len() as _;
            // SAFETY: control is CMSG_SPACE(fd_bytes) so the first header and data fit.
            unsafe {
                let c = libc::CMSG_FIRSTHDR(&msg);
                if c.is_null() {
                    return Err(io::Error::other("no cmsg space"));
                }
                (*c).cmsg_level = libc::SOL_SOCKET;
                (*c).cmsg_type = libc::SCM_RIGHTS;
                (*c).cmsg_len = libc::CMSG_LEN(fd_bytes as u32) as _;
                std::ptr::copy_nonoverlapping(
                    raw.as_ptr() as *const u8,
                    libc::CMSG_DATA(c),
                    fd_bytes,
                );
            }
        }
        // SAFETY: msg is fully initialised above.
        let n = unsafe { libc::sendmsg(sock.as_raw_fd(), &msg, SEND_FLAGS) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        first = false;
        sent += n as usize;
    }
    Ok(())
}

/// Reads up to `out.len()` bytes with recvmsg, appending any received fds.
/// Returns bytes read (0 = EOF).
fn recv_some(sock: RawFd, out: &mut [u8], fds: &mut Vec<OwnedFd>) -> io::Result<usize> {
    // SAFETY: pure size computation.
    let mut control = vec![0u8; unsafe { libc::CMSG_SPACE((MAX_FDS * 4) as u32) } as usize];
    loop {
        let mut iov = libc::iovec {
            iov_base: out.as_mut_ptr() as *mut libc::c_void,
            iov_len: out.len(),
        };
        // SAFETY: zeroed msghdr is valid; buffers outlive the call.
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = control.as_mut_ptr() as *mut libc::c_void;
        msg.msg_controllen = control.len() as _;
        // SAFETY: msg points at live buffers.
        let n = unsafe { libc::recvmsg(sock, &mut msg, RECV_FLAGS) };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        // SAFETY: walk cmsgs the kernel wrote; each fd is owned by us from here on,
        // so any later error path closes it by dropping.
        unsafe {
            let end = control.as_ptr() as usize + msg.msg_controllen as usize;
            let mut c = libc::CMSG_FIRSTHDR(&msg);
            while !c.is_null() {
                if (*c).cmsg_level == libc::SOL_SOCKET && (*c).cmsg_type == libc::SCM_RIGHTS {
                    let data = libc::CMSG_DATA(c);
                    let avail = end.saturating_sub(data as usize);
                    let len = ((*c).cmsg_len as usize)
                        .saturating_sub(libc::CMSG_LEN(0) as usize)
                        .min(avail);
                    for i in 0..len / 4 {
                        let fd = std::ptr::read_unaligned((data as *const RawFd).add(i));
                        cloexec(fd);
                        fds.push(OwnedFd::from_raw_fd(fd));
                    }
                }
                c = libc::CMSG_NXTHDR(&msg, c);
            }
        }
        if msg.msg_flags & libc::MSG_CTRUNC != 0 {
            return Err(bad("fd control message truncated"));
        }
        return Ok(n as usize);
    }
}

/// Blocking receive. `Ok(None)` on clean EOF before a header.
pub fn recv_frame(sock: BorrowedFd<'_>) -> io::Result<Option<Frame>> {
    let raw = sock.as_raw_fd();
    let mut fds = Vec::new();
    let mut hdr = [0u8; HEADER];
    let mut got = 0;
    while got < HEADER {
        // Never read past the header: the next frame's fds must stay queued.
        let n = recv_some(raw, &mut hdr[got..], &mut fds)?;
        if n == 0 {
            if got == 0 && fds.is_empty() {
                return Ok(None);
            }
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        got += n;
    }
    let len = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as usize;
    if !(2..=MAX_BODY + 2).contains(&len) {
        return Err(bad("bad frame length"));
    }
    if hdr[5] as usize != fds.len() || fds.len() > MAX_FDS {
        return Err(bad("fd count mismatch"));
    }
    let mut body = vec![0u8; len - 2];
    let mut off = 0;
    while off < body.len() {
        // SAFETY: reading into the unfilled tail of body.
        let n = unsafe {
            libc::read(
                raw,
                body[off..].as_mut_ptr() as *mut libc::c_void,
                body.len() - off,
            )
        };
        if n < 0 {
            let e = io::Error::last_os_error();
            if e.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        if n == 0 {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        off += n as usize;
    }
    Ok(Some(Frame {
        kind: hdr[4],
        body,
        fds,
    }))
}

pub fn put_key(buf: &mut Vec<u8>, key: &[u8]) {
    buf.extend((key.len() as u16).to_be_bytes());
    buf.extend(key);
}

/// Splits `klen: u16 | key | rest` into `(key, rest)`.
pub fn take_key(body: &[u8]) -> io::Result<(&[u8], &[u8])> {
    let n = body.get(..2).ok_or_else(|| bad("short key"))?;
    let n = u16::from_be_bytes([n[0], n[1]]) as usize;
    if body.len() < 2 + n {
        return Err(bad("short key"));
    }
    Ok((&body[2..2 + n], &body[2 + n..]))
}

pub fn set_timeouts(sock: BorrowedFd<'_>, d: Duration) -> io::Result<()> {
    let tv = libc::timeval {
        tv_sec: d.as_secs() as _,
        tv_usec: d.subsec_micros() as _,
    };
    for opt in [libc::SO_RCVTIMEO, libc::SO_SNDTIMEO] {
        // SAFETY: tv is a valid timeval for the duration of the call.
        let r = unsafe {
            libc::setsockopt(
                sock.as_raw_fd(),
                libc::SOL_SOCKET,
                opt,
                &tv as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::timeval>() as libc::socklen_t,
            )
        };
        if r < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::fd::{AsFd, AsRawFd};
    use std::os::unix::net::UnixStream;

    fn pair() -> (UnixStream, UnixStream) {
        UnixStream::pair().unwrap()
    }

    #[test]
    fn roundtrip_no_fds() {
        let (a, b) = pair();
        send_frame(a.as_fd(), 0x07, b"abc", &[]).unwrap();
        let f = recv_frame(b.as_fd()).unwrap().unwrap();
        assert_eq!(
            (f.kind, f.body.as_slice(), f.fds.len()),
            (0x07, &b"abc"[..], 0)
        );
    }

    #[test]
    fn roundtrip_64_pipe_fds() {
        let (a, b) = pair();
        let pipes: Vec<(UnixStream, UnixStream)> = (0..64).map(|_| pair()).collect();
        let fds: Vec<_> = pipes.iter().map(|p| p.1.as_fd()).collect();
        send_frame(a.as_fd(), 0x02, b"k", &fds).unwrap();
        let f = recv_frame(b.as_fd()).unwrap().unwrap();
        assert_eq!(f.fds.len(), 64);
        for (i, fd) in f.fds.into_iter().enumerate() {
            let mut w = UnixStream::from(fd);
            w.write_all(&[i as u8]).unwrap();
            let mut r = &pipes[i].0;
            let mut byte = [0u8];
            r.read_exact(&mut byte).unwrap();
            assert_eq!(byte[0], i as u8);
        }
    }

    #[test]
    fn big_body_16mib() {
        let (a, b) = pair();
        let body: Vec<u8> = (0..16usize << 20).map(|i| (i % 251) as u8).collect();
        let want = body.clone();
        let t = std::thread::spawn(move || send_frame(a.as_fd(), 0x42, &body, &[]).unwrap());
        let f = recv_frame(b.as_fd()).unwrap().unwrap();
        t.join().unwrap();
        assert!(f.body == want);
    }

    #[test]
    fn two_frames_with_fds_do_not_merge() {
        let (a, b) = pair();
        let (x, y, z) = (pair(), pair(), pair());
        send_frame(a.as_fd(), 1, b"A", &[x.0.as_fd()]).unwrap();
        send_frame(a.as_fd(), 2, b"B", &[y.0.as_fd(), z.0.as_fd()]).unwrap();
        let fa = recv_frame(b.as_fd()).unwrap().unwrap();
        let fb = recv_frame(b.as_fd()).unwrap().unwrap();
        assert_eq!((fa.kind, fa.fds.len()), (1, 1));
        assert_eq!((fb.kind, fb.fds.len()), (2, 2));
    }

    #[test]
    fn eof_before_header_is_none() {
        let (a, b) = pair();
        drop(a);
        assert!(recv_frame(b.as_fd()).unwrap().is_none());
    }

    #[test]
    fn eof_mid_frame_errors() {
        let (mut a, b) = pair();
        a.write_all(&[0, 0, 0, 12, 7, 0, 1, 2]).unwrap();
        drop(a);
        let e = recv_frame(b.as_fd()).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::UnexpectedEof);
        let (mut a, b) = pair();
        a.write_all(&[0, 0]).unwrap();
        drop(a);
        assert_eq!(
            recv_frame(b.as_fd()).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    }

    #[test]
    fn too_many_fds_rejected_on_send() {
        let (a, _b) = pair();
        let p = pair();
        let fds: Vec<_> = (0..65).map(|_| p.0.as_fd()).collect();
        let e = send_frame(a.as_fd(), 2, b"", &fds).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn oversize_len_rejected_on_recv() {
        let (mut a, b) = pair();
        let len = (MAX_BODY + 3) as u32;
        let mut h = len.to_be_bytes().to_vec();
        h.extend([2, 0]);
        a.write_all(&h).unwrap();
        let e = recv_frame(b.as_fd()).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn nfds_mismatch_rejected_and_fds_closed() {
        let (a, b) = pair();
        let p = pair();
        // header claims 2 fds, carries 1
        let hdr = [0, 0, 0, 2, 2, 2];
        let fd = [p.0.as_raw_fd()];
        raw_send(a.as_raw_fd(), &hdr, &fd);
        let e = recv_frame(b.as_fd()).unwrap_err();
        assert_eq!(e.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn received_fds_are_cloexec() {
        let (a, b) = pair();
        let p = pair();
        send_frame(a.as_fd(), 2, b"", &[p.0.as_fd()]).unwrap();
        let f = recv_frame(b.as_fd()).unwrap().unwrap();
        let flags = unsafe { libc::fcntl(f.fds[0].as_raw_fd(), libc::F_GETFD) };
        assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0);
    }

    #[test]
    fn key_roundtrip() {
        let mut buf = Vec::new();
        put_key(&mut buf, b"pane/7");
        buf.extend(b"blob");
        let (k, rest) = take_key(&buf).unwrap();
        assert_eq!((k, rest), (&b"pane/7"[..], &b"blob"[..]));
        assert!(take_key(&[0, 9, 1]).is_err());
    }

    fn raw_send(sock: i32, data: &[u8], fds: &[i32]) {
        let iov = libc::iovec {
            iov_base: data.as_ptr() as *mut _,
            iov_len: data.len(),
        };
        let mut ctl = vec![0u8; unsafe { libc::CMSG_SPACE(4 * fds.len() as u32) } as usize];
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &iov as *const _ as *mut _;
        msg.msg_iovlen = 1;
        msg.msg_control = ctl.as_mut_ptr() as *mut _;
        msg.msg_controllen = ctl.len() as _;
        unsafe {
            let c = libc::CMSG_FIRSTHDR(&msg);
            (*c).cmsg_level = libc::SOL_SOCKET;
            (*c).cmsg_type = libc::SCM_RIGHTS;
            (*c).cmsg_len = libc::CMSG_LEN(4 * fds.len() as u32) as _;
            std::ptr::copy_nonoverlapping(
                fds.as_ptr() as *const u8,
                libc::CMSG_DATA(c),
                4 * fds.len(),
            );
            assert!(libc::sendmsg(sock, &msg, 0) >= 0);
        }
    }
}
