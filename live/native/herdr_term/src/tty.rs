//! Host tty ownership: raw mode, startup probe, input reader, restore.
//!
//! `Inner` is shared by the NIF resource and the kernel threads it owns. The
//! threads hold an `Arc<Inner>`, so teardown is explicit: `TtyResource`'s
//! `Drop` restores the terminal without waiting and raises `shutdown`; each
//! detached thread re-checks it at least every `POLL_MS` and drops its `Arc`.

use crate::blit::BlitEncoder;
use crate::output::{Flushed, Output};
use crate::probe::{self, ProbeState};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// Every blocking wait on the fd is bounded by this, so threads notice `shutdown`.
const POLL_MS: i32 = 100;
/// Total time budget for writing the open or restore sequence.
const WRITE_BUDGET: Duration = Duration::from_millis(100);
const PROBE_TIMEOUT: Duration = Duration::from_millis(250);
/// Input kept while nobody is subscribed (and probe leftovers).
const MAX_PENDING_INPUT: usize = 64 * 1024;
const READ_CHUNK: usize = 4096;

const ENTER: &[u8] = b"\x1b[?1049h\x1b[?7l\x1b[?25l";
const PROBE_QUERY: &[u8] = b"\x1b[?u\x1b[c";
const KITTY_POP: &[u8] = b"\x1b[<u";
const RESTORE: &[u8] = b"\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1016l\x1b[?2004l\x1b[?1004l\x1b]8;;\x1b\\\x1b[0m\x1b[0 q\x1b[?25h\x1b[?7h\x1b[?1049l";

/// Events delivered to the subscriber.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// `{:tty_input, binary}`
    Input(Vec<u8>),
    /// `{:exit, :tty, :hangup}`: EOF or EIO on the tty.
    Hangup,
    /// `{:exit, :tty, {:panic, binary}}`: a kernel thread panicked.
    Panic(String),
    /// `{:tty_resumed}`: back from `suspend`; the next frame repaints.
    Resumed,
}

/// Where events go: an Erlang pid in production, a channel in tests.
pub trait Sink: Send {
    fn send(&mut self, event: Event);
}

impl Sink for mpsc::Sender<Event> {
    fn send(&mut self, event: Event) {
        // A dropped receiver just means nobody listens any more.
        let _ = mpsc::Sender::send(self, event);
    }
}

pub type Subscriber = Option<Box<dyn Sink>>;

#[derive(Default)]
struct Subscription {
    sink: Subscriber,
    pending: Vec<u8>,
    exit: Option<Event>,
}

impl Subscription {
    fn deliver(&mut self, event: Event) {
        if let Some(sink) = self.sink.as_mut() {
            sink.send(event);
            return;
        }
        match event {
            Event::Input(bytes) => {
                // ponytail: input beyond 64 KiB before subscribe is dropped; a
                // client subscribes right after open, so this cap is never hit live.
                let room = MAX_PENDING_INPUT.saturating_sub(self.pending.len());
                self.pending
                    .extend_from_slice(&bytes[..bytes.len().min(room)]);
            }
            // Nobody to tell; the next subscriber sends a fresh frame anyway.
            Event::Resumed => {}
            exit => self.exit = Some(exit),
        }
    }
}

