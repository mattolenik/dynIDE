//! Real VM spawning: `<vm argv>` with inherited cwd, stdio, controlling
//! terminal and process group (so SIGWINCH and a terminal ^C reach it), plus
//! `HERDR_BROKER_SOCK` and `HERDR_LIVE_GEN`. The elixir/erl scripts exec down
//! to beam.smp, so the spawned pid is the VM pid.

use crate::broker::{Role, Spawner};
use std::ffi::OsString;
use std::io;
use std::path::PathBuf;
use std::process::Command;

pub struct Real {
    pub argv: Vec<OsString>,
    pub sock: PathBuf,
}

impl Spawner for Real {
    fn spawn(&mut self, gen: u64, _role: Role) -> io::Result<u32> {
        let (prog, args) = self
            .argv
            .split_first()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "empty vm argv"))?;
        // Dropping the Child neither kills nor waits; the broker reaps with waitpid.
        let child = Command::new(prog)
            .args(args)
            .env("HERDR_BROKER_SOCK", &self.sock)
            .env("HERDR_LIVE_GEN", gen.to_string())
            .spawn()?;
        Ok(child.id())
    }

    fn signal(&mut self, pid: u32, sig: i32) {
        // The broker only signals pids it has not reaped yet, so no recycling.
        // SAFETY: plain kill(2).
        unsafe { libc::kill(pid as libc::pid_t, sig) };
    }

    fn reap(&mut self) -> Vec<(u32, i32)> {
        let mut out = Vec::new();
        loop {
            let mut st = 0;
            // SAFETY: plain waitpid(2) with a valid out pointer.
            let pid = unsafe { libc::waitpid(-1, &mut st, libc::WNOHANG) };
            if pid <= 0 {
                return out;
            }
            let code = if libc::WIFEXITED(st) {
                libc::WEXITSTATUS(st)
            } else {
                -libc::WTERMSIG(st)
            };
            out.push((pid as u32, code));
        }
    }
}
