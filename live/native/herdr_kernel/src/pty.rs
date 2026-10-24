//! PTY runtime: reader, writer and waiter threads. Raw PTY bytes never leave the kernel;
//! the reader feeds ghostty and emits only damage generations and structured events.

use std::any::Any;
use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, CommandBuilder, PtySize};

use crate::splitter::{Seq, Splitter};
use crate::vt::{lock, Vt};

const READ_CHUNK: usize = 16 * 1024;
const DAMAGE_INTERVAL: Duration = Duration::from_millis(4);
const WRITE_CAP: usize = 1024 * 1024;
const FINAL_DRAIN: usize = 64 * 1024;
/// How often a writer blocked on a full PTY rechecks whether the pane closed.
// ponytail: tick poll, so close latency is <= 50 ms; add a writer wake pipe if that matters.
const WRITER_TICK_MS: i32 = 50;
/// OSC and DCS events sent per damage window; the rest are dropped.
// ponytail: fixed cap with silent drop; add a dropped-count event if a consumer needs to know.
const EVENT_CAP_PER_WINDOW: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExitStatus {
    Code(i32),
    Signal(i32),
    Panic(String),
    /// The real status was lost (e.g. someone else reaped the child).
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Damage(u64),
    Exit(ExitStatus),
    Osc {
        code: u32,
        payload: Vec<u8>,
        truncated: bool,
    },
    Dcs {
        payload: Vec<u8>,
        truncated: bool,
    },
    Bell,
    Title(Vec<u8>),
    Pwd(Vec<u8>),
}

pub trait EventSink: Send + Sync + 'static {
    fn send(&self, ev: Event);
}

#[derive(Debug, Clone)]
pub struct SpawnOptions {
    pub id: u64,
    pub cmd: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<String>,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteError {
    Backpressure,
    Closed,
}

#[derive(Default)]
struct Queue {
    bufs: VecDeque<Vec<u8>>,
    bytes: usize,
    closed: bool,
}

/// Writer queue. Shared with ghostty's write-pty callback, so it must not own the `Vt`.
#[derive(Default)]
struct Writer {
    q: Mutex<Queue>,
    cv: Condvar,
}

impl Writer {
    /// `cap` applies to BEAM writes; a write is accepted whenever the queue is empty.
    fn push(&self, b: &[u8], cap: Option<usize>) -> Result<(), WriteError> {
        let mut q = lock(&self.q);
        if q.closed {
            return Err(WriteError::Closed);
        }
        if cap.is_some_and(|cap| q.bytes > 0 && q.bytes + b.len() > cap) {
            return Err(WriteError::Backpressure);
        }
        if !b.is_empty() {
            q.bytes += b.len();
            q.bufs.push_back(b.to_vec());
            self.cv.notify_one();
        }
        Ok(())
    }

    fn close(&self) {
        let mut q = lock(&self.q);
        q.closed = true;
        q.bufs = VecDeque::new();
        q.bytes = 0;
        self.cv.notify_all();
    }

    fn is_closed(&self) -> bool {
        lock(&self.q).closed
    }