pub struct Inner {
    file: File,
    saved: libc::termios,
    kitty: Option<u16>,
    /// The `ESC[>{flags}u` push written at open, re-sent on resume.
    kitty_push: Option<Vec<u8>>,
    restored: AtomicBool,
    shutdown: AtomicBool,
    sub: Mutex<Subscription>,
    pub output: Output,
    /// Held for each write syscall on `file` (never across a wait), so a
    /// restore never interleaves with a half-written output item.
    write_lock: Mutex<()>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panicking thread already reported itself; keep using the data.
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn cvt(rc: libc::c_int) -> io::Result<()> {
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// Polls `fd` for `events`; `Ok(false)` on timeout. EINTR counts as a timeout.
#[cfg(not(target_os = "macos"))]
pub(crate) fn poll_fd(fd: RawFd, events: libc::c_short, timeout_ms: i32) -> io::Result<bool> {
    let mut pfd = libc::pollfd {
        fd,
        events,
        revents: 0,
    };
    // SAFETY: one valid pollfd.
    let rc = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
    if rc < 0 {
        return interrupted_is_timeout(io::Error::last_os_error());
    }
    if rc > 0 && pfd.revents & libc::POLLNVAL != 0 {
        return Err(io::Error::from_raw_os_error(libc::EBADF));
    }
    Ok(rc > 0)
}

/// Polls `fd` for `events`; `Ok(false)` on timeout. EINTR counts as a timeout.
///
/// macOS poll(2) reports POLLNVAL for `/dev/tty`, so this uses select(2). The
/// `$DARWIN_EXTSN` variant accepts fds at or above FD_SETSIZE when the set is
/// sized for them, which matters inside the BEAM's large fd table.
#[cfg(target_os = "macos")]
pub(crate) fn poll_fd(fd: RawFd, events: libc::c_short, timeout_ms: i32) -> io::Result<bool> {
    extern "C" {
        #[link_name = "select$DARWIN_EXTSN"]
        fn select_extsn(
            nfds: libc::c_int,
            readfds: *mut u32,
            writefds: *mut u32,
            errorfds: *mut u32,
            timeout: *mut libc::timeval,
        ) -> libc::c_int;
    }
    let index = usize::try_from(fd).map_err(|_| io::Error::from_raw_os_error(libc::EBADF))?;
    // Darwin fd_set: 32-bit words, bit `fd % 32` of word `fd / 32`.
    let mut set = vec![0u32; index / 32 + 1];
    set[index / 32] |= 1 << (index % 32);
    let mut timeout = libc::timeval {
        tv_sec: libc::time_t::from(timeout_ms / 1000),
        tv_usec: (timeout_ms % 1000) * 1000,
    };
    let none = std::ptr::null_mut();
    let (read, write) = if events & libc::POLLOUT != 0 {
        (none, set.as_mut_ptr())
    } else {
        (set.as_mut_ptr(), none)
    };
    // SAFETY: `set` covers `fd + 1` bits and outlives the call.
    let rc = unsafe { select_extsn(fd + 1, read, write, none, &mut timeout) };
    if rc < 0 {
        return interrupted_is_timeout(io::Error::last_os_error());
    }
    Ok(rc > 0)
}

fn interrupted_is_timeout(err: io::Error) -> io::Result<bool> {
    if err.kind() == io::ErrorKind::Interrupted {
        Ok(false)
    } else {
        Err(err)
    }
}

fn ms_until(deadline: Instant) -> Option<i32> {
    let left = deadline.checked_duration_since(Instant::now())?;
    Some(left.as_millis().clamp(1, POLL_MS as u128) as i32)
}

/// Writes all of `bytes` to the non-blocking `file` before `deadline`.
fn write_by(file: &File, mut bytes: &[u8], deadline: Instant) -> io::Result<()> {
    while !bytes.is_empty() {
        match (&*file).write(bytes) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => bytes = &bytes[n..],
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                let ms = ms_until(deadline).ok_or(io::ErrorKind::TimedOut)?;
                poll_fd(file.as_raw_fd(), libc::POLLOUT, ms)?;
            }
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

impl Inner {
    /// Opens `path`, enters raw mode and the alternate screen, probes kitty
    /// keyboard support (pushing `kitty_flags` when confirmed and non-zero),
    /// and starts the reader thread. Blocks for up to the probe timeout.
    pub fn open_path(path: &str, kitty_flags: u16, sub: Subscriber) -> io::Result<Arc<Inner>> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOCTTY | libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)?;
        let fd = file.as_raw_fd();
        // SAFETY: zeroed termios is a valid out-parameter for tcgetattr.
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out-pointer.
        cvt(unsafe { libc::tcgetattr(fd, &mut saved) })?;
        set_raw(fd, &saved)?;

        let (probe, leftover) = match Self::probe(&file) {
            Ok(found) => found,
            Err(err) => {
                // Leaves the alternate screen too; nothing was pushed yet.
                let _ = reset(&file, &saved, false, true);
                return Err(err);
            }
        };
        let kitty = probe.flags;
        let kitty_push = (kitty.is_some() && kitty_flags != 0)
            .then(|| format!("\x1b[>{kitty_flags}u").into_bytes());
        if let Some(push) = &kitty_push {
            // Best effort: a host that just answered the probe is reading.
            let _ = write_by(&file, push, Instant::now() + WRITE_BUDGET);
        }

        let mut subscription = Subscription {
            sink: sub,
            ..Subscription::default()
        };
        if !leftover.is_empty() {
            subscription.deliver(Event::Input(leftover));
        }
        let inner = Arc::new(Inner {
            file,
            saved,
            kitty,
            kitty_push,
            restored: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
            sub: Mutex::new(subscription),
            output: Output::new(),
            write_lock: Mutex::new(()),
        });
        // Detached: each thread holds its own Arc and exits within POLL_MS of shutdown.
        for (name, body) in [
            ("herdr-tty-reader", Inner::read_loop as fn(&Inner)),
            ("herdr-tty-output", Inner::output_loop),
        ] {
            let thread = Arc::clone(&inner);
            let spawned = std::thread::Builder::new()
                .name(name.into())
                .spawn(move || thread.run_guarded(body));
            if let Err(err) = spawned {
                let _ = inner.restore();
                return Err(err);
            }
        }
        Ok(inner)
    }

    /// Writes the enter sequence and probe, then collects replies until DA1
    /// or the timeout. Returns the probe result and the non-reply bytes.
    fn probe(file: &File) -> io::Result<(ProbeState, Vec<u8>)> {
        let mut out = ENTER.to_vec();
        out.extend_from_slice(PROBE_QUERY);
        write_by(file, &out, Instant::now() + WRITE_BUDGET)?;

        let deadline = Instant::now() + PROBE_TIMEOUT;
        let mut state = ProbeState::default();
        let mut buf = Vec::new();
        let mut chunk = [0u8; READ_CHUNK];
        while !state.da1_seen && buf.len() < MAX_PENDING_INPUT {
            let Some(ms) = ms_until(deadline) else { break };
            if !poll_fd(file.as_raw_fd(), libc::POLLIN, ms)? {
                continue;
            }
            match (&*file).read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    probe::parse(&mut buf, &mut state);
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) => {}
                // EIO and friends: let the reader thread report the hangup.
                Err(_) => break,
            }
        }
        Ok((state, buf))
    }

    /// Runs a thread body; a panic is reported to the subscriber.
    fn run_guarded(&self, body: fn(&Inner)) {
        if let Err(payload) = catch_unwind(AssertUnwindSafe(|| body(self))) {
            let reason = payload
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".to_owned());
            lock(&self.sub).deliver(Event::Panic(reason));
        }
    }

    fn read_loop(&self) {
        let fd = self.file.as_raw_fd();
        let mut chunk = [0u8; READ_CHUNK];
        while !self.shutdown.load(Ordering::Acquire) {
            match poll_fd(fd, libc::POLLIN, POLL_MS) {
                // Input that arrives after restore belongs to whoever opens the tty next.
                Ok(true) if self.shutdown.load(Ordering::Acquire) => break,
                Ok(true) => {}
                Ok(false) => continue,
                Err(_) => {
                    self.hangup();
                    break;
                }
            }
            match (&self.file).read(&mut chunk) {
                Ok(0) => {
                    self.hangup();
                    break;
                }
                Ok(n) => lock(&self.sub).deliver(Event::Input(chunk[..n].to_vec())),
                Err(e)
                    if matches!(
                        e.kind(),
                        io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                    ) => {}
                Err(_) => {
                    self.hangup();
                    break;
                }
            }
        }
    }

    fn output_loop(&self) {
        let mut encoder = BlitEncoder::default();
        let poll = Duration::from_millis(POLL_MS as u64);
        self.output
            .run(&mut encoder, poll, |bytes| self.write_output(bytes));
    }

    /// Writes all of `bytes`, waiting `POLL_MS` at a time for the host and
    /// rechecking `shutdown` before every write syscall.
    fn write_output(&self, mut bytes: &[u8]) -> Flushed {
        let fd = self.file.as_raw_fd();
        while !bytes.is_empty() {
            let result = {
                let _guard = lock(&self.write_lock);
                if self.shutdown.load(Ordering::Acquire) {
                    return Flushed::Failed;
                }
                (&self.file).write(bytes)
            };
            match result {
                Ok(0) => return Flushed::Failed,
                Ok(n) => bytes = &bytes[n..],
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    if poll_fd(fd, libc::POLLOUT, POLL_MS).is_err() {
                        return Flushed::Failed;
                    }
                }
                Err(_) => return Flushed::Failed,
            }
        }
        Flushed::Done
    }

    /// Stops both threads and discards queued output.
    fn stop(&self) {
        self.shutdown.store(true, Ordering::Release);
        self.output.close();
    }

    fn hangup(&self) {
        if !self.shutdown.load(Ordering::Acquire) {
            lock(&self.sub).deliver(Event::Hangup);
        }
    }

    /// Replaces the subscriber. Input (and an exit) that arrived while
    /// nobody was subscribed is handed to `early` first, under the same lock,
    /// so it stays ahead of anything the reader delivers to `sink`. `early`
    /// exists because the NIF must send from the calling scheduler thread.
    pub fn subscribe(&self, sink: Box<dyn Sink>, mut early: impl FnMut(Event)) {
        let mut sub = lock(&self.sub);
        if !sub.pending.is_empty() {
            early(Event::Input(std::mem::take(&mut sub.pending)));
        }
        if let Some(exit) = sub.exit.take() {
            early(exit);
        }
        sub.sink = Some(sink);
    }

    pub fn kitty(&self) -> Option<u16> {
        self.kitty
    }

    /// `(cols, rows, xpixel, ypixel)` from TIOCGWINSZ.
    pub fn size(&self) -> io::Result<(u16, u16, u16, u16)> {
        // SAFETY: zeroed winsize is a valid out-parameter.
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out-pointer.
        cvt(unsafe { libc::ioctl(self.file.as_raw_fd(), libc::TIOCGWINSZ, &mut ws) })?;
        Ok((ws.ws_col, ws.ws_row, ws.ws_xpixel, ws.ws_ypixel))
    }

    /// Restores the host terminal once; later calls do nothing. Stops the
    /// reader and output threads first; later writes and frames are
    /// discarded. Waits up to `WRITE_BUDGET` for the host to take the
    /// sequence, which is written directly, not through the output queue.
    pub fn restore(&self) -> io::Result<()> {
        if self.restored.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.stop();
        let _guard = lock(&self.write_lock);
        reset(&self.file, &self.saved, self.kitty_push.is_some(), true)
    }

    /// Restores the terminal, stops the whole process group with SIGSTOP and,
    /// once continued, re-enters raw mode and the alternate screen. Returns
    /// `Ok(true)` after SIGCONT, and exactly then `Event::Resumed` follows.
    /// `Ok(false)` after the final `restore` (nothing done). `Err` when the
    /// terminal could not be reset; the process is then not stopped.
    pub fn suspend(self: &Arc<Self>) -> io::Result<bool> {
        self.suspend_with(|| {
            // SAFETY: plain syscall; signals our own process group.
            unsafe { libc::kill(0, libc::SIGSTOP) };
            // Linux hands a process-wide signal to the main thread, so this
            // (scheduler) thread returns from kill before the group stop
            // reaches it and would re-raw the tty first. A thread-directed
            // stop holds it here; SIGCONT flushes the extra one on Linux.
            // XNU stops the caller inside kill and keeps a thread-pending
            // stop across SIGCONT, so this would stop macOS twice.
            #[cfg(target_os = "linux")]
            // SAFETY: plain syscall; signals the calling thread.
            unsafe {
                libc::raise(libc::SIGSTOP)
            };
        })
    }

    /// `suspend` with the stop injected, so tests can run it in-process.
    /// The write lock is held throughout, so the output thread cannot write
    /// while the host is cooked; it resumes behind the re-enter sequence.
    pub(crate) fn suspend_with(self: &Arc<Self>, stop: impl FnOnce()) -> io::Result<bool> {
        let _guard = lock(&self.write_lock);
        if self.restored.load(Ordering::Acquire) {
            return Ok(false);
        }
        reset(&self.file, &self.saved, self.kitty_push.is_some(), true)?;
        stop();
        // Best effort: the resumed caller repaints either way; nothing else to undo.
        let _ = set_raw(self.file.as_raw_fd(), &self.saved);
        let mut enter = ENTER.to_vec();
        enter.extend(self.kitty_push.iter().flatten());
        // Best effort, like open: a host that continued us is reading.
        let _ = write_by(&self.file, &enter, Instant::now() + WRITE_BUDGET);
        self.output.reset_frame();
        // The caller is a dirty scheduler, where the NIF sink cannot send, so
        // a short-lived thread delivers the event.
        let inner = Arc::clone(self);
        let _ = std::thread::Builder::new()
            .name("herdr-tty-resumed".into())
            .spawn(move || inner.run_guarded(|i| lock(&i.sub).deliver(Event::Resumed)));
        Ok(true)
    }

    /// Destructor path, never waits: signals the threads (which hold their
    /// own `Arc` and exit within `POLL_MS`), then makes one non-blocking
    /// restore write attempt if not already restored.
    fn shutdown(&self) {
        self.stop();
        if !self.restored.swap(true, Ordering::AcqRel) {
            // Waits for at most one non-blocking write syscall.
            let _guard = lock(&self.write_lock);
            let _ = reset(&self.file, &self.saved, self.kitty_push.is_some(), false);
        }
    }
}

