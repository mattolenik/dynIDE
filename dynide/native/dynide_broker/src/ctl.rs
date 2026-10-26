//! Client side of `kernel-restart` and `status`.

use dynide_fdpass::{self as fp, kind};
use std::ffi::OsString;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

/// One request, one reply. Exit 2 when no broker answers.
fn call(sock: &Path, k: u8, body: &[u8], timeout: Option<Duration>) -> Result<Vec<u8>, i32> {
    let Ok(s) = UnixStream::connect(sock) else {
        eprintln!("dynide: no broker at {}", sock.display());
        return Err(2);
    };
    let reply = (|| -> std::io::Result<dynide_fdpass::Frame> {
        if let Some(t) = timeout {
            fp::set_timeouts(s.as_fd(), t)?;
        }
        fp::send_frame(s.as_fd(), k, body, &[])?;
        fp::recv_frame(s.as_fd())?.ok_or_else(|| std::io::ErrorKind::UnexpectedEof.into())
    })();
    match reply {
        Ok(f) => Ok(f.body),
        Err(e) => {
            eprintln!("dynide: broker at {}: {e}", sock.display());
            Err(1)
        }
    }
}

/// `argv` empty: the broker's current VM argv; else the target's (kept on success).
pub fn restart(sock: &Path, argv: &[OsString]) -> i32 {
    // No timeout: a target boot may recompile the kernel (120 s on the broker side).
    match call(
        sock,
        kind::CTL_RESTART,
        &crate::broker::encode_argv(argv),
        None,
    ) {
        Ok(body) => {
            let ok = body.first() == Some(&1);
            println!("{}", String::from_utf8_lossy(body.get(1..).unwrap_or(&[])));
            if ok {
                0
            } else {
                1
            }
        }
        Err(code) => code,
    }
}

pub fn status(sock: &Path) -> i32 {
    match call(sock, kind::CTL_STATUS, &[], Some(Duration::from_secs(5))) {
        Ok(body) => {
            print!("{}", String::from_utf8_lossy(&body));
            0
        }
        Err(code) => code,
    }
}