    /// Next buffer in order, or None once closed.
    fn pop(&self) -> Option<Vec<u8>> {
        let mut q = lock(&self.q);
        loop {
            if q.closed {
                return None;
            }
            if let Some(b) = q.bufs.pop_front() {
                q.bytes -= b.len();
                return Some(b);
            }
            q = self.cv.wait(q).unwrap_or_else(PoisonError::into_inner);
        }
    }
}

/// State shared by the `Pty` handle and its three threads. The threads hold `Arc<Inner>`,
/// never `Arc<Pty>`, so dropping the last `Arc<Pty>` runs `Pty::drop` (SIGHUP) while they
/// are still running; they end on exit, and `Inner` (and its fds) drops with the last one.
struct Inner {
    id: u64,
    pid: libc::pid_t,
    vt: Arc<Vt>,
    sink: Arc<dyn EventSink>,
    /// Dup of the PTY master, O_NONBLOCK. Used by the reader, the writer and `resize`.
    fd: OwnedFd,
    /// Self-pipe the reader polls; both ends live here so a write can never hit EPIPE.
    wake_r: OwnedFd,
    wake_w: OwnedFd,
    writer: Arc<Writer>,
    hidden: AtomicBool,
    exit_sent: AtomicBool,
    /// Set by `fail`; the reader stops after its next wake.
    stop: AtomicBool,
    exit: Mutex<Option<ExitStatus>>,
    /// Reap status. The waiter holds this lock across the reaping `waitpid`, and `signal`
    /// holds it across `kill`, so a signal never reaches a recycled pid.
    reaped: Mutex<Option<ExitStatus>>,
    inject_panic: AtomicBool,
}

fn last_err() -> io::Error {
    io::Error::last_os_error()
}

fn cvt(r: libc::ssize_t) -> io::Result<usize> {
    usize::try_from(r).map_err(|_| last_err())
}

fn read_fd(fd: RawFd, buf: &mut [u8]) -> io::Result<usize> {
    // SAFETY: buf is valid for buf.len() writable bytes.
    cvt(unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) })
}

fn write_fd(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    // SAFETY: buf is valid for buf.len() readable bytes.
    cvt(unsafe { libc::write(fd, buf.as_ptr().cast(), buf.len()) })
}

fn pollfd(fd: RawFd, events: libc::c_short) -> libc::pollfd {
    libc::pollfd {
        fd,
        events,
        revents: 0,
    }
}

/// `poll`, retried on EINTR. Negative fds are ignored by the kernel.
fn poll(fds: &mut [libc::pollfd], timeout_ms: i32) {
    loop {
        // SAFETY: fds is a valid, exclusively borrowed pollfd slice.
        let r = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout_ms) };
        if r >= 0 || last_err().kind() != io::ErrorKind::Interrupted {
            return;
        }
    }
}

fn set_flags(fd: RawFd, get: libc::c_int, set: libc::c_int, flag: libc::c_int) -> io::Result<()> {
    // SAFETY: fcntl on an fd we own, with integer arguments only.
    let flags = unsafe { libc::fcntl(fd, get) };
    if flags < 0 || unsafe { libc::fcntl(fd, set, flags | flag) } < 0 {
        return Err(last_err());
    }
    Ok(())
}

fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: fds has room for the two descriptors pipe(2) writes.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(last_err());
    }
    // SAFETY: pipe(2) just returned these fds and nothing else owns them.
    let (r, w) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    for fd in [&r, &w] {
        set_flags(
            fd.as_raw_fd(),
            libc::F_GETFD,
            libc::F_SETFD,
            libc::FD_CLOEXEC,
        )?;
        set_flags(
            fd.as_raw_fd(),
            libc::F_GETFL,
            libc::F_SETFL,
            libc::O_NONBLOCK,
        )?;
    }
    Ok((r, w))
}

fn wait_status(status: libc::c_int) -> ExitStatus {
    if libc::WIFSIGNALED(status) {
        ExitStatus::Signal(libc::WTERMSIG(status))
    } else {
        ExitStatus::Code(libc::WEXITSTATUS(status))
    }
}

fn panic_msg(p: Box<dyn Any + Send>) -> String {
    match p.downcast::<&str>() {
        Ok(s) => s.to_string(),
        Err(p) => match p.downcast::<String>() {
            Ok(s) => *s,
            Err(_) => "unknown panic".to_string(),
        },
    }
}

impl Inner {
    fn wake(&self) {
        // EAGAIN means a wake is already pending; nothing else can fail here.
        let _ = write_fd(self.wake_w.as_raw_fd(), &[1]);
    }

    fn signal(&self, signo: i32) -> io::Result<()> {
        let reaped = lock(&self.reaped);
        if reaped.is_some() {
            return Ok(());
        }
        // SAFETY: plain syscall; the pid is our unreaped child (see `reaped`).
        if unsafe { libc::kill(self.pid, signo) } == 0 {
            return Ok(());
        }
        match last_err() {
            e if e.raw_os_error() == Some(libc::ESRCH) => Ok(()),
            e => Err(e),
        }
    }

