//! PTY runtime: reader, writer and waiter threads. Raw PTY bytes never leave the kernel;
//! the reader feeds ghostty and emits only damage generations and structured events.

use std::any::Any;
use std::collections::VecDeque;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, CommandBuilder, PtySize};

use crate::bulk::{set_thread_bulk, Pacer};
use crate::exitwatch::{self, Watch};
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

/// A pane handed over by a previous VM: `fd` is its PTY master, `pid` its child (not ours).
#[derive(Debug, Clone)]
pub struct AdoptOptions {
    pub id: u64,
    pub pid: u32,
    /// The child already exited: no watcher, `kill` is a no-op, the exit follows the drain.
    pub exited: bool,
    /// Last title and pwd the previous owner saw, so `info` survives a handoff.
    pub title: Option<Vec<u8>>,
    pub pwd: Option<Vec<u8>>,
    /// The child's start time as the previous owner read it (`exitwatch::start_time`).
    /// A live pid whose start time differs (recycled) or that is gone is treated as
    /// exited: never watched, never signalled. None skips the check.
    pub start_time: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtyInfo {
    pub pid: u32,
    pub adopted: bool,
    pub hidden: bool,
    pub title: Option<Vec<u8>>,
    pub pwd: Option<Vec<u8>>,
    pub exited: Option<ExitStatus>,
    /// The child's start time (spawn, or carried by adopt); None when unreadable.
    pub start_time: Option<u64>,
}

/// `release` needs a frozen pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotFrozen;

#[derive(Debug)]
pub enum ThawError {
    /// Handed off: the pane stays released and frozen.
    Released,
    Io(io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteError {
    Backpressure,
    Closed,
    /// A single BEAM write larger than `WRITE_CAP`.
    TooLarge,
}

#[derive(Default)]
struct Queue {
    bufs: VecDeque<Vec<u8>>,
    bytes: usize,
    closed: bool,
    /// Frozen: `pop` returns None so the writer stops, while `push` still queues.
    paused: bool,
    /// Closed by `take`, so `resume` reopens it.
    taken: bool,
}

/// Writer queue. Shared with ghostty's write-pty callback, so it must not own the `Vt`.
#[derive(Default)]
struct Writer {
    q: Mutex<Queue>,
    cv: Condvar,
}

impl Writer {
    /// The queue holds at most `WRITE_CAP` bytes. A BEAM write (`beam`) of up to
    /// `WRITE_CAP` bytes is accepted whenever the queue is empty; a ghostty reply that
    /// does not fit is refused (the caller drops it).
    fn push(&self, b: &[u8], beam: bool) -> Result<(), WriteError> {
        let mut q = lock(&self.q);
        if q.closed {
            return Err(WriteError::Closed);
        }
        if beam && b.len() > WRITE_CAP {
            return Err(WriteError::TooLarge);
        }
        if q.bytes + b.len() > WRITE_CAP && (q.bytes > 0 || !beam) {
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

    /// For a writer blocked mid-buffer: true when it must stop. Paused, the unwritten
    /// `rest` goes back to the queue front so no byte is lost or reordered.
    fn interrupted(&self, rest: &[u8]) -> bool {
        let mut q = lock(&self.q);
        if q.paused && !q.closed {
            q.bytes += rest.len();
            q.bufs.push_front(rest.to_vec());
        }
        q.closed || q.paused
    }

    fn pause(&self) {
        lock(&self.q).paused = true;
        self.cv.notify_all();
    }

    fn resume(&self) {
        let mut q = lock(&self.q);
        q.paused = false;
        if q.taken {
            q.taken = false;
            q.closed = false;
        }
    }

    fn copy(&self) -> Vec<u8> {
        lock(&self.q).bufs.iter().flatten().copied().collect()
    }

    /// Closes the queue and returns everything still in it.
    fn take(&self) -> Vec<u8> {
        let mut q = lock(&self.q);
        if q.closed {
            return Vec::new();
        }
        q.closed = true;
        q.taken = true;
        q.bytes = 0;
        std::mem::take(&mut q.bufs).into_iter().flatten().collect()
    }

    /// Next buffer in order, or None once closed or paused.
    fn pop(&self) -> Option<Vec<u8>> {
        let mut q = lock(&self.q);
        loop {
            if q.closed || q.paused {
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
/// The waiter (spawned) or exit watcher (adopted) blocks until the child exits, so like the
/// reader it keeps `Inner` alive exactly as long as the child lives.
struct Inner {
    id: u64,
    pid: libc::pid_t,
    /// Handed over by a previous VM; not our child, so never waited on.
    adopted: bool,
    /// Exit watch for an adopted, live child; also how it is signalled.
    watch: Option<Watch>,
    /// `exitwatch::start_time` of the child, carried across handoffs.
    start_time: Option<u64>,
    /// Set by `freeze`: the reader and writer stop without draining or closing.
    frozen: AtomicBool,
    /// Set by `release`: no SIGHUP on drop, no exit event ever.
    released: AtomicBool,
    /// Reader and writer handles, joined by `freeze`. Its lock serializes freeze, thaw,
    /// take_pending and release.
    threads: Mutex<Vec<JoinHandle<()>>>,
    /// Last title and pwd the reader flushed (or the adoption seed).
    title: Mutex<Option<Vec<u8>>>,
    pwd: Mutex<Option<Vec<u8>>>,
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

pub(crate) fn panic_msg(p: Box<dyn Any + Send>) -> String {
    match p.downcast::<&str>() {
        Ok(s) => s.to_string(),
        Err(p) => match p.downcast::<String>() {
            Ok(s) => *s,
            Err(_) => "unknown panic".to_string(),
        },
    }
}

impl Inner {
    /// A fresh `Inner` for a non-adopted pane, and the vt's write-pty hook into its writer.
    fn new(
        vt: Arc<Vt>,
        sink: Arc<dyn EventSink>,
        fd: OwnedFd,
        id: u64,
        pid: libc::pid_t,
    ) -> io::Result<Inner> {
        let (wake_r, wake_w) = pipe()?;
        let writer = Arc::new(Writer::default());
        let w = Arc::clone(&writer);
        // ghostty replies (DA, DSR, ...) are dropped when the queue is full; the callback
        // runs under the core lock, so it only enqueues.
        // This closure is called from C: no unwind may cross back into it.
        vt.set_write_pty(move |b| {
            let _ = catch_unwind(AssertUnwindSafe(|| w.push(b, false)));
        });
        Ok(Inner {
            id,
            pid,
            adopted: false,
            watch: None,
            start_time: None,
            frozen: AtomicBool::new(false),
            released: AtomicBool::new(false),
            threads: Mutex::new(Vec::new()),
            title: Mutex::new(None),
            pwd: Mutex::new(None),
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
        })
    }

    fn wake(&self) {
        // EAGAIN means a wake is already pending; nothing else can fail here.
        let _ = write_fd(self.wake_w.as_raw_fd(), &[1]);
    }

    /// A released pane's child belongs to the next VM: it is never signalled (not by
    /// `kill`, `Drop`'s SIGHUP, or `fail`'s SIGKILL).
    fn signal(&self, signo: i32) -> io::Result<()> {
        let reaped = lock(&self.reaped);
        if reaped.is_some() || self.released.load(Ordering::Acquire) {
            return Ok(());
        }
        let r = match &self.watch {
            Some(w) => w.signal(signo),
            // SAFETY: plain syscall; the pid is our unreaped child (see `reaped`).
            None => match unsafe { libc::kill(self.pid, signo) } {
                0 => Ok(()),
                _ => Err(last_err()),
            },
        };
        match r {
            Err(e) if e.raw_os_error() == Some(libc::ESRCH) => Ok(()),
            r => r,
        }
    }

    fn send_exit(&self, status: ExitStatus) {
        if self.released.load(Ordering::Acquire) {
            return;
        }
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

    fn flush(&mut self, inner: &Inner) {
        if let Some(t) = self.title.take() {
            *lock(&inner.title) = Some(t.clone());
            inner.sink.send(Event::Title(t));
        }
        if let Some(p) = self.pwd.take() {
            *lock(&inner.pwd) = Some(p.clone());
            inner.sink.send(Event::Pwd(p));
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
    let mut pacer = Pacer::new(Instant::now());
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
        // Frozen: unread output stays in the PTY for the next owner; no drain, no close,
        // no exit event.
        // ponytail: the splitter's partial OSC/DCS state is dropped, so an event split
        // across freeze and thaw is lost (the Vt itself keeps its parser state).
        if inner.frozen.load(Ordering::Acquire) {
            win.flush(inner);
            if pending && !inner.hidden() {
                inner.damage();
            }
            return;
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
                    if let Some(bulk) = pacer.observe(n, Instant::now()) {
                        set_thread_bulk(bulk);
                    }
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
        // Adopted: nobody reaps for us, and a child that closed its tty (or a watch that
        // never fires) must still end the pane. The status is unknowable anyway.
        if eof && inner.adopted {
            lock(&inner.reaped).get_or_insert(ExitStatus::Unknown);
            break;
        }
        if inner.hidden() {
            pending = false;
        }
        // Leading edge after idle, then at most one damage per interval; a quiescent tail
        // is flushed when the interval ends (poll timeout above), with no further input.
        let due = pending || win.pending();
        if due && (eof || last.is_none_or(|t| t.elapsed() >= DAMAGE_INTERVAL)) {
            win.flush(inner);
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
    win.flush(inner);
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
                    if inner.writer.interrupted(&buf[off..]) {
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

/// Adopted panes: never waits (the child is not ours); reports `Unknown` on exit.
fn watcher_main(inner: &Inner) {
    if let Some(w) = &inner.watch {
        w.wait();
    }
    lock(&inner.reaped).get_or_insert(ExitStatus::Unknown);
    inner.wake();
}

/// A kernel thread body.
type Body = fn(&Inner);

fn run(inner: &Arc<Inner>, name: &str, body: Body) -> io::Result<JoinHandle<()>> {
    let inner = Arc::clone(inner);
    std::thread::Builder::new()
        .name(format!("herdr-pty-{name}-{}", inner.id))
        .spawn(move || {
            if let Err(p) = catch_unwind(AssertUnwindSafe(|| body(&inner))) {
                inner.fail(panic_msg(p));
            }
        })
}

/// Starts the writer and reader, keeping their handles for `freeze`.
fn start_io(inner: &Arc<Inner>, threads: &mut Vec<JoinHandle<()>>) -> io::Result<()> {
    threads.push(run(inner, "writer", writer_main)?);
    threads.push(run(inner, "reader", reader_main)?);
    // A reap seen while the reader was not running (thaw, or adopt of an exited child)
    // is noticed on this wake.
    inner.wake();
    Ok(())
}

/// Starts `side` (waiter or watcher, detached) and the I/O threads.
fn launch(inner: Inner, side: Option<(&str, Body)>) -> io::Result<Arc<Pty>> {
    let inner = Arc::new(inner);
    let started = side
        .map_or(Ok(()), |(name, body)| run(&inner, name, body).map(drop))
        .and_then(|()| start_io(&inner, &mut lock(&inner.threads)));
    if let Err(e) = started {
        inner.writer.close();
        // An adopted child is not ours to kill on a local failure.
        if !inner.adopted {
            let _ = inner.signal(libc::SIGKILL);
        }
        return Err(e);
    }
    Ok(Arc::new(Pty { inner }))
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
        // Keep the errno when there is one (exec failures); portable-pty's own checks (e.g.
        // a missing executable) are plain messages.
        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| match e.downcast::<io::Error>() {
                Ok(io) => io,
                Err(e) => io::Error::other(format!("{e:#}")),
            })?;
        drop(pair.slave);
        drop(pair.master);
        let pid = child
            .process_id()
            .ok_or_else(|| io::Error::other("child has no pid"))?;
        // Dropping a std Child neither kills nor reaps; the waiter thread reaps.
        drop(child);
        let mut inner = match Inner::new(vt, sink, fd, opts.id, pid as libc::pid_t) {
            Ok(inner) => inner,
            Err(e) => {
                // No waiter runs yet: kill and reap the just-spawned child here.
                let mut status = 0;
                // SAFETY: plain syscalls on our own unreaped child.
                unsafe {
                    libc::kill(pid as libc::pid_t, libc::SIGKILL);
                    libc::waitpid(pid as libc::pid_t, &mut status, 0);
                }
                return Err(e);
            }
        };
        // Our unreaped child: its pid cannot be recycled yet.
        inner.start_time = exitwatch::start_time(pid).ok();
        launch(inner, Some(("waiter", waiter_main)))
    }

    /// Takes over a PTY master `fd` whose child `opts.pid` some earlier process spawned.
    /// The exit is always `Unknown` (the status is not ours to collect).
    pub fn adopt(
        vt: Arc<Vt>,
        fd: OwnedFd,
        opts: AdoptOptions,
        sink: Arc<dyn EventSink>,
    ) -> io::Result<Arc<Pty>> {
        set_flags(
            fd.as_raw_fd(),
            libc::F_GETFL,
            libc::F_SETFL,
            libc::O_NONBLOCK,
        )?;
        let watch = match opts.exited {
            true => None,
            false => match exitwatch::watch(opts.pid) {
                Ok(w) => Some(w),
                Err(e) if e.raw_os_error() == Some(libc::ESRCH) => None,
                Err(e) => return Err(e),
            },
        };
        // Checked after the watch is registered, so a pid recycled before it is caught
        // here and one recycled after it cannot be (the watch pins the old process).
        let watch = match (watch, opts.start_time) {
            (Some(w), Some(want)) => match exitwatch::start_time(opts.pid) {
                Ok(now) if now == want => Some(w),
                // gone, recycled or unreadable: never watch or signal it
                _ => None,
            },
            (w, _) => w,
        };
        let base = Inner::new(vt, sink, fd, opts.id, opts.pid as libc::pid_t)?;
        let side = watch.is_some().then_some(("watch", watcher_main as Body));
        let inner = Inner {
            adopted: true,
            reaped: Mutex::new(watch.is_none().then_some(ExitStatus::Unknown)),
            watch,
            start_time: opts.start_time,
            title: Mutex::new(opts.title),
            pwd: Mutex::new(opts.pwd),
            ..base
        };
        launch(inner, side)
    }

    /// A CLOEXEC dup of the PTY master (it shares the file description, so O_NONBLOCK).
    pub fn dup_fd(&self) -> io::Result<OwnedFd> {
        self.inner.fd.try_clone()
    }

    /// Stops the writer at a buffer boundary and the reader after its current chunk, joins
    /// both, and returns a copy of the queued input. Writes keep queueing. Idempotent.
    pub fn freeze(&self) -> Vec<u8> {
        let mut threads = lock(&self.inner.threads);
        self.inner.frozen.store(true, Ordering::Release);
        self.inner.writer.pause();
        self.inner.wake();
        for h in threads.drain(..) {
            // Thread bodies run under catch_unwind, so join never sees a panic.
            let _ = h.join();
        }
        self.inner.writer.copy()
    }

    /// After `freeze`: closes the queue (later writes are `Closed`) and returns its bytes.
    /// Not frozen: returns nothing and leaves the queue alone.
    pub fn take_pending(&self) -> Vec<u8> {
        let _threads = lock(&self.inner.threads);
        match self.inner.frozen.load(Ordering::Acquire) {
            true => self.inner.writer.take(),
            false => Vec::new(),
        }
    }

    /// Restarts the reader and writer on the same pane, reopening a taken queue. No-op
    /// when not frozen; refused once released.
    pub fn thaw(&self) -> Result<(), ThawError> {
        let mut threads = lock(&self.inner.threads);
        if self.inner.released.load(Ordering::Acquire) {
            return Err(ThawError::Released);
        }
        if !self.inner.frozen.swap(false, Ordering::AcqRel) {
            return Ok(());
        }
        self.inner.writer.resume();
        // The reader already ended with the exit event; nothing to restart.
        if self.inner.exit_sent.load(Ordering::Acquire) {
            return Ok(());
        }
        start_io(&self.inner, &mut threads).map_err(ThawError::Io)
    }

    /// Hands the pane off for good: no SIGHUP on drop and no exit event, ever.
    pub fn release(&self) -> Result<(), NotFrozen> {
        let _threads = lock(&self.inner.threads);
        if !self.inner.frozen.load(Ordering::Acquire) {
            return Err(NotFrozen);
        }
        self.inner.released.store(true, Ordering::Release);
        Ok(())
    }

    pub fn info(&self) -> PtyInfo {
        PtyInfo {
            pid: self.inner.pid as u32,
            adopted: self.inner.adopted,
            hidden: self.inner.hidden(),
            title: lock(&self.inner.title).clone(),
            pwd: lock(&self.inner.pwd).clone(),
            exited: self.exit_status(),
            start_time: self.inner.start_time,
        }
    }

    /// The child's working directory from the OS, else the last OSC 7 pwd as a path.
    /// Only absolute paths. One syscall, so fine on a normal scheduler. Once the child
    /// exited its pid may be recycled, so only the OSC 7 pwd is used then.
    pub fn cwd(&self) -> Option<String> {
        let os = match self.exit_status() {
            Some(_) => None,
            None => os_cwd(self.inner.pid as u32).filter(|p| p.starts_with('/')),
        };
        os.or_else(|| lock(&self.inner.pwd).as_deref().and_then(osc7_path))
    }

    pub fn id(&self) -> u64 {
        self.inner.id
    }

    pub fn os_pid(&self) -> u32 {
        self.inner.pid as u32
    }

    pub fn write(&self, bytes: &[u8]) -> Result<(), WriteError> {
        self.inner.writer.push(bytes, true)
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

/// `proc_pidinfo(PROC_PIDVNODEPATHINFO)`: the process's current directory.
#[cfg(target_os = "macos")]
fn os_cwd(pid: u32) -> Option<String> {
    // SAFETY: zeroed proc_vnodepathinfo is a valid out-buffer for proc_pidinfo.
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    // SAFETY: the buffer is valid and exactly `size` bytes.
    let r = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDVNODEPATHINFO,
            0,
            (&mut info as *mut libc::proc_vnodepathinfo).cast(),
            size,
        )
    };
    if r != size {
        return None;
    }
    // SAFETY: `vip_path` is MAXPATHLEN contiguous c_chars (declared as [[c_char; 32]; 32]).
    let raw: &[u8] = unsafe {
        std::slice::from_raw_parts(
            info.pvi_cdir.vip_path.as_ptr().cast::<u8>(),
            std::mem::size_of_val(&info.pvi_cdir.vip_path),
        )
    };
    let len = raw.iter().position(|&b| b == 0)?;
    String::from_utf8(raw[..len].to_vec()).ok()
}

#[cfg(target_os = "linux")]
fn os_cwd(pid: u32) -> Option<String> {
    std::fs::read_link(format!("/proc/{pid}/cwd"))
        .ok()?
        .into_os_string()
        .into_string()
        .ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn os_cwd(_pid: u32) -> Option<String> {
    None
}

/// An OSC 7 payload as an absolute path: `file://host/p` percent-decoded to `/p`, a bare
/// absolute path as is, anything else None.
fn osc7_path(pwd: &[u8]) -> Option<String> {
    let path = match pwd.strip_prefix(b"file://") {
        Some(rest) => &rest[rest.iter().position(|&b| b == b'/')?..],
        None => pwd,
    };
    if path.first() != Some(&b'/') {
        return None;
    }
    let hex = |b: u8| (b as char).to_digit(16).map(|d| d as u8);
    let mut out = Vec::with_capacity(path.len());
    let mut i = 0;
    while i < path.len() {
        let pair = path
            .get(i + 1)
            .copied()
            .and_then(hex)
            .zip(path.get(i + 2).copied().and_then(hex));
        match (path[i], pair) {
            (b'%', Some((h, l))) => {
                out.push(h << 4 | l);
                i += 3;
            }
            (b, _) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
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
        // `h''i` keeps the echoed command line from matching. Typeahead can put the output
        // after the prompt (dash on Linux, when the write beats the first prompt).
        pty.write(b"echo h''i\n").expect("write");
        until(&rx, T, |ev| {
            matches!(ev, Event::Damage(_))
                && lines(&vt).iter().any(|l| l == "hi" || l.ends_with("$ hi"))
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
    fn write_caps() {
        let w = Writer::default();
        assert_eq!(
            w.push(&vec![0; WRITE_CAP + 1], true),
            Err(WriteError::TooLarge)
        );
        assert_eq!(w.push(&vec![0; WRITE_CAP], true), Ok(()));
        assert_eq!(w.push(b"x", true), Err(WriteError::Backpressure));
        // Replies beyond the cap are refused, so the queue never exceeds it.
        assert_eq!(w.push(b"x", false), Err(WriteError::Backpressure));
        assert_eq!(lock(&w.q).bytes, WRITE_CAP);
        let w = Writer::default();
        assert_eq!(w.push(&vec![0; WRITE_CAP], false), Ok(()));
        assert_eq!(w.push(b"x", false), Err(WriteError::Backpressure));
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
                Err(e) => panic!("{e:?}"),
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

    fn alive(pid: u32) -> bool {
        // SAFETY: signal 0 only checks existence.
        unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
    }

    fn sigkill(pid: u32) {
        // SAFETY: plain syscall on a test child.
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    }

    /// Spawns `cmd`, hands its master over (dup, freeze, release, drop) and adopts it into
    /// a fresh Vt, as a restarted VM would.
    fn handed_over(
        cmd: &str,
        args: &[&str],
        exited: bool,
    ) -> (Arc<Vt>, Arc<Pty>, Receiver<Event>, u32) {
        handed_over_as(cmd, args, exited, |t| t)
    }

    /// `handed_over` with the carried start time mapped by `start`.
    fn handed_over_as(
        cmd: &str,
        args: &[&str],
        exited: bool,
        start: impl Fn(Option<u64>) -> Option<u64>,
    ) -> (Arc<Vt>, Arc<Pty>, Receiver<Event>, u32) {
        let (_vt, pty, _rx) = spawn(cmd, args);
        let pid = pty.os_pid();
        let start_time = start(pty.info().start_time);
        let fd = pty.dup_fd().expect("dup");
        assert!(pty.freeze().is_empty());
        pty.release().expect("release");
        drop(pty);
        adopt_fd(fd, pid, exited, start_time)
    }

    fn adopt_fd(
        fd: OwnedFd,
        pid: u32,
        exited: bool,
        start_time: Option<u64>,
    ) -> (Arc<Vt>, Arc<Pty>, Receiver<Event>, u32) {
        let vt = Vt::new(80, 24, 1000).expect("vt");
        let (tx, rx) = mpsc::channel();
        let opts = AdoptOptions {
            id: 2,
            pid,
            exited,
            title: None,
            pwd: None,
            start_time,
        };
        let pty = Pty::adopt(
            Arc::clone(&vt),
            fd,
            opts,
            Arc::new(ChanSink(Mutex::new(tx))),
        )
        .expect("adopt");
        (vt, pty, rx, pid)
    }

    #[test]
    fn adopt_dup_keeps_child_and_io() {
        let (vt, pty, rx, pid) = handed_over("/bin/sh", &[], false);
        assert!(pty.info().adopted);
        pty.write(b"echo adopted-ok\n").expect("write");
        // The output line, not the echoed command line.
        until(&rx, T, |ev| {
            matches!(ev, Event::Damage(_))
                && lines(&vt)
                    .iter()
                    .any(|l| l.ends_with("adopted-ok") && !l.contains("echo"))
        });
        assert!(alive(pid));
        sigkill(pid);
    }

    #[test]
    fn adopted_exit_is_unknown() {
        let (_vt, pty, rx, _pid) = handed_over("/bin/sh", &[], false);
        pty.write(b"exit 7\n").expect("write");
        assert_eq!(exit_of(&rx), ExitStatus::Unknown);
        std::thread::sleep(Duration::from_millis(300));
        assert!(rx.try_iter().all(|ev| !matches!(ev, Event::Exit(_))));
        assert_eq!(pty.info().exited, Some(ExitStatus::Unknown));
    }

    #[test]
    fn spawn_records_start_time() {
        let (_vt, pty, _rx) = spawn("/bin/sleep", &["30"]);
        let t = pty.info().start_time.expect("start time");
        assert_eq!(exitwatch::start_time(pty.os_pid()).expect("read"), t);
        assert_eq!(
            exitwatch::start_time(u32::MAX >> 1).map_err(|e| e.raw_os_error()),
            Err(Some(libc::ESRCH))
        );
        sigkill(pty.os_pid());
    }

    #[test]
    fn adopt_recycled_pid_is_exited() {
        // a live pid whose start time differs is someone else's process now
        let (_vt, pty, rx, pid) =
            handed_over_as("/bin/sleep", &["30"], false, |t| t.map(|t| t + 1));
        assert_eq!(exit_of(&rx), ExitStatus::Unknown);
        assert!(pty.kill(libc::SIGKILL).is_ok());
        std::thread::sleep(Duration::from_millis(100));
        assert!(alive(pid));
        sigkill(pid);
    }

    #[test]
    fn adopt_matching_start_time_is_watched() {
        let (_vt, pty, rx, pid) = handed_over("/bin/sleep", &["30"], false);
        assert!(pty.info().start_time.is_some());
        pty.kill(libc::SIGKILL).expect("kill");
        assert_eq!(exit_of(&rx), ExitStatus::Unknown);
        // The exit is reported at zombie time (pidfd/kqueue); the handed-over Pty's waiter
        // in this process reaps it a moment later, and kill(pid, 0) sees a zombie as alive.
        let end = Instant::now() + T;
        while alive(pid) && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(!alive(pid));
    }

    #[test]
    fn adopted_eof_reports_exit() {
        // the watch is on a process that outlives the pane's tty: EOF must end the pane
        let (_vt, sh, _rx) = spawn("/bin/sh", &[]);
        let fd = sh.dup_fd().expect("dup");
        assert!(sh.freeze().is_empty());
        sh.release().expect("release");
        drop(sh);
        let mut other = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .expect("sleep");
        let (_vt, pty, rx, _) = adopt_fd(fd, other.id(), false, None);
        pty.write(b"exit\n").expect("write");
        assert_eq!(exit_of(&rx), ExitStatus::Unknown);
        let _ = other.kill();
        let _ = other.wait();
    }

    #[test]
    fn adopt_exited_reports_at_once() {
        let (_vt, pty, rx, pid) = handed_over("/bin/sleep", &["30"], true);
        assert_eq!(exit_of(&rx), ExitStatus::Unknown);
        assert!(pty.kill(libc::SIGKILL).is_ok());
        std::thread::sleep(Duration::from_millis(100));
        assert!(alive(pid));
        sigkill(pid);
    }

    #[test]
    fn freeze_then_thaw_resumes() {
        let (vt, pty, rx) = spawn("/bin/cat", &[]);
        assert!(pty.freeze().is_empty());
        pty.write(b"abc\n").expect("write");
        // Idempotent: still frozen, the queued input is reported again.
        assert_eq!(pty.freeze(), b"abc\n");
        std::thread::sleep(Duration::from_millis(100));
        assert!(!lines(&vt).iter().any(|l| l.contains("abc")));
        pty.thaw().expect("thaw");
        until(&rx, T, |ev| {
            matches!(ev, Event::Damage(_)) && lines(&vt).iter().any(|l| l == "abc")
        });
    }

    #[test]
    fn freeze_carries_unwritten_input() {
        const TOTAL: usize = 512 * 1024;
        let out = std::env::temp_dir().join(format!("herdr-freeze-{}", std::process::id()));
        let script = format!(
            "stty raw -echo; printf ready; sleep 2; head -c {TOTAL} > '{}'; printf done; sleep 30",
            out.display()
        );
        let (vt, pty, rx) = sh(&script);
        until(&rx, T, |ev| {
            matches!(ev, Event::Damage(_)) && lines(&vt)[0].starts_with("ready")
        });
        // Printable bytes only (raw mode passes them verbatim) in a period that does not
        // divide the chunk size, so a reordered chunk changes the stream.
        let written: Vec<u8> = (0..TOTAL).map(|i| b'!' + (i % 89) as u8).collect();
        let mut off = 0;
        while off < TOTAL {
            match pty.write(&written[off..(off + 64 * 1024).min(TOTAL)]) {
                Ok(()) => off += 64 * 1024,
                Err(WriteError::Backpressure) => break,
                Err(e) => panic!("{e:?}"),
            }
        }
        let written = &written[..off.min(TOTAL)];
        std::thread::sleep(Duration::from_millis(100));
        let start = Instant::now();
        let copy = pty.freeze();
        assert!(
            start.elapsed() < Duration::from_millis(500),
            "{:?}",
            start.elapsed()
        );
        let pending = pty.take_pending();
        assert_eq!(copy, pending);
        assert!(!pending.is_empty() && pending.len() < written.len());
        assert_eq!(&written[written.len() - pending.len()..], &pending[..]);
        // What the PTY accepted plus the pending bytes, replayed after a thaw, is exactly
        // the written stream: the child copies all of it to `out`.
        pty.thaw().expect("thaw");
        pty.write(&pending).expect("write pending");
        until(&rx, Duration::from_secs(10), |ev| {
            matches!(ev, Event::Damage(_)) && lines(&vt)[0].starts_with("readydone")
        });
        let got = std::fs::read(&out).expect("read out");
        let _ = std::fs::remove_file(&out);
        assert_eq!(got.len(), written.len());
        assert!(got == written, "stream differs");
    }

    #[test]
    fn release_does_not_hup() {
        let (vt, pty, rx) = spawn("/bin/sleep", &["30"]);
        let pid = pty.os_pid();
        let fd = pty.dup_fd().expect("dup");
        assert!(pty.release().is_err(), "release requires freeze");
        pty.freeze();
        pty.release().expect("release");
        drop((vt, pty, rx));
        std::thread::sleep(Duration::from_millis(200));
        assert!(alive(pid));
        sigkill(pid);
        drop(fd);
    }

    #[test]
    fn released_is_never_signalled() {
        let (_vt, pty, _rx) = spawn("/bin/sleep", &["30"]);
        let pid = pty.os_pid();
        pty.freeze();
        pty.release().expect("release");
        assert!(matches!(pty.thaw(), Err(ThawError::Released)));
        // A late panic (e.g. in the waiter) must not kill the handed-off child.
        pty.inner.fail("late".into());
        pty.kill(libc::SIGKILL).expect("kill is a no-op");
        std::thread::sleep(Duration::from_millis(200));
        assert!(alive(pid));
        assert!(matches!(pty.thaw(), Err(ThawError::Released)));
        sigkill(pid);
    }

    #[test]
    fn write_after_take_pending_is_closed() {
        let (_vt, pty, _rx) = spawn("/bin/cat", &[]);
        pty.freeze();
        pty.write(b"x").expect("write");
        assert_eq!(pty.take_pending(), b"x");
        assert_eq!(pty.write(b"y"), Err(WriteError::Closed));
        pty.thaw().expect("thaw");
        assert_eq!(pty.write(b"z"), Ok(()));
    }

    #[test]
    fn info_records_title_and_pwd() {
        let (_vt, pty, rx) = sh("printf '\\033]2;tt\\007\\033]7;file://h/tmp\\007'; sleep 30");
        until(&rx, T, |ev| matches!(ev, Event::Pwd(_)));
        let info = pty.info();
        assert_eq!(info.title.as_deref(), Some(&b"tt"[..]));
        assert_eq!(info.pwd.as_deref(), Some(&b"file://h/tmp"[..]));
        assert!(!info.adopted && info.exited.is_none() && info.pid == pty.os_pid());
    }

    fn wait_cwd(pty: &Pty, want: &str) -> Option<String> {
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            let got = pty.cwd();
            if got.as_deref() == Some(want) || Instant::now() > end {
                return got;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn cwd_reports_spawn_dir() {
        let dir = std::env::temp_dir().join(format!("herdr-cwd-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let canon = std::fs::canonicalize(&dir).expect("canon");
        let canon = canon.to_str().expect("utf8").to_string();
        let vt = Vt::new(80, 24, 1000).expect("vt");
        let (tx, _rx) = mpsc::channel();
        let opts = SpawnOptions {
            id: 1,
            cmd: "/bin/sh".into(),
            args: vec!["-c".into(), "sleep 5".into()],
            env: vec![],
            cwd: Some(dir.to_str().expect("utf8").into()),
            cols: 80,
            rows: 24,
        };
        let pty = Pty::spawn(vt, opts, Arc::new(ChanSink(Mutex::new(tx)))).expect("spawn");
        assert_eq!(wait_cwd(&pty, &canon).as_deref(), Some(canon.as_str()));
        let _ = pty.kill(libc::SIGKILL);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn cwd_follows_cd() {
        let (_vt, pty, _rx) = spawn("/bin/sh", &[]);
        pty.write(b"cd /\n").expect("write");
        assert_eq!(wait_cwd(&pty, "/").as_deref(), Some("/"));
        let _ = pty.kill(libc::SIGKILL);
    }

    #[test]
    fn cwd_after_exit_skips_the_os() {
        // the pid may be recycled once the child is gone: only OSC 7 is trusted then
        let (_vt, pty, rx) = sh("exit 0");
        exit_of(&rx);
        assert_eq!(pty.cwd(), None);
    }

    #[test]
    fn cwd_falls_back_to_osc7() {
        assert_eq!(
            osc7_path(b"file://h/tmp/a%20b").as_deref(),
            Some("/tmp/a b")
        );
        assert_eq!(osc7_path(b"file:///tmp").as_deref(), Some("/tmp"));
        assert_eq!(osc7_path(b"/var/x").as_deref(), Some("/var/x"));
        assert_eq!(osc7_path(b"relative"), None);
        assert_eq!(osc7_path(b"file://h"), None);
        assert_eq!(osc7_path(b"file://h/bad%zz").as_deref(), Some("/bad%zz"));
    }
}