/// Puts `fd` in raw mode derived from `saved` (`cfmakeraw`, `VMIN=1 VTIME=0`).
fn set_raw(fd: RawFd, saved: &libc::termios) -> io::Result<()> {
    let mut raw = *saved;
    // SAFETY: raw is a valid termios.
    unsafe { libc::cfmakeraw(&mut raw) };
    raw.c_cc[libc::VMIN] = 1;
    raw.c_cc[libc::VTIME] = 0;
    // SAFETY: valid fd and termios.
    cvt(unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) })
}

/// Writes the restore sequence and resets termios to `saved`. With `wait`,
/// the write may poll for up to `WRITE_BUDGET`; without, it is a single
/// non-blocking attempt and a partial write is accepted.
fn reset(file: &File, saved: &libc::termios, kitty_pushed: bool, wait: bool) -> io::Result<()> {
    let mut out = Vec::with_capacity(KITTY_POP.len() + RESTORE.len());
    if kitty_pushed {
        out.extend_from_slice(KITTY_POP);
    }
    out.extend_from_slice(RESTORE);
    // Best effort: a host that stopped reading must not keep us in raw mode.
    if wait {
        let _ = write_by(file, &out, Instant::now() + WRITE_BUDGET);
    } else {
        let _ = (&*file).write(&out);
    }
    // SAFETY: valid fd and a termios from tcgetattr.
    cvt(unsafe { libc::tcsetattr(file.as_raw_fd(), libc::TCSANOW, saved) })
}