    fn send_exit(&self, status: ExitStatus) {
        if !self.exit_sent.swap(true, Ordering::AcqRel) {
            *lock(&self.exit) = Some(status.clone());
            self.sink.send(Event::Exit(status));
        }
    }

    /// A kernel thread panicked: report once, kill the child, stop writing.
    fn fail(&self, msg: String) {
        // Close first so a write after `Exit(Panic)` already sees `Closed`.
        self.writer.close();
        self.stop.store(true, Ordering::Release);
        self.send_exit(ExitStatus::Panic(msg));
        let _ = self.signal(libc::SIGKILL);
        self.wake();
    }

    fn damage(&self) {
        self.sink.send(Event::Damage(self.vt.refresh()));
    }

    fn hidden(&self) -> bool {
        self.hidden.load(Ordering::Acquire)
    }

    fn check_injected_panic(&self) {
        if self.inject_panic.load(Ordering::Acquire) {
            self.vt.panic_holding_core();
        }
    }

    fn feed(&self, sp: &mut Splitter, seqs: &mut Vec<Seq>, win: &mut Window, chunk: &[u8]) {
        self.check_injected_panic();
        sp.observe(chunk, seqs);
        // Clipboard and pwd effects are ignored: OSC 52 and OSC 7 arrive via the splitter.
        let fx = self.vt.write(chunk);
        for s in seqs.drain(..) {
            let ev = match s {
                Seq::Osc {
                    code: 0 | 2,
                    payload,
                    ..
                } => {
                    win.title = Some(payload);
                    continue;
                }
                Seq::Osc {
                    code: 7, payload, ..
                } => {
                    win.pwd = Some(payload);
                    continue;
                }
                Seq::Osc { code: 1, .. } => continue,
                _ if win.sent >= EVENT_CAP_PER_WINDOW => continue,
                Seq::Osc {
                    code,
                    payload,
                    truncated,
                } => Event::Osc {
                    code,
                    payload,
                    truncated,
                },
                Seq::Dcs { payload, truncated } => Event::Dcs { payload, truncated },
            };
            win.sent += 1;
            self.sink.send(ev);
        }
        if fx.bells > 0 {
            self.sink.send(Event::Bell);
        }
    }
}

/// Per damage window: title and pwd keep only the last value; OSC and DCS events are
/// capped at `EVENT_CAP_PER_WINDOW`.
#[derive(Default)]
struct Window {
    title: Option<Vec<u8>>,
    pwd: Option<Vec<u8>>,
    sent: usize,
}

impl Window {
    fn pending(&self) -> bool {
        self.title.is_some() || self.pwd.is_some() || self.sent > 0
    }

    fn flush(&mut self, sink: &dyn EventSink) {
        if let Some(t) = self.title.take() {
            sink.send(Event::Title(t));
        }
        if let Some(p) = self.pwd.take() {
            sink.send(Event::Pwd(p));
        }
        self.sent = 0;
    }
}

fn reader_main(inner: &Inner) {
    let fd = inner.fd.as_raw_fd();
    let mut sp = Splitter::new();
    let mut seqs = Vec::new();
    let mut win = Window::default();
    let mut buf = vec![0u8; READ_CHUNK];
    let mut eof = false;
    let mut pending = false;
    let mut last: Option<Instant> = None;
    loop {
        // Pending damage (or window events, which flush even when hidden) waits at most
        // until the interval since the last flush ends.
        let timeout = match (pending || win.pending(), last) {
            (true, Some(t)) => DAMAGE_INTERVAL
                .saturating_sub(t.elapsed())
                .as_micros()
                .div_ceil(1000) as i32,
            _ => -1,
        };
        let mut fds = [
            pollfd(inner.wake_r.as_raw_fd(), libc::POLLIN),
            pollfd(if eof { -1 } else { fd }, libc::POLLIN),
        ];
        poll(&mut fds, timeout);
        inner.check_injected_panic();
        if inner.stop.load(Ordering::Acquire) {
            break;
        }
        if fds[0].revents != 0 {
            while matches!(read_fd(inner.wake_r.as_raw_fd(), &mut buf), Ok(n) if n > 0) {}
            if lock(&inner.reaped).is_some() {
                break;
            }
        }
        if fds[1].revents != 0 {
            match read_fd(fd, &mut buf) {
                Ok(0) => eof = true,
                Ok(n) => {
                    inner.feed(&mut sp, &mut seqs, &mut win, &buf[..n]);
                    pending = true;
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                // A hangup with nothing to read can report EAGAIN; treat it as EOF.
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    eof = fds[1].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0;
                }
                // EIO: the slave side is closed.
                Err(_) => eof = true,
            }
        }
        if inner.hidden() {
            pending = false;
        }
        // Leading edge after idle, then at most one damage per interval; a quiescent tail
        // is flushed when the interval ends (poll timeout above), with no further input.
        let due = pending || win.pending();
        if due && (eof || last.is_none_or(|t| t.elapsed() >= DAMAGE_INTERVAL)) {
            win.flush(&*inner.sink);
            if pending {
                inner.damage();
            }
            last = Some(Instant::now());
            pending = false;
        }
    }
    let mut total = 0;
    while !eof && total < FINAL_DRAIN {
        let room = READ_CHUNK.min(FINAL_DRAIN - total);
        match read_fd(fd, &mut buf[..room]) {
            Ok(0) => break,
            Ok(n) => {
                inner.feed(&mut sp, &mut seqs, &mut win, &buf[..n]);
                total += n;
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    win.flush(&*inner.sink);
    if !inner.hidden() {
        inner.damage();
    }
    inner.writer.close();
    let status = lock(&inner.reaped).clone();
    inner.send_exit(status.unwrap_or(ExitStatus::Unknown));
}

fn writer_main(inner: &Inner) {
    let fd = inner.fd.as_raw_fd();
    while let Some(buf) = inner.writer.pop() {
        let mut off = 0;
        while off < buf.len() {
            match write_fd(fd, &buf[off..]) {
                Ok(n) => off += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    // The fd is O_NONBLOCK (shared with the reader's file description), so
                    // wait for room, waking every tick to notice the pane closing.
                    let mut p = [pollfd(fd, libc::POLLOUT)];
                    poll(&mut p, WRITER_TICK_MS);
                    let gone = p[0].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL);
                    if gone != 0 {
                        inner.writer.close();
                        return;
                    }
                    if inner.writer.is_closed() {
                        return;
                    }
                }
                // EIO/EPIPE: the child side is gone.
                Err(_) => {
                    inner.writer.close();
                    return;
                }
            }
        }
    }
}

fn waiter_main(inner: &Inner) {
    // Wait on this pid only, never -1, so other children (erts', std::process) are untouched.
    // WNOWAIT leaves the zombie in place until `reaped` is locked; see `Inner::reaped`.
    let exited = loop {
        // SAFETY: zeroed siginfo_t is a valid out-parameter for waitid.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let flags = libc::WEXITED | libc::WNOWAIT;
        // SAFETY: info is a valid, exclusively borrowed siginfo_t.
        let r = unsafe { libc::waitid(libc::P_PID, inner.pid as libc::id_t, &mut info, flags) };
        if r == 0 {
            break true;
        }
        if last_err().kind() != io::ErrorKind::Interrupted {
            break false;
        }
    };
    let mut reaped = lock(&inner.reaped);
    let mut status = 0;
    let st = loop {
        // waitid failed (not EINTR): do not block in waitpid while holding `reaped`.
        if !exited {
            break ExitStatus::Unknown;
        }
        // SAFETY: status is a valid out-parameter.
        let r = unsafe { libc::waitpid(inner.pid, &mut status, 0) };
        if r == inner.pid {
            break wait_status(status);
        }
        if r < 0 && last_err().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        // ECHILD: someone else reaped our child; the real status is lost.
        break ExitStatus::Unknown;
    };
    *reaped = Some(st);
    drop(reaped);
    inner.wake();
}

fn run(inner: &Arc<Inner>, name: &str, body: fn(&Inner)) -> io::Result<()> {
    let inner = Arc::clone(inner);
    std::thread::Builder::new()
        .name(format!("herdr-pty-{name}-{}", inner.id))
        .spawn(move || {
            if let Err(p) = catch_unwind(AssertUnwindSafe(|| body(&inner))) {
                inner.fail(panic_msg(p));
            }
        })
        .map(drop)
}

pub struct Pty {
    inner: Arc<Inner>,
}

impl Pty {
    pub fn spawn(
        vt: Arc<Vt>,
        opts: SpawnOptions,
        sink: Arc<dyn EventSink>,
    ) -> io::Result<Arc<Pty>> {
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: opts.rows,
                cols: opts.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(io::Error::other)?;
        let master = pair
            .master
            .as_raw_fd()
            .ok_or_else(|| io::Error::other("pty master has no fd"))?;
        // SAFETY: `pair.master` owns this fd and is alive; try_clone_to_owned dups it (CLOEXEC).
        let fd = unsafe { BorrowedFd::borrow_raw(master) }.try_clone_to_owned()?;
        set_flags(
            fd.as_raw_fd(),
            libc::F_GETFL,
            libc::F_SETFL,
            libc::O_NONBLOCK,
        )?;
        let (wake_r, wake_w) = pipe()?;

        let mut cmd = CommandBuilder::new(&opts.cmd);
        cmd.args(&opts.args);
        // CommandBuilder starts from the inherited environment; caller entries override.
        cmd.env("TERM", "xterm-256color");
        for (k, v) in &opts.env {
            cmd.env(k, v);
        }
        if let Some(cwd) = &opts.cwd {
            cmd.cwd(cwd);
        }
        // The vendored portable-pty pre_exec (vendor/portable-pty/src/unix.rs, spawn_command)
        // resets SIGCHLD/SIGHUP/SIGINT/SIGQUIT/SIGTERM/SIGALRM to SIG_DFL, clears the signal
        // mask, calls setsid + TIOCSCTTY, and closes every fd above 2 (close_random_fds).
        // std::process::Command also restores SIGPIPE. Master and slave are CLOEXEC.
        let child = pair.slave.spawn_command(cmd).map_err(io::Error::other)?;
        drop(pair.slave);
        drop(pair.master);
        let pid = child
            .process_id()
            .ok_or_else(|| io::Error::other("child has no pid"))?;
        // Dropping a std Child neither kills nor reaps; the waiter thread reaps.
        drop(child);

        let writer = Arc::new(Writer::default());
        let w = Arc::clone(&writer);
        // ghostty replies (DA, DSR, ...) bypass the cap; the callback runs under the core
        // lock, so it only enqueues.
        // This closure is called from C: no unwind may cross back into it.
        vt.set_write_pty(move |b| {
            let _ = catch_unwind(AssertUnwindSafe(|| w.push(b, None)));
        });
        let inner = Arc::new(Inner {
            id: opts.id,
            pid: pid as libc::pid_t,
            vt,
            sink,
            fd,
            wake_r,
            wake_w,
            writer,
            hidden: AtomicBool::new(false),
            exit_sent: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            exit: Mutex::new(None),
            reaped: Mutex::new(None),
            inject_panic: AtomicBool::new(false),
        });
        let started = run(&inner, "waiter", waiter_main)
            .and_then(|()| run(&inner, "writer", writer_main))
            .and_then(|()| run(&inner, "reader", reader_main));
        if let Err(e) = started {
            inner.writer.close();
            let _ = inner.signal(libc::SIGKILL);
            return Err(e);
        }
        Ok(Arc::new(Pty { inner }))
    }

    pub fn id(&self) -> u64 {
        self.inner.id
    }

    pub fn os_pid(&self) -> u32 {
        self.inner.pid as u32
    }

    pub fn write(&self, bytes: &[u8]) -> Result<(), WriteError> {
        self.inner.writer.push(bytes, Some(WRITE_CAP))
    }

    /// PTY winsize only; `px` is the total pixel size. The `Vt` is resized separately.
    pub fn resize(&self, cols: u16, rows: u16, px: Option<(u16, u16)>) -> io::Result<()> {
        let (x, y) = px.unwrap_or((0, 0));
        let ws = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: x,
            ws_ypixel: y,
        };
        // SAFETY: TIOCSWINSZ reads a winsize from a valid pointer.
        if unsafe { libc::ioctl(self.inner.fd.as_raw_fd(), libc::TIOCSWINSZ, &ws) } != 0 {
            return Err(last_err());
        }
        Ok(())
    }

    pub fn kill(&self, signo: i32) -> io::Result<()> {
        self.inner.signal(signo)
    }

    pub fn set_hidden(&self, hidden: bool) {
        self.inner.hidden.store(hidden, Ordering::Release);
        if !hidden {
            self.inner.vt.mark_all_dirty();
            self.inner.damage();
        }
    }

    pub fn request_full_damage(&self) {
        self.inner.vt.reset_read_cursor();
        let gen = self.inner.vt.snapshot().gen;
        self.inner.sink.send(Event::Damage(gen));
    }

    pub fn exit_status(&self) -> Option<ExitStatus> {
        lock(&self.inner.exit).clone()
    }

    pub fn inject_reader_panic(&self) {
        self.inner.inject_panic.store(true, Ordering::Release);
        self.inner.wake();
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        let _ = self.inner.signal(libc::SIGHUP);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::decode_row;
    use crate::vt::TextRange;
    use std::sync::mpsc::{self, Receiver};

    const T: Duration = Duration::from_secs(5);

    struct ChanSink(Mutex<mpsc::Sender<Event>>);

    impl EventSink for ChanSink {
        fn send(&self, ev: Event) {
            let _ = lock(&self.0).send(ev);
        }
    }

    fn spawn(cmd: &str, args: &[&str]) -> (Arc<Vt>, Arc<Pty>, Receiver<Event>) {
        let vt = Vt::new(80, 24, 1000).expect("vt");
        let (tx, rx) = mpsc::channel();
        let opts = SpawnOptions {
            id: 1,
            cmd: cmd.into(),
            args: args.iter().map(|a| a.to_string()).collect(),
            env: vec![("PS1".into(), "$ ".into())],
            cwd: None,
            cols: 80,
            rows: 24,
        };
        let pty =
            Pty::spawn(Arc::clone(&vt), opts, Arc::new(ChanSink(Mutex::new(tx)))).expect("spawn");
        (vt, pty, rx)
    }

    fn sh(script: &str) -> (Arc<Vt>, Arc<Pty>, Receiver<Event>) {
        spawn("/bin/sh", &["-c", script])
    }

    fn lines(vt: &Vt) -> Vec<String> {
        vt.full_rows()
            .1
            .iter()
            .map(|(_, r)| {
                decode_row(r)
                    .expect("decode")
                    .iter()
                    .map(|c| if c.glyph.is_empty() { " " } else { &c.glyph }.to_string())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    /// Receives until `pred` holds, failing after `timeout`.
    fn until(rx: &Receiver<Event>, timeout: Duration, mut pred: impl FnMut(&Event) -> bool) {
        let end = Instant::now() + timeout;
        loop {
            let left = end.saturating_duration_since(Instant::now());
            match rx.recv_timeout(left) {
                Ok(ev) if pred(&ev) => return,
                Ok(_) => {}
                Err(e) => panic!("timed out waiting: {e:?}"),
            }
        }
    }

    fn exit_of(rx: &Receiver<Event>) -> ExitStatus {
        let mut out = None;
        until(rx, T, |ev| match ev {
            Event::Exit(s) => {
                out = Some(s.clone());
                true
            }
            _ => false,
        });
        out.expect("exit")
    }

    #[test]
    fn echo_hi_damage_and_rows() {
        let (vt, pty, rx) = spawn("/bin/sh", &[]);
        pty.write(b"echo hi\n").expect("write");
        until(&rx, T, |ev| {
            matches!(ev, Event::Damage(_)) && lines(&vt).iter().any(|l| l.starts_with("hi"))
        });
    }

    #[test]
    fn exit_status_code() {
        let (_vt, pty, rx) = sh("exit 7");
        assert_eq!(exit_of(&rx), ExitStatus::Code(7));
        assert_eq!(pty.exit_status(), Some(ExitStatus::Code(7)));
    }

    #[test]
    fn exit_status_signal() {
        let (_vt, _pty, rx) = sh("kill -9 $$");
        assert_eq!(exit_of(&rx), ExitStatus::Signal(9));
    }

    #[test]
    fn exit_on_reap_not_eof() {
        let start = Instant::now();
        let (_vt, _pty, rx) = sh("sleep 30 & exit 3");
        assert_eq!(exit_of(&rx), ExitStatus::Code(3));
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn burst_then_silence_flushes() {
        let start = Instant::now();
        let (vt, _pty, rx) = sh("seq 1 20000; sleep 5");
        until(&rx, T, |ev| {
            matches!(ev, Event::Damage(_)) && lines(&vt).iter().any(|l| l == "20000")
        });
        assert!(start.elapsed() < Duration::from_secs(5));
        let ls = lines(&vt);
        assert_eq!(ls.iter().rposition(|l| !l.is_empty()), Some(22), "{ls:?}");
        assert_eq!(ls[22], "20000");
    }

    #[test]
    fn coalescing_bounds_damage() {
        let start = Instant::now();
        let (_vt, _pty, rx) = sh("seq 1 200000");
        let mut damage = 0u128;
        until(&rx, Duration::from_secs(20), |ev| match ev {
            Event::Damage(_) => {
                damage += 1;
                false
            }
            ev => matches!(ev, Event::Exit(_)),
        });
        let ms = start.elapsed().as_millis();
        assert!(damage <= ms / 4 + 5, "{damage} damages in {ms} ms");
        assert!(damage > 0);
    }

    #[test]
    fn hidden_suppresses_damage() {
        let (vt, pty, rx) = sh("sleep 0.3; printf hidden-output; sleep 30");
        pty.set_hidden(true);
        let end = Instant::now() + T;
        while !vt
            .read_text(TextRange::Viewport)
            .expect("text")
            .contains("hidden-output")
        {
            assert!(Instant::now() < end, "output never parsed");
            std::thread::sleep(Duration::from_millis(10));
        }
        std::thread::sleep(Duration::from_millis(100));
        assert!(rx.try_iter().all(|ev| !matches!(ev, Event::Damage(_))));
        pty.set_hidden(false);
        assert!(matches!(rx.recv_timeout(T), Ok(Event::Damage(_))));
        assert!(lines(&vt)[0].starts_with("hidden-output"));
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(rx.try_iter().count(), 0);
    }

    #[test]
    fn title_pwd_bell_osc_events() {
        let (_vt, _pty, rx) = sh(concat!(
            "printf '\\033]2;tt\\007\\033]1;icon\\007\\033]7;file://h/tmp\\007",
            "\\007\\033]9;note\\007\\033Pxyz\\033\\\\'"
        ));
        let mut evs = Vec::new();
        until(&rx, T, |ev| {
            evs.push(ev.clone());
            matches!(ev, Event::Exit(_))
        });
        let want = [
            Event::Title(b"tt".to_vec()),
            Event::Pwd(b"file://h/tmp".to_vec()),
            Event::Bell,
            Event::Osc {
                code: 9,
                payload: b"note".to_vec(),
                truncated: false,
            },
            Event::Dcs {
                payload: b"xyz".to_vec(),
                truncated: false,
            },
        ];
        for w in &want {
            assert!(evs.contains(w), "missing {w:?} in {evs:?}");
        }
        assert!(!evs.iter().any(|e| matches!(e, Event::Osc { code: 1, .. })));
        assert_eq!(
            evs.iter().filter(|e| matches!(e, Event::Title(_))).count(),
            1
        );
    }

    /// Every event up to and including the exit, and the elapsed time.
    fn all_until_exit(rx: &Receiver<Event>) -> Vec<Event> {
        let mut evs = Vec::new();
        until(rx, Duration::from_secs(20), |ev| {
            evs.push(ev.clone());
            matches!(ev, Event::Exit(_))
        });
        evs
    }

    #[test]
    fn titles_coalesce_to_last_per_window() {
        let (_vt, _pty, rx) =
            sh("awk 'BEGIN { for (i = 0; i < 10000; i++) printf \"\\033]0;t%d\\007\", i }'");
        let titles: Vec<_> = all_until_exit(&rx)
            .into_iter()
            .filter_map(|e| match e {
                Event::Title(t) => Some(t),
                _ => None,
            })
            .collect();
        assert!(
            !titles.is_empty() && titles.len() <= 20,
            "{} titles",
            titles.len()
        );
        assert_eq!(titles.last().map(Vec::as_slice), Some(&b"t9999"[..]));
    }

    #[test]
    fn osc_capped_per_window() {
        let start = Instant::now();
        let (_vt, _pty, rx) =
            sh("awk 'BEGIN { for (i = 0; i < 10000; i++) printf \"\\033]777;x\\007\" }'");
        let evs = all_until_exit(&rx);
        let ms = start.elapsed().as_millis() as usize;
        let osc = evs
            .iter()
            .filter(|e| matches!(e, Event::Osc { code: 777, .. }))
            .count();
        assert!(osc > 0 && osc <= 64 * (ms / 4 + 2), "{osc} osc in {ms} ms");
        assert!(osc < 10000, "nothing dropped");
    }

    #[test]
    fn write_after_exit_is_closed() {
        let (_vt, pty, rx) = sh("exit 0");
        assert_eq!(exit_of(&rx), ExitStatus::Code(0));
        assert_eq!(pty.write(b"x"), Err(WriteError::Closed));
    }

    #[test]
    fn backpressure_when_child_not_reading() {
        let (_vt, pty, _rx) = sh("stty raw -echo; sleep 30");
        let chunk = vec![b'a'; 64 * 1024];
        let mut accepted = 0usize;
        let mut hit = false;
        while accepted < 4 * 1024 * 1024 {
            match pty.write(&chunk) {
                Ok(()) => accepted += chunk.len(),
                Err(WriteError::Backpressure) => {
                    hit = true;
                    break;
                }
                Err(WriteError::Closed) => panic!("closed"),
            }
        }
        assert!(hit, "accepted {accepted} bytes without backpressure");
    }

    #[test]
    fn da_reply_goes_to_child() {
        let (vt, _pty, rx) = sh(
            "stty raw -echo; printf '\\033[c'; dd bs=1 count=3 2>/dev/null | od -An -tx1; sleep 5",
        );
        until(&rx, T, |ev| {
            matches!(ev, Event::Damage(_)) && lines(&vt).iter().any(|l| l.contains("1b 5b 3f"))
        });
    }

    #[test]
    fn panic_in_reader_reports_exit_once() {
        let (vt, pty, rx) = sh("sleep 30");
        pty.inject_reader_panic();
        assert!(matches!(exit_of(&rx), ExitStatus::Panic(m) if m.contains("injected")));
        assert_eq!(pty.write(b"x"), Err(WriteError::Closed));
        std::thread::sleep(Duration::from_millis(500));
        assert!(rx.try_iter().all(|ev| !matches!(ev, Event::Exit(_))));
        assert!(matches!(pty.exit_status(), Some(ExitStatus::Panic(_))));
        vt.write(b"still ok");
        vt.refresh();
        assert_eq!(vt.full_rows().1.len(), 24);
        assert!(lines(&vt)[0].starts_with("still ok"));
    }

    #[test]
    fn reaping_leaves_other_children_alone() {
        let other = std::thread::spawn(|| {
            (0..20).all(|_| {
                std::process::Command::new("true")
                    .status()
                    .is_ok_and(|s| s.success())
            })
        });
        let ptys: Vec<_> = (10..20).map(|n| (n, sh(&format!("exit {n}")))).collect();
        for (n, (_vt, _pty, rx)) in &ptys {
            assert_eq!(exit_of(rx), ExitStatus::Code(*n));
        }
        assert!(other.join().expect("join"));
    }
}