/// The NIF resource. Dropping it (BEAM GC of the last reference) restores the
/// terminal and stops the threads.
pub struct TtyResource {
    pub inner: Arc<Inner>,
}

impl TtyResource {
    pub fn new(inner: Arc<Inner>) -> Self {
        TtyResource { inner }
    }
}

impl Drop for TtyResource {
    fn drop(&mut self) {
        self.inner.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::output::{Backpressure, FrameJob, WRITE_QUEUE_BYTES};
    use std::fs::File;
    use std::io::{Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    struct Pty {
        master: File,
        slave: File,
        path: String,
    }

    fn pty() -> Pty {
        let (mut m, mut s) = (0, 0);
        // SAFETY: openpty writes two fds; name/termios/winsize may be null.
        let rc = unsafe {
            libc::openpty(
                &mut m,
                &mut s,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(rc, 0, "openpty: {}", io::Error::last_os_error());
        // SAFETY: openpty returned owned fds.
        let (master, slave) = unsafe { (File::from_raw_fd(m), File::from_raw_fd(s)) };
        // ttyname_r: glibc's ttyname shares one static buffer across threads.
        let mut buf = [0 as libc::c_char; 128];
        // SAFETY: buf is writable for buf.len() bytes.
        let rc = unsafe { libc::ttyname_r(slave.as_raw_fd(), buf.as_mut_ptr(), buf.len()) };
        assert_eq!(rc, 0, "ttyname_r: {}", io::Error::from_raw_os_error(rc));
        // SAFETY: ttyname_r wrote a NUL-terminated string into buf.
        let path = unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        Pty {
            master,
            slave,
            path,
        }
    }

    fn termios(f: &File) -> libc::termios {
        // SAFETY: zeroed termios is a valid out-parameter.
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: valid fd and out-pointer.
        assert_eq!(unsafe { libc::tcgetattr(f.as_raw_fd(), &mut t) }, 0);
        t
    }

    fn same_termios(a: &libc::termios, b: &libc::termios) -> bool {
        a.c_iflag == b.c_iflag
            && a.c_oflag == b.c_oflag
            && a.c_cflag == b.c_cflag
            // PENDIN is kernel bookkeeping the BSD tty layer sets when ICANON is
        // re-enabled and clears on the next read; it is not configuration.
        && a.c_lflag & !libc::PENDIN == b.c_lflag & !libc::PENDIN
            && a.c_cc == b.c_cc
    }

    /// Reads from `f` until `want` appears or `timeout` passes; returns everything read.
    fn read_until(f: &File, want: &[u8], timeout: Duration) -> Vec<u8> {
        let deadline = Instant::now() + timeout;
        let mut out = Vec::new();
        while !out.windows(want.len().max(1)).any(|w| w == want) || want.is_empty() {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            match poll_fd(f.as_raw_fd(), libc::POLLIN, left.as_millis() as i32 + 1) {
                Ok(true) => {}
                _ => break,
            }
            let mut buf = [0u8; 4096];
            match (&*f).read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => out.extend_from_slice(&buf[..n]),
            }
        }
        out
    }

    fn contains(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }

    fn channel() -> (Box<dyn Sink>, mpsc::Receiver<Event>) {
        let (tx, rx) = mpsc::channel();
        (Box::new(tx), rx)
    }

    fn recv_input(rx: &mpsc::Receiver<Event>, want: &[u8]) -> Vec<u8> {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut got = Vec::new();
        while !contains(&got, want) {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            match rx.recv_timeout(left) {
                Ok(Event::Input(b)) => got.extend(b),
                Ok(other) => panic!("unexpected event {other:?}"),
                Err(_) => break,
            }
        }
        got
    }

    #[test]
    fn open_sets_raw_mode() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        let t = termios(&p.slave);
        assert_eq!(t.c_lflag & (libc::ICANON | libc::ECHO), 0);
        let out = read_until(&p.master, b"\x1b[c", Duration::from_secs(1));
        assert!(contains(&out, b"\x1b[?1049h"), "{out:?}");
        assert!(contains(&out, b"\x1b[?u\x1b[c"), "{out:?}");
        drop(tty);
    }

    #[test]
    fn probe_reads_kitty_flags() {
        let p = pty();
        let master = p.master.try_clone().unwrap();
        let replier = std::thread::spawn(move || {
            read_until(&master, b"\x1b[c", Duration::from_secs(1));
            (&master).write_all(b"\x1b[?15u\x1b[?62;22c").unwrap();
            master
        });
        let tty = TtyResource::new(Inner::open_path(&p.path, 1, None).unwrap());
        let master = replier.join().unwrap();
        assert_eq!(tty.inner.kitty(), Some(15));
        let out = read_until(&master, b"\x1b[>1u", Duration::from_secs(1));
        assert!(contains(&out, b"\x1b[>1u"), "{out:?}");
        drop(tty);
        let out = read_until(&master, b"\x1b[?1049l", Duration::from_secs(1));
        assert!(
            out.starts_with(b"\x1b[<u"),
            "pushed flags are popped: {out:?}"
        );
    }

    #[test]
    fn probe_times_out_without_reply() {
        let p = pty();
        let start = Instant::now();
        let tty = TtyResource::new(Inner::open_path(&p.path, 1, None).unwrap());
        assert!(start.elapsed() < Duration::from_millis(400));
        assert_eq!(tty.inner.kitty(), None);
        let out = read_until(&p.master, b"\x1b[>", Duration::from_millis(200));
        assert!(!contains(&out, b"\x1b[>"), "nothing pushed: {out:?}");
    }

    #[test]
    fn probe_keeps_user_bytes() {
        let p = pty();
        let master = p.master.try_clone().unwrap();
        let replier = std::thread::spawn(move || {
            read_until(&master, b"\x1b[c", Duration::from_secs(1));
            // Brief vector `\x1b[c` is the query, not a DA1 reply; replies carry `?`.
            (&master).write_all(b"ab\x1b[?1u\x1b[?62cZ").unwrap();
        });
        let (sink, rx) = channel();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, Some(sink)).unwrap());
        replier.join().unwrap();
        assert_eq!(tty.inner.kitty(), Some(1));
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(1)).ok(),
            Some(Event::Input(b"abZ".to_vec()))
        );
    }

    #[test]
    fn bytes_before_subscribe_are_delivered_first() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        (&p.master).write_all(b"early").unwrap();
        std::thread::sleep(Duration::from_millis(250));
        let (tx, rx) = mpsc::channel();
        let early = tx.clone();
        tty.inner.subscribe(Box::new(tx), |e| {
            let _ = early.send(e);
        });
        (&p.master).write_all(b"late").unwrap();
        assert_eq!(recv_input(&rx, b"earlylate"), b"earlylate");
    }

    #[test]
    fn input_reaches_subscriber() {
        let p = pty();
        let (sink, rx) = channel();
        let _tty = TtyResource::new(Inner::open_path(&p.path, 0, Some(sink)).unwrap());
        (&p.master).write_all(b"hello").unwrap();
        assert_eq!(recv_input(&rx, b"hello"), b"hello");
    }

    #[test]
    fn hangup_on_master_close() {
        let p = pty();
        let (sink, rx) = channel();
        let _tty = TtyResource::new(Inner::open_path(&p.path, 0, Some(sink)).unwrap());
        drop(p.master);
        drop(p.slave);
        let ev = rx.recv_timeout(Duration::from_secs(2));
        assert_eq!(ev.ok(), Some(Event::Hangup));
    }

    #[test]
    fn size_reports_winsize() {
        let p = pty();
        let ws = libc::winsize {
            ws_row: 30,
            ws_col: 100,
            ws_xpixel: 800,
            ws_ypixel: 600,
        };
        // SAFETY: valid fd and winsize pointer.
        assert_eq!(
            unsafe { libc::ioctl(p.master.as_raw_fd(), libc::TIOCSWINSZ, &ws) },
            0
        );
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        assert_eq!(tty.inner.size().unwrap(), (100, 30, 800, 600));
    }

    #[test]
    fn restore_is_idempotent() {
        let p = pty();
        let before = termios(&p.slave);
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        read_until(&p.master, b"\x1b[c", Duration::from_secs(1));
        tty.inner.restore().unwrap();
        assert!(same_termios(&termios(&p.slave), &before));
        let out = read_until(&p.master, b"\x1b[?1049l", Duration::from_secs(1));
        assert!(out.starts_with(b"\x1b[?1000l"), "no kitty pop: {out:?}");
        assert!(out.ends_with(b"\x1b[?1049l"), "{out:?}");
        tty.inner.restore().unwrap();
        drop(tty);
        let again = read_until(&p.master, b"", Duration::from_millis(200));
        assert!(
            again.is_empty(),
            "second restore and drop write nothing: {again:?}"
        );
        assert!(same_termios(&termios(&p.slave), &before));
    }

    #[test]
    fn drop_restores() {
        let p = pty();
        let before = termios(&p.slave);
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        let start = Instant::now();
        drop(tty);
        assert!(start.elapsed() < Duration::from_millis(400));
        assert!(same_termios(&termios(&p.slave), &before));
        let out = read_until(&p.master, b"\x1b[?1049l", Duration::from_secs(1));
        assert!(contains(&out, b"\x1b[?1049l"), "{out:?}");
    }

    #[test]
    fn drop_does_not_wait_on_blocked_host() {
        let p = pty();
        let before = termios(&p.slave);
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        // Fill the host's output queue; the master is never read.
        let junk = [b'x'; 4096];
        loop {
            match (&tty.inner.file).write(&junk) {
                Ok(_) => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("fill: {e}"),
            }
        }
        let start = Instant::now();
        drop(tty);
        let took = start.elapsed();
        assert!(took < Duration::from_millis(20), "drop took {took:?}");
        assert!(same_termios(&termios(&p.slave), &before));
    }

    /// A one-row frame drawing `text` (blit output contains it verbatim on
    /// a full redraw).
    fn frame(text: &str, repaint: bool) -> FrameJob {
        FrameJob {
            rows: vec![(0, crate::cell::ascii_row(text))],
            repaint,
            ..FrameJob::default()
        }
    }

    /// Fills the host's output queue directly; the master is never read.
    /// Linux moves pty output to the master's line discipline from a
    /// workqueue, freeing room after EAGAIN, so refill until it stays full.
    fn fill(tty: &TtyResource) {
        let junk = [b'x'; 4096];
        let mut wrote = true;
        while wrote {
            wrote = false;
            loop {
                match (&tty.inner.file).write(&junk) {
                    Ok(_) => wrote = true,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) => panic!("fill: {e}"),
                }
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_for(mut cond: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if cond() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        cond()
    }

    #[test]
    fn blocked_reader_does_not_block_write() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        let mut refused = 0;
        for _ in 0..64 {
            let chunk = vec![b'w'; 64 * 1024];
            let start = Instant::now();
            if tty.inner.output.write(chunk) == Err(Backpressure) {
                refused += 1;
            }
            let took = start.elapsed();
            assert!(took < Duration::from_millis(5), "write took {took:?}");
            assert!(tty.inner.output.stats().queued_bytes <= WRITE_QUEUE_BYTES);
        }
        assert!(refused > 0, "a blocked host must push back");
    }

    #[test]
    fn blocked_reader_drops_frames() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        fill(&tty);
        for i in 0..1000 {
            let start = Instant::now();
            tty.inner
                .output
                .submit_frame(frame(&format!("<F{i:04}>"), true));
            let took = start.elapsed();
            assert!(took < Duration::from_millis(5), "submit took {took:?}");
        }
        assert!(tty.inner.output.stats().frames_dropped >= 990);
        let mut out = read_until(&p.master, b"<F0999>", Duration::from_secs(5));
        out.extend(read_until(&p.master, b"", Duration::from_millis(200)));
        let last = out.windows(7).rposition(|w| w == b"<F0999>");
        let tail = &out[last.expect("last frame written") + 7..];
        // Only the last frame's cursor epilogue follows its cells.
        assert!(
            !contains(tail, b"<F"),
            "nothing after the last frame: {tail:?}"
        );
        assert!(tail.ends_with(b"\x1b[?2026l\x1b[1;7H\x1b[?25l"), "{tail:?}");
        assert!(wait_for(|| {
            let st = tty.inner.output.stats();
            st.frames_written + st.frames_dropped == 1000
        }));
    }

    #[test]
    fn superseded_repaint_is_kept() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        fill(&tty);
        tty.inner.output.submit_frame(frame("<A>", false));
        // Let the output thread take <A> so it is in flight, not pending.
        std::thread::sleep(Duration::from_millis(50));
        tty.inner.output.submit_frame(frame("<B>", true));
        tty.inner.output.submit_frame(frame("<C>", false));
        let out = read_until(&p.master, b"<C>", Duration::from_secs(5));
        // <C> inherits <B>'s repaint: a full redraw, not a one-cell diff.
        assert!(contains(&out, b"<A>") && !contains(&out, b"<B>"));
        assert!(contains(&out, b"\x1b[1;1H\x1b[0;39;49m<C>"), "{out:?}");
        assert_eq!(tty.inner.output.stats().frames_dropped, 1);
    }

    #[test]
    fn writes_and_frames_keep_order() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        read_until(&p.master, b"\x1b[c", Duration::from_secs(1));
        tty.inner.output.write(b"<A>".to_vec()).unwrap();
        tty.inner.output.submit_frame(frame("<B>", false));
        tty.inner.output.write(b"<C>".to_vec()).unwrap();
        let out = read_until(&p.master, b"<C>", Duration::from_secs(2));
        let frame = &out[3..out.len() - 3];
        assert!(out.starts_with(b"<A>") && out.ends_with(b"<C>"), "{out:?}");
        assert!(frame.starts_with(b"\x1b[?2026h") && contains(frame, b"<B>"));
    }

    #[test]
    fn drop_with_blocked_reader_returns_quickly() {
        let p = pty();
        let before = termios(&p.slave);
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        for _ in 0..64 {
            let _ = tty.inner.output.write(vec![b'w'; 64 * 1024]);
        }
        tty.inner.output.submit_frame(frame("<F>", true));
        let start = Instant::now();
        drop(tty);
        let took = start.elapsed();
        assert!(took < Duration::from_millis(500), "drop took {took:?}");
        assert!(same_termios(&termios(&p.slave), &before));
    }

    #[test]
    fn output_after_restore_is_discarded() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        tty.inner.restore().unwrap();
        read_until(&p.master, b"\x1b[?1049l", Duration::from_secs(1));
        assert_eq!(tty.inner.output.write(b"late".to_vec()), Ok(()));
        tty.inner.output.submit_frame(frame("late", false));
        let out = read_until(&p.master, b"", Duration::from_millis(300));
        assert!(out.is_empty(), "{out:?}");
    }

    #[test]
    fn resume_reapplies_raw_and_resets_frame() {
        let p = pty();
        let master = p.master.try_clone().unwrap();
        let replier = std::thread::spawn(move || {
            read_until(&master, b"\x1b[c", Duration::from_secs(1));
            (&master).write_all(b"\x1b[?0u\x1b[?62c").unwrap();
        });
        let (sink, rx) = channel();
        let tty = TtyResource::new(Inner::open_path(&p.path, 1, Some(sink)).unwrap());
        replier.join().unwrap();
        tty.inner.output.submit_frame(frame("<A>", false));
        read_until(&p.master, b"<A>", Duration::from_secs(2));
        assert!(wait_for(|| tty.inner.output.stats().frames_written == 1));

        let mut stopped_lflag = 0;
        let stopped = tty
            .inner
            .suspend_with(|| {
                stopped_lflag = termios(&p.slave).c_lflag;
                // The output thread must hold this until after resume.
                tty.inner.output.write(b"<W>".to_vec()).unwrap();
                std::thread::sleep(Duration::from_millis(150));
            })
            .unwrap();
        assert!(stopped);
        let cooked = libc::ICANON | libc::ECHO;
        assert_eq!(stopped_lflag & cooked, cooked, "cooked while stopped");
        assert_eq!(termios(&p.slave).c_lflag & cooked, 0, "raw after resume");

        let out = read_until(&p.master, b"<W>", Duration::from_secs(2));
        let at = |needle: &[u8]| out.windows(needle.len()).position(|w| w == needle);
        let (pop, leave, enter, push, w) = (
            at(b"\x1b[<u"),
            at(b"\x1b[?1049l"),
            at(b"\x1b[?1049h"),
            at(b"\x1b[>1u"),
            at(b"<W>"),
        );
        assert!(
            pop < leave && leave < enter && enter < push && push < w && pop.is_some(),
            "{out:?}"
        );
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(1)).ok(),
            Some(Event::Resumed)
        );
        tty.inner.output.submit_frame(frame("<A>", false));
        let out = read_until(&p.master, b"<A>", Duration::from_secs(2));
        assert!(contains(&out, b"\x1b[2J"), "full repaint: {out:?}");
    }

    #[test]
    fn suspend_that_cannot_reset_neither_stops_nor_resumes() {
        let p = pty();
        let (sink, rx) = channel();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, Some(sink)).unwrap());
        // A non-tty behind the fd makes the reset's tcsetattr fail.
        let null = File::open("/dev/null").unwrap();
        // SAFETY: both fds are open; dup2 atomically replaces the tty fd.
        assert!(unsafe { libc::dup2(null.as_raw_fd(), tty.inner.file.as_raw_fd()) } >= 0);
        let mut called = false;
        assert!(tty.inner.suspend_with(|| called = true).is_err());
        assert!(!called);
        let resumed = std::iter::from_fn(|| rx.recv_timeout(Duration::from_millis(300)).ok())
            .any(|e| e == Event::Resumed);
        assert!(!resumed);
    }

    #[test]
    fn suspend_after_restore_does_nothing() {
        let p = pty();
        let tty = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        tty.inner.restore().unwrap();
        read_until(&p.master, b"\x1b[?1049l", Duration::from_secs(1));
        let mut called = false;
        assert!(!tty.inner.suspend_with(|| called = true).unwrap());
        assert!(!called);
        let out = read_until(&p.master, b"", Duration::from_millis(200));
        assert!(out.is_empty(), "{out:?}");
    }

    #[test]
    fn restored_reader_leaves_input_to_next_open() {
        let p = pty();
        let first = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        read_until(&p.master, b"\x1b[c", Duration::from_secs(1));
        first.inner.restore().unwrap();
        let master = p.master.try_clone().unwrap();
        let replier = std::thread::spawn(move || {
            read_until(&master, b"\x1b[?u\x1b[c", Duration::from_secs(1));
            (&master).write_all(b"\x1b[?3u\x1b[?62c").unwrap();
        });
        // The first reader may still be polling; it must not take the reply.
        let second = TtyResource::new(Inner::open_path(&p.path, 0, None).unwrap());
        replier.join().unwrap();
        assert_eq!(second.inner.kitty(), Some(3));
    }

    #[test]
    fn open_rejects_missing_path() {
        assert!(Inner::open_path("/nonexistent", 0, None).is_err());
    }
}
