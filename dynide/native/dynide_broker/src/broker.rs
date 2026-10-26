//! Poll loop and state machine. Single thread: `poll(2)` over the listener,
//! every connection and the signal self-pipe. Holds entries (fds + blob) sent
//! by the primary VM, keeps a warm standby, and runs the crash and graceful
//! handoffs (m5 plan rulings 3, 7-15).

use crate::log::{event, log};
use dynide_fdpass::{self as fp, kind, Frame};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::ffi::OsString;
use std::io::{self, Read};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Primary,
    Standby,
    Target,
}

impl Role {
    fn name(self) -> &'static str {
        match self {
            Role::Primary => "primary",
            Role::Standby => "standby",
            Role::Target => "target",
        }
    }
}

/// VM process control. The real one is `vm::Real`; tests connect fake VMs.
pub trait Spawner {
    /// Starts `argv` (the broker's current VM argv, or a restart's own) as VM `gen`.
    fn spawn(&mut self, gen: u64, role: Role, argv: &[OsString]) -> io::Result<u32>;
    fn signal(&mut self, pid: u32, sig: i32);
    /// Children reaped since the last call: `(pid, exit code or -signal)`.
    fn reap(&mut self) -> Vec<(u32, i32)>;
}

/// Ruling 12 timeouts; tests shorten them.
pub struct Config {
    pub sock: PathBuf,
    /// The VM argv every spawn uses until a CTL_RESTART with its own argv succeeds.
    pub argv: Vec<OsString>,
    pub hello_timeout: Duration,
    pub prepared_timeout: Duration,
    pub restored_timeout: Duration,
    pub release_timeout: Duration,
    pub stop_grace: Duration,
    pub shutdown_grace: Duration,
    pub frame_timeout: Duration,
    /// After a primary's link EOF, how long to wait for its exit status: 0 is a
    /// deliberate quit (clean broker stop), anything else or no exit a crash.
    pub exit_grace: Duration,
}

impl Config {
    pub fn new(sock: PathBuf, argv: Vec<OsString>) -> Config {
        let s = Duration::from_secs;
        Config {
            sock,
            argv,
            hello_timeout: s(120),
            prepared_timeout: s(5),
            restored_timeout: s(5),
            release_timeout: s(5),
            stop_grace: s(2),
            shutdown_grace: s(15),
            frame_timeout: s(5),
            // a clean quit under load must not read as a crash
            exit_grace: s(5),
        }
    }
}

pub struct Outcome {
    pub code: i32,
    /// The last primary VM did not exit 0 (the tty guard writes its sequence).
    pub crashed: bool,
}

/// ETF `{:error, :closed}`: the reply to a request whose VM died first.
const ERR_CLOSED: &[u8] = b"\x83h\x02w\x05errorw\x06closed";

struct Entry {
    fds: Vec<OwnedFd>,
    blob: Vec<u8>,
}

/// A spawned VM, kept until reaped (so only unreaped pids are ever signalled).
struct Vm {
    pid: u32,
    conn: Option<u64>,
    /// Sent HELLO.
    ready: bool,
    /// No link EOF or reap seen yet.
    alive: bool,
    released: bool,
    /// Sent PREPARED (until THAW): its HOLD/UPDATE/DROP are ignored, since the
    /// target already got the entries.
    prepared: bool,
    /// Logged one ignored frame since `prepared`.
    warned: bool,
}

/// A queued ctl reply; replies leave in request order.
struct Slot {
    id: u64,
    reply: Option<(u8, Vec<u8>)>,
}

enum ConnKind {
    New,
    Vm(u64),
    Ctl(VecDeque<Slot>),
}

struct Conn {
    sock: UnixStream,
    kind: ConnKind,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Step {
    Booting,
    Preparing,
    Adopting,
}

#[derive(Clone)]
enum Plan {
    Idle,
    /// Waiting for `gen`'s HELLO, then FRESH (`restore`: after a lost session).
    Fresh {
        gen: u64,
        restore: bool,
    },
    /// Ruling 13: adopt into `to` (`sent` = entries once ADOPT_END went out).
    Crash {
        from: u64,
        to: u64,
        attempts: u32,
        t0: Instant,
        sent: Option<usize>,
    },
    /// Ruling 9. `t0` is when PREPARE went out.
    Graceful {
        old: u64,
        to: u64,
        step: Step,
        t0: Instant,
        sent: usize,
    },
    /// Graceful failed: `to` was SIGKILLed; THAW `old` once it is dead.
    Thawing {
        old: u64,
        to: u64,
        froze: bool,
        reason: String,
    },
    /// RELEASE sent; waiting for `old` to exit before booting a standby.
    Releasing {
        old: u64,
    },
    Stopping,
}

struct Req {
    conn: u64,
    sent_to: Option<u64>,
}

pub struct Broker<S: Spawner> {
    cfg: Config,
    spawner: S,
    sig: Option<UnixStream>,
    listener: UnixListener,
    conns: BTreeMap<u64, Conn>,
    next_token: u64,
    /// Conns to close after the current event (never re-entrantly).
    closing: Vec<u64>,
    vms: BTreeMap<u64, Vm>,
    next_gen: u64,
    primary: Option<u64>,
    standby: Option<u64>,
    last_primary: Option<u64>,
    last_primary_status: Option<i32>,
    plan: Plan,
    deadline: Option<Instant>,
    kills: Vec<(Instant, u64)>,
    /// Primaries whose link closed, waiting for their exit status until the instant.
    exit_waits: Vec<(Instant, u64)>,
    entries: BTreeMap<Vec<u8>, Entry>,
    /// HOLD/UPDATE/DROP from the adoption target, applied at its RESTORED.
    staged: Vec<Frame>,
    next_ref: u64,
    requests: HashMap<u64, Req>,
    queue: VecDeque<(u64, Vec<u8>)>,
    /// The ctl slot waiting for the graceful result.
    restart: Option<(u64, u64)>,
    /// The running restart's own VM argv (CTL_RESTART body): adopted as `cfg.argv`
    /// only when that restart succeeds, so a failure never boots it again.
    restart_argv: Option<Vec<OsString>>,
    handoffs: u64,
    last_kind: Option<&'static str>,
    last_ms: Option<u128>,
    code: i32,
}

fn be_u64(b: &[u8], at: usize) -> Option<u64> {
    Some(u64::from_be_bytes(b.get(at..at + 8)?.try_into().ok()?))
}

fn be_u32(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

/// CTL_RESTART body: empty, or the VM argv with each argument NUL-terminated.
pub fn encode_argv(argv: &[OsString]) -> Vec<u8> {
    use std::os::unix::ffi::OsStrExt;
    let mut b = Vec::new();
    for a in argv {
        b.extend(a.as_bytes());
        b.push(0);
    }
    b
}

fn decode_argv(body: &[u8]) -> Option<Vec<OsString>> {
    use std::os::unix::ffi::OsStrExt;
    let args = body.strip_suffix(&[0])?;
    let argv: Vec<OsString> = args
        .split(|b| *b == 0)
        .map(|a| std::ffi::OsStr::from_bytes(a).to_os_string())
        .collect();
    argv.first().is_some_and(|a| !a.is_empty()).then_some(argv)
}

fn show_argv(argv: &[OsString]) -> String {
    argv.iter()
        .map(|a| a.to_string_lossy())
        .collect::<Vec<_>>()
        .join(" ")
}

fn result_body(ok: bool, text: &str) -> Vec<u8> {
    let mut b = vec![ok as u8];
    b.extend(text.as_bytes());
    b
}

fn pollfd(fd: i32) -> libc::pollfd {
    libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    }
}

impl<S: Spawner> Broker<S> {
    /// Binds `cfg.sock` (mode 0600). `sig` is the signal self-pipe read end.
    pub fn new(cfg: Config, spawner: S, sig: UnixStream) -> io::Result<Self> {
        let listener = UnixListener::bind(&cfg.sock)?;
        std::fs::set_permissions(&cfg.sock, std::fs::Permissions::from_mode(0o600))?;
        listener.set_nonblocking(true)?;
        Ok(Broker {
            cfg,
            spawner,
            sig: Some(sig),
            listener,
            conns: BTreeMap::new(),
            next_token: 0,
            closing: Vec::new(),
            vms: BTreeMap::new(),
            next_gen: 1,
            primary: None,
            standby: None,
            last_primary: None,
            last_primary_status: None,
            plan: Plan::Idle,
            deadline: None,
            kills: Vec::new(),
            exit_waits: Vec::new(),
            entries: BTreeMap::new(),
            staged: Vec::new(),
            next_ref: 1,
            requests: HashMap::new(),
            queue: VecDeque::new(),
            restart: None,
            restart_argv: None,
            handoffs: 0,
            last_kind: None,
            last_ms: None,
            code: 0,
        })
    }

    /// Runs until a stop completes and every VM is reaped; removes the socket.
    pub fn run(&mut self) -> io::Result<Outcome> {
        match self.spawn_vm(Role::Primary) {
            Some(gen) => {
                self.plan = Plan::Fresh {
                    gen,
                    restore: false,
                }
            }
            None => self.begin_stop(1),
        }
        while !(matches!(self.plan, Plan::Stopping) && self.vms.is_empty()) {
            self.poll_once()?;
            self.close_pending();
            self.fire_timers();
            self.close_pending();
        }
        let _ = std::fs::remove_file(&self.cfg.sock);
        Ok(Outcome {
            code: self.code,
            crashed: self.last_primary_status.is_some_and(|s| s != 0),
        })
    }

    fn poll_once(&mut self) -> io::Result<()> {
        let mut pfds = vec![
            pollfd(self.sig.as_ref().map_or(-1, |s| s.as_raw_fd())),
            pollfd(self.listener.as_raw_fd()),
        ];
        let mut tokens = Vec::with_capacity(self.conns.len());
        for (t, c) in &self.conns {
            tokens.push(*t);
            pfds.push(pollfd(c.sock.as_raw_fd()));
        }
        let timeout = self.wake_ms();
        // SAFETY: pfds is a live, correctly sized pollfd array.
        let n = unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, timeout) };
        if n < 0 {
            let e = io::Error::last_os_error();
            return if e.kind() == io::ErrorKind::Interrupted {
                Ok(())
            } else {
                Err(e)
            };
        }
        if pfds[0].revents != 0 {
            self.on_signals();
        }
        if pfds[1].revents != 0 {
            self.accept();
        }
        for (i, t) in tokens.into_iter().enumerate() {
            if pfds[i + 2].revents != 0 {
                self.read_one(t);
            }
        }
        Ok(())
    }

    fn wake_ms(&self) -> i32 {
        let next = self
            .kills
            .iter()
            .chain(&self.exit_waits)
            .map(|k| k.0)
            .chain(self.deadline)
            .min();
        next.map_or(-1, |at| {
            let ms = at.saturating_duration_since(Instant::now()).as_millis() + 1;
            ms.min(i32::MAX as u128) as i32
        })
    }

    fn on_signals(&mut self) {
        let mut buf = [0u8; 64];
        let n = match self.sig.as_mut().map(|s| s.read(&mut buf)) {
            Some(Ok(n)) => n,
            _ => return,
        };
        if n == 0 {
            // Write end gone: no more signals can arrive, so stop.
            self.sig = None;
            self.begin_stop(0);
            return;
        }
        if buf[..n].contains(&b'C') {
            self.reap();
        }
        if buf[..n].contains(&b'T') {
            self.begin_stop(0);
        }
    }

    fn accept(&mut self) {
        loop {
            match self.listener.accept() {
                Ok((s, _)) => {
                    // macOS accept inherits O_NONBLOCK from the listener.
                    if s.set_nonblocking(false).is_err()
                        || fp::set_timeouts(s.as_fd(), self.cfg.frame_timeout).is_err()
                    {
                        continue;
                    }
                    let t = self.next_token;
                    self.next_token += 1;
                    self.conns.insert(
                        t,
                        Conn {
                            sock: s,
                            kind: ConnKind::New,
                        },
                    );
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return,
            }
        }
    }

    /// One whole frame (blocking, frame_timeout). Any error closes the conn:
    /// after a timeout the stream position is unknown.
    fn read_one(&mut self, t: u64) {
        if self.closing.contains(&t) {
            return;
        }
        let Some(c) = self.conns.get(&t) else { return };
        match fp::recv_frame(c.sock.as_fd()) {
            Ok(Some(f)) => self.on_frame(t, f),
            Ok(None) => self.closing.push(t),
            Err(e) => {
                log!("connection read: {e}");
                self.closing.push(t);
            }
        }
    }

    fn close_pending(&mut self) {
        while let Some(t) = self.closing.pop() {
            let Some(c) = self.conns.remove(&t) else {
                continue;
            };
            match c.kind {
                ConnKind::Vm(gen) => self.link_closed(gen),
                ConnKind::Ctl(_) => {
                    self.requests.retain(|_, r| r.conn != t);
                    if self.restart.is_some_and(|(rt, _)| rt == t) {
                        self.restart = None;
                    }
                }
                ConnKind::New => {}
            }
        }
    }

    fn fire_timers(&mut self) {
        let now = Instant::now();
        let mut due = Vec::new();
        self.kills.retain(|&(at, gen)| {
            let fire = at <= now;
            if fire {
                due.push(gen);
            }
            !fire
        });
        for gen in due {
            self.kill(gen);
        }
        let mut lapsed = Vec::new();
        self.exit_waits.retain(|&(at, gen)| {
            let fire = at <= now;
            if fire {
                lapsed.push(gen);
            }
            !fire
        });
        for gen in lapsed {
            // Link gone but no exit status within exit_grace: a crash.
            if let Some(v) = self.vms.get_mut(&gen).filter(|v| v.alive) {
                v.alive = false;
                let (pid, ready) = (v.pid, v.ready);
                self.spawner.signal(pid, libc::SIGKILL);
                self.vm_died(gen, ready, "eof");
            }
        }
        if self.deadline.is_some_and(|d| d <= now) {
            self.deadline = None;
            self.on_timeout();
        }
    }

    fn on_timeout(&mut self) {
        match self.plan.clone() {
            Plan::Crash { sent, .. } => self.crash_fail(if sent.is_some() {
                "timeout waiting for restored"
            } else {
                "timeout waiting for hello"
            }),
            Plan::Graceful { step, .. } => self.graceful_fail(match step {
                Step::Booting => "timeout waiting for hello",
                Step::Preparing => "timeout waiting for prepared",
                Step::Adopting => "timeout waiting for restored",
            }),
            Plan::Thawing { .. } => self.thaw(),
            _ => {}
        }
    }

    // ---- frames ----

    fn on_frame(&mut self, t: u64, f: Frame) {
        let Some(c) = self.conns.get_mut(&t) else {
            return;
        };
        if matches!(c.kind, ConnKind::New) && (0x81..=0x83).contains(&f.kind) {
            c.kind = ConnKind::Ctl(VecDeque::new());
        }
        match c.kind {
            ConnKind::New if f.kind == kind::HELLO => self.on_hello(t, &f.body),
            ConnKind::New => self.closing.push(t),
            ConnKind::Vm(gen) => self.on_vm_frame(gen, f),
            ConnKind::Ctl(_) => self.on_ctl_frame(t, f),
        }
    }

    fn on_hello(&mut self, t: u64, body: &[u8]) {
        let (Some(gen), Some(os_pid)) = (be_u64(body, 0), be_u32(body, 8)) else {
            self.closing.push(t);
            return;
        };
        let wanted = self.standby == Some(gen) || self.plan_target() == Some(gen);
        let Some(vm) = self
            .vms
            .get_mut(&gen)
            .filter(|v| wanted && v.alive && v.conn.is_none())
        else {
            log!("unexpected hello gen={gen}");
            self.closing.push(t);
            return;
        };
        if vm.pid != os_pid {
            // Not the process we spawned (or a confused one): never trust it with fds.
            log!(
                "vm gen={gen} reports pid={os_pid}, spawned pid={}; killing it",
                vm.pid
            );
            vm.alive = false;
            let pid = vm.pid;
            self.closing.push(t);
            self.spawner.signal(pid, libc::SIGKILL);
            self.vm_died(gen, false, "bad hello");
            return;
        }
        vm.conn = Some(t);
        vm.ready = true;
        if let Some(c) = self.conns.get_mut(&t) {
            c.kind = ConnKind::Vm(gen);
        }
        match self.plan.clone() {
            Plan::Fresh { gen: g, restore } if g == gen => {
                // FRESH body: 0 boot, 1 fallback after failed adoptions
                if self.send(t, kind::FRESH, &[u8::from(restore)]) {
                    self.promote(gen);
                    self.go_idle();
                }
            }
            Plan::Crash { to, .. } if to == gen => self.crash_adopt(),
            Plan::Graceful {
                old,
                to,
                step: Step::Booting,
                sent,
                ..
            } if to == gen => match self.vm_conn(old) {
                Some(ot) if self.send(ot, kind::PREPARE, &[]) => {
                    self.plan = Plan::Graceful {
                        old,
                        to,
                        step: Step::Preparing,
                        t0: Instant::now(),
                        sent,
                    };
                    self.deadline = Some(Instant::now() + self.cfg.prepared_timeout);
                }
                _ => self.graceful_fail("old vm unreachable"),
            },
            // The standby just becomes ready; it gets nothing until promoted.
            _ => {}
        }
    }

    fn on_vm_frame(&mut self, gen: u64, f: Frame) {
        match f.kind {
            kind::HOLD | kind::UPDATE | kind::DROP => {
                if let Some(v) = self.vms.get_mut(&gen).filter(|v| v.prepared) {
                    if !v.warned {
                        v.warned = true;
                        log!("vm gen={gen} sent {:#x} after PREPARED; ignored", f.kind);
                    }
                } else if self.primary == Some(gen) {
                    self.apply(f);
                } else if self.plan_target() == Some(gen) {
                    self.staged.push(f);
                }
            }
            kind::RESTORED => self.on_restored(gen),
            kind::PREPARED => self.on_prepared(gen),
            kind::REPLY => {
                if let Some(r) = be_u64(&f.body, 0) {
                    self.on_reply(r, &f.body[8..]);
                }
            }
            k => log!("vm gen={gen} sent unknown kind {k:#x}"),
        }
    }

    fn apply(&mut self, f: Frame) {
        let Ok((key, rest)) = fp::take_key(&f.body) else {
            log!("frame {:#x} with a bad key", f.kind);
            return;
        };
        match f.kind {
            kind::HOLD => {
                let e = Entry {
                    fds: f.fds,
                    blob: rest.to_vec(),
                };
                // Replacing closes the old entry's fds.
                self.entries.insert(key.to_vec(), e);
            }
            kind::UPDATE => {
                if let Some(e) = self.entries.get_mut(key) {
                    e.blob = rest.to_vec();
                }
            }
            _ => {
                self.entries.remove(key);
            }
        }
    }

    fn on_ctl_frame(&mut self, t: u64, f: Frame) {
        let id = self.next_ref;
        self.next_ref += 1;
        if let Some(Conn {
            kind: ConnKind::Ctl(slots),
            ..
        }) = self.conns.get_mut(&t)
        {
            slots.push_back(Slot { id, reply: None });
        }
        match f.kind {
            kind::CTL_STATUS => {
                let s = self.status_text();
                self.ctl_fill(t, id, kind::CTL_STATUS_REPLY, s.into_bytes());
            }
            kind::CTL_RESTART => self.begin_graceful(t, id, decode_argv(&f.body)),
            _ => {
                self.requests.insert(
                    id,
                    Req {
                        conn: t,
                        sent_to: None,
                    },
                );
                self.queue.push_back((id, f.body));
                self.flush_requests();
            }
        }
    }

    fn ctl_fill(&mut self, t: u64, id: u64, k: u8, body: Vec<u8>) {
        let Some(c) = self.conns.get_mut(&t) else {
            return;
        };
        let ConnKind::Ctl(slots) = &mut c.kind else {
            return;
        };
        if let Some(s) = slots.iter_mut().find(|s| s.id == id) {
            s.reply = Some((k, body));
        }
        while slots.front().is_some_and(|s| s.reply.is_some()) {
            let Some(Slot {
                reply: Some((k, b)),
                ..
            }) = slots.pop_front()
            else {
                break;
            };
            if fp::send_frame(c.sock.as_fd(), k, &b, &[]).is_err() {
                self.closing.push(t);
                break;
            }
        }
    }

    fn on_reply(&mut self, r: u64, payload: &[u8]) {
        if let Some(req) = self.requests.remove(&r) {
            self.ctl_fill(req.conn, r, kind::CTL_REPLY, payload.to_vec());
        }
    }

    /// Ruling 10: forward in order unless there is no primary or it is frozen.
    fn flush_requests(&mut self) {
        if matches!(self.phase(), "preparing" | "adopting" | "stopping") {
            return;
        }
        let Some(p) = self.primary else { return };
        let Some(t) = self.vm_conn(p) else { return };
        while let Some((r, payload)) = self.queue.pop_front() {
            let Some(req) = self.requests.get_mut(&r) else {
                continue;
            };
            req.sent_to = Some(p);
            let mut b = r.to_be_bytes().to_vec();
            b.extend(&payload);
            if !self.send(t, kind::REQUEST, &b) {
                if let Some(req) = self.requests.get_mut(&r) {
                    req.sent_to = None;
                }
                self.queue.push_front((r, payload));
                return;
            }
        }
    }

    // ---- handoff ----

    fn on_restored(&mut self, gen: u64) {
        match self.plan.clone() {
            Plan::Crash {
                from,
                to,
                t0,
                sent: Some(k),
                ..
            } if to == gen => {
                self.promote(gen);
                let ms = t0.elapsed().as_millis();
                log!("handoff crash gen={from} -> gen={to} entries={k} ms={ms}");
                event!("broker_handoff", "kind" => "crash", "from" => from, "to" => to, "entries" => k, "ms" => ms);
                self.record("crash", ms);
                self.go_idle();
            }
            Plan::Graceful {
                old,
                to,
                step: Step::Adopting,
                t0,
                sent,
            } if to == gen => {
                self.promote(gen);
                let ms = t0.elapsed().as_millis();
                log!("handoff graceful gen={old} -> gen={to} entries={sent} ms={ms}");
                event!("broker_handoff", "kind" => "graceful", "from" => old, "to" => to, "entries" => sent, "ms" => ms);
                self.record("graceful", ms);
                let old_alive = match self.vms.get_mut(&old) {
                    Some(v) => {
                        v.released = true;
                        v.alive
                    }
                    None => false,
                };
                if let Some(ot) = self.vm_conn(old) {
                    self.send(ot, kind::RELEASE, &[]);
                }
                self.kills
                    .push((Instant::now() + self.cfg.release_timeout, old));
                self.reply_restart(
                    true,
                    &format!("ok gen={old} -> gen={to} entries={sent} ms={ms}"),
                );
                self.deadline = None;
                if old_alive {
                    self.plan = Plan::Releasing { old };
                    self.flush_requests();
                } else {
                    self.go_idle();
                }
            }
            _ => {}
        }
    }

    fn on_prepared(&mut self, gen: u64) {
        let Plan::Graceful {
            old,
            to,
            step: Step::Preparing,
            t0,
            ..
        } = self.plan.clone()
        else {
            return;
        };
        if old != gen {
            return;
        }
        if let Some(v) = self.vms.get_mut(&old) {
            v.prepared = true;
        }
        match self.send_adopt(to, 0) {
            Some(sent) => {
                self.plan = Plan::Graceful {
                    old,
                    to,
                    step: Step::Adopting,
                    t0,
                    sent,
                };
                self.deadline = Some(Instant::now() + self.cfg.restored_timeout);
            }
            None => self.graceful_fail("adopt send failed"),
        }
    }

    /// Every held entry as ADOPT, then ADOPT_END. Returns the entry count.
    fn send_adopt(&mut self, to: u64, reason: u8) -> Option<usize> {
        let t = self.vm_conn(to)?;
        let c = self.conns.get(&t)?;
        let mut res = Ok(());
        for (key, e) in &self.entries {
            let mut body = Vec::with_capacity(2 + key.len() + e.blob.len());
            fp::put_key(&mut body, key);
            body.extend(&e.blob);
            let fds: Vec<BorrowedFd<'_>> = e.fds.iter().map(|f| f.as_fd()).collect();
            res = fp::send_frame(c.sock.as_fd(), kind::ADOPT, &body, &fds);
            if res.is_err() {
                break;
            }
        }
        let n = self.entries.len();
        if res.is_ok() {
            let mut b = (n as u32).to_be_bytes().to_vec();
            b.push(reason);
            res = fp::send_frame(c.sock.as_fd(), kind::ADOPT_END, &b, &[]);
        }
        match res {
            Ok(()) => {
                log!("adopt sent to gen={to} entries={n}");
                Some(n)
            }
            Err(e) => {
                log!("adopt send to gen={to}: {e}");
                self.closing.push(t);
                None
            }
        }
    }

    fn begin_crash(&mut self, from: u64) {
        if let Plan::Graceful { old, to, .. } | Plan::Thawing { old, to, .. } = self.plan.clone() {
            if old == from {
                self.kill(to);
                self.reply_restart(false, "failed: old vm died");
            }
        }
        let reuse = self.standby.take();
        self.crash_try(from, 0, Instant::now(), reuse);
    }

    fn crash_try(&mut self, from: u64, mut attempts: u32, t0: Instant, mut reuse: Option<u64>) {
        self.staged.clear();
        loop {
            if attempts >= 3 {
                self.fallback_restore(from);
                return;
            }
            let Some(to) = reuse.take().or_else(|| self.spawn_vm(Role::Target)) else {
                attempts += 1;
                continue;
            };
            self.plan = Plan::Crash {
                from,
                to,
                attempts,
                t0,
                sent: None,
            };
            if self.vms.get(&to).is_some_and(|v| v.ready) {
                self.crash_adopt();
            } else {
                self.deadline = Some(Instant::now() + self.cfg.hello_timeout);
            }
            return;
        }
    }

    fn crash_adopt(&mut self) {
        let Plan::Crash {
            from,
            to,
            attempts,
            t0,
            ..
        } = self.plan.clone()
        else {
            return;
        };
        match self.send_adopt(to, 1) {
            Some(n) => {
                self.plan = Plan::Crash {
                    from,
                    to,
                    attempts,
                    t0,
                    sent: Some(n),
                };
                self.deadline = Some(Instant::now() + self.cfg.restored_timeout);
            }
            None => self.crash_fail("adopt send failed"),
        }
    }

    fn crash_fail(&mut self, reason: &str) {
        let Plan::Crash {
            from,
            to,
            attempts,
            t0,
            ..
        } = self.plan.clone()
        else {
            return;
        };
        log!(
            "handoff failed: {reason} (crash gen={from} -> gen={to}, attempt {})",
            attempts + 1
        );
        event!("broker_handoff_failed", "reason" => reason, "from" => from, "to" => to);
        self.kill(to);
        self.crash_try(from, attempts + 1, t0, None);
    }

    /// Ruling 13's disk-restore hook (M8): held fds close and a fresh VM is told
    /// (FRESH body 1) that it restores a lost session from disk.
    fn fallback_restore(&mut self, lost: u64) {
        log!("handoff failed; fresh vm restores from disk");
        event!("session_lost", "reason" => "fallback_restore", "gen" => lost);
        self.entries.clear();
        self.deadline = None;
        match self.spawn_vm(Role::Primary) {
            Some(gen) => self.plan = Plan::Fresh { gen, restore: true },
            None => self.begin_stop(1),
        }
    }

    fn begin_graceful(&mut self, t: u64, id: u64, argv: Option<Vec<OsString>>) {
        let old = match (self.primary, &self.plan) {
            (Some(p), Plan::Idle) => p,
            _ => {
                let text = format!("failed: busy, phase={}", self.phase());
                self.ctl_fill(t, id, kind::CTL_RESULT, result_body(false, &text));
                return;
            }
        };
        self.restart = Some((t, id));
        if let Some(a) = &argv {
            log!("restart with vm argv {}", show_argv(a));
        }
        let target = argv.clone().unwrap_or_else(|| self.cfg.argv.clone());
        self.restart_argv = argv;
        if let Some(s) = self.standby.take() {
            self.terminate(s, self.cfg.stop_grace);
        }
        match self.spawn_with(Role::Target, &target) {
            Some(to) => {
                self.plan = Plan::Graceful {
                    old,
                    to,
                    step: Step::Booting,
                    t0: Instant::now(),
                    sent: 0,
                };
                self.deadline = Some(Instant::now() + self.cfg.hello_timeout);
            }
            None => {
                log!("handoff failed: spawn failed");
                event!("broker_handoff_failed", "reason" => "spawn failed", "from" => old, "to" => "none");
                self.reply_restart(false, "failed: spawn failed");
                self.go_idle();
            }
        }
    }

    fn graceful_fail(&mut self, reason: &str) {
        let Plan::Graceful { old, to, step, .. } = self.plan.clone() else {
            return;
        };
        log!("handoff failed: {reason} (graceful gen={old} -> gen={to})");
        event!("broker_handoff_failed", "reason" => reason, "from" => old, "to" => to);
        self.kill(to);
        self.staged.clear();
        self.plan = Plan::Thawing {
            old,
            to,
            froze: step != Step::Booting,
            reason: reason.to_string(),
        };
        self.deadline = Some(Instant::now() + self.cfg.stop_grace);
        if !self.vms.get(&to).is_some_and(|v| v.alive) {
            self.thaw();
        }
    }

    fn thaw(&mut self) {
        let Plan::Thawing {
            old, froze, reason, ..
        } = self.plan.clone()
        else {
            return;
        };
        if froze {
            if let Some(v) = self.vms.get_mut(&old) {
                (v.prepared, v.warned) = (false, false);
            }
            if let Some(t) = self.vm_conn(old) {
                self.send(t, kind::THAW, &[]);
            }
        }
        self.reply_restart(false, &format!("failed: {reason}"));
        self.go_idle();
    }

    fn reply_restart(&mut self, ok: bool, text: &str) {
        // before any standby or crash boot that follows: those use the adopted argv
        if let (true, Some(a)) = (ok, self.restart_argv.take()) {
            log!("vm argv now {}", show_argv(&a));
            self.cfg.argv = a;
        }
        if let Some((t, id)) = self.restart.take() {
            self.ctl_fill(t, id, kind::CTL_RESULT, result_body(ok, text));
        }
    }

    fn record(&mut self, k: &'static str, ms: u128) {
        self.handoffs += 1;
        self.last_kind = Some(k);
        self.last_ms = Some(ms);
    }

    // ---- vm lifecycle ----

    fn spawn_vm(&mut self, role: Role) -> Option<u64> {
        let argv = self.cfg.argv.clone();
        self.spawn_with(role, &argv)
    }

    fn spawn_with(&mut self, role: Role, argv: &[OsString]) -> Option<u64> {
        let gen = self.next_gen;
        self.next_gen += 1;
        match self.spawner.spawn(gen, role, argv) {
            Ok(pid) => {
                log!("started vm gen={gen} pid={pid} role={}", role.name());
                self.vms.insert(
                    gen,
                    Vm {
                        pid,
                        conn: None,
                        ready: false,
                        alive: true,
                        released: false,
                        prepared: false,
                        warned: false,
                    },
                );
                Some(gen)
            }
            Err(e) => {
                log!("spawn vm gen={gen} failed: {e}");
                None
            }
        }
    }

    fn promote(&mut self, gen: u64) {
        self.primary = Some(gen);
        self.last_primary = Some(gen);
        self.last_primary_status = None;
        for f in std::mem::take(&mut self.staged) {
            self.apply(f);
        }
        log!("vm gen={gen} is primary");
    }

    /// Back to steady state: forward queued requests, boot a standby (ruling 8:
    /// only once the primary is primary).
    fn go_idle(&mut self) {
        self.plan = Plan::Idle;
        self.deadline = None;
        self.flush_requests();
        if self.standby.is_none() && self.primary.is_some() {
            self.standby = self.spawn_vm(Role::Standby);
        }
    }

    fn kill(&mut self, gen: u64) {
        if let Some(v) = self.vms.get(&gen) {
            self.spawner.signal(v.pid, libc::SIGKILL);
        }
    }

    fn terminate(&mut self, gen: u64, grace: Duration) {
        if let Some(v) = self.vms.get(&gen) {
            self.spawner.signal(v.pid, libc::SIGTERM);
            self.kills.push((Instant::now() + grace, gen));
        }
    }

    fn link_closed(&mut self, gen: u64) {
        let stopping = matches!(self.plan, Plan::Stopping);
        let primary = self.primary == Some(gen);
        let Some(v) = self.vms.get_mut(&gen) else {
            return;
        };
        v.conn = None;
        if !v.alive {
            return;
        }
        log!("vm gen={gen} link closed");
        if primary && !v.released && !stopping {
            // A quitting VM closes its link long before it exits: let the exit
            // status decide (reap), or exit_grace lapse into the crash path.
            self.exit_waits
                .push((Instant::now() + self.cfg.exit_grace, gen));
            return;
        }
        v.alive = false;
        let (pid, ready, quiet) = (v.pid, v.ready, v.released || stopping);
        if !quiet {
            // Make sure a VM that lost its link is really gone.
            self.spawner.signal(pid, libc::SIGKILL);
        }
        self.vm_died(gen, ready, "eof");
    }

    fn reap(&mut self) {
        for (pid, st) in self.spawner.reap() {
            let Some(gen) = self.vms.iter().find(|(_, v)| v.pid == pid).map(|(g, _)| *g) else {
                continue;
            };
            // Frames the VM wrote before dying are still queued (a HOLD right
            // before kill -9 must count): read them first.
            if let Some(t) = self.vm_conn(gen) {
                while let Some(c) = self.conns.get(&t) {
                    let mut p = [pollfd(c.sock.as_raw_fd())];
                    // SAFETY: one live pollfd; zero timeout (the data is already there).
                    if unsafe { libc::poll(p.as_mut_ptr(), 1, 0) } <= 0 {
                        break;
                    }
                    match fp::recv_frame(c.sock.as_fd()) {
                        Ok(Some(f)) => self.on_frame(t, f),
                        _ => break,
                    }
                }
            }
            if self.last_primary == Some(gen) {
                self.last_primary_status = Some(st);
            }
            self.exit_waits.retain(|&(_, g)| g != gen);
            let Some(v) = self.vms.remove(&gen) else {
                continue;
            };
            if let Some(t) = v.conn {
                self.conns.remove(&t);
            }
            if v.alive {
                let how = if st >= 0 {
                    st.to_string()
                } else {
                    format!("sig{}", -st)
                };
                self.vm_died(gen, v.ready, &how);
            }
        }
    }

    /// First death signal (link EOF or reap) of `gen`.
    fn vm_died(&mut self, gen: u64, ready: bool, how: &str) {
        let role = if self.primary == Some(gen) {
            "primary"
        } else if self.standby == Some(gen) {
            "standby"
        } else {
            "target"
        };
        log!("vm gen={gen} died status={how}");
        event!("broker_vm_exit", "gen" => gen, "status" => how, "role" => role);
        let lost: Vec<u64> = self
            .requests
            .iter()
            .filter(|(_, r)| r.sent_to == Some(gen))
            .map(|(r, _)| *r)
            .collect();
        for r in lost {
            self.on_reply(r, ERR_CLOSED);
        }
        if matches!(self.plan, Plan::Stopping) {
            return;
        }
        if self.primary == Some(gen) && how == "0" {
            // The primary quit on purpose (e.g. the local client detached).
            log!("vm gen={gen} exited cleanly");
            self.primary = None;
            self.begin_stop(0);
            return;
        }
        if self.primary == Some(gen) {
            self.primary = None;
            self.begin_crash(gen);
            return;
        }
        if self.standby == Some(gen) {
            self.standby = None;
            // A standby that never booted is not retried until the next handoff.
            if ready && matches!(self.plan, Plan::Idle) {
                self.go_idle();
            }
            return;
        }
        match self.plan.clone() {
            Plan::Fresh { gen: g, .. } if g == gen => self.begin_stop(1),
            Plan::Crash { to, .. } if to == gen => self.crash_fail("target died"),
            Plan::Graceful { to, .. } if to == gen => self.graceful_fail("target died"),
            Plan::Thawing { to, .. } if to == gen => self.thaw(),
            Plan::Releasing { old } if old == gen => self.go_idle(),
            _ => {}
        }
    }

    /// Ruling 14: never a handoff. Primary SIGTERM (SIGKILL after
    /// shutdown_grace), the rest SIGTERM (SIGKILL after stop_grace).
    fn begin_stop(&mut self, code: i32) {
        if matches!(self.plan, Plan::Stopping) {
            return;
        }
        log!("stopping");
        self.code = code;
        self.reply_restart(false, "failed: broker stopping");
        self.staged.clear();
        self.plan = Plan::Stopping;
        self.deadline = None;
        let gens: Vec<u64> = self.vms.keys().copied().collect();
        for gen in gens {
            let grace = if self.primary == Some(gen) {
                self.cfg.shutdown_grace
            } else {
                self.cfg.stop_grace
            };
            self.terminate(gen, grace);
        }
    }

    // ---- helpers ----

    fn plan_target(&self) -> Option<u64> {
        match self.plan {
            Plan::Fresh { gen, .. } => Some(gen),
            Plan::Crash { to, .. } | Plan::Graceful { to, .. } => Some(to),
            _ => None,
        }
    }

    fn vm_conn(&self, gen: u64) -> Option<u64> {
        self.vms.get(&gen).and_then(|v| v.conn)
    }

    fn send(&mut self, t: u64, k: u8, body: &[u8]) -> bool {
        let Some(c) = self.conns.get(&t) else {
            return false;
        };
        match fp::send_frame(c.sock.as_fd(), k, body, &[]) {
            Ok(()) => true,
            Err(e) => {
                log!("send {k:#x}: {e}");
                self.closing.push(t);
                false
            }
        }
    }

    fn phase(&self) -> &'static str {
        match &self.plan {
            Plan::Idle => "idle",
            Plan::Fresh { .. } => "booting",
            Plan::Crash { .. } => "adopting",
            Plan::Graceful { step, .. } => match step {
                Step::Booting => "booting",
                Step::Preparing => "preparing",
                Step::Adopting => "adopting",
            },
            Plan::Thawing { froze: true, .. } => "preparing",
            Plan::Thawing { .. } => "booting",
            Plan::Releasing { .. } => "releasing",
            Plan::Stopping => "stopping",
        }
    }

    fn status_text(&self) -> String {
        let dash = |v: Option<String>| v.unwrap_or_else(|| "-".into());
        let gen = |g: Option<u64>| dash(g.map(|g| g.to_string()));
        let pid =
            |g: Option<u64>| dash(g.and_then(|g| self.vms.get(&g)).map(|v| v.pid.to_string()));
        let ready = self
            .standby
            .and_then(|g| self.vms.get(&g))
            .is_some_and(|v| v.ready);
        format!(
            "broker_pid={}\nprimary_gen={}\nprimary_pid={}\nstandby_gen={}\nstandby_pid={}\n\
             standby_ready={}\nentries={}\nphase={}\nhandoffs={}\nlast_handoff_kind={}\n\
             last_handoff_ms={}\nvm_argv={}\n",
            std::process::id(),
            gen(self.primary),
            pid(self.primary),
            gen(self.standby),
            pid(self.standby),
            ready as u8,
            self.entries.len(),
            self.phase(),
            self.handoffs,
            self.last_kind.unwrap_or("-"),
            dash(self.last_ms.map(|m| m.to_string())),
            show_argv(&self.cfg.argv),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::sync::mpsc::{channel, Receiver, Sender};
    use std::sync::{Arc, Mutex};
    use std::thread::JoinHandle;

    const WAIT: Duration = Duration::from_secs(3);

    fn pid(gen: u64) -> u32 {
        10_000 + gen as u32
    }

    /// `(gen, argv)` of every spawn.
    type Argvs = Arc<Mutex<Vec<(u64, Vec<OsString>)>>>;

    struct Fake {
        sock: PathBuf,
        argvs: Argvs,
        vms: Sender<(u64, Role, UnixStream)>,
        sigs: Sender<(u32, i32)>,
        reaps: Arc<Mutex<Vec<(u32, i32)>>>,
    }

    impl Spawner for Fake {
        fn spawn(&mut self, gen: u64, role: Role, argv: &[OsString]) -> io::Result<u32> {
            self.argvs.lock().unwrap().push((gen, argv.to_vec()));
            let s = UnixStream::connect(&self.sock)?;
            fp::set_timeouts(s.as_fd(), WAIT)?;
            let _ = self.vms.send((gen, role, s));
            Ok(pid(gen))
        }
        fn signal(&mut self, pid: u32, sig: i32) {
            let _ = self.sigs.send((pid, sig));
        }
        fn reap(&mut self) -> Vec<(u32, i32)> {
            std::mem::take(&mut *self.reaps.lock().unwrap())
        }
    }

    struct H {
        sock: PathBuf,
        argvs: Argvs,
        vms: Receiver<(u64, Role, UnixStream)>,
        sigs: Receiver<(u32, i32)>,
        reaps: Arc<Mutex<Vec<(u32, i32)>>>,
        sig_w: UnixStream,
        thread: JoinHandle<io::Result<Outcome>>,
    }

    fn start(name: &str) -> H {
        let dir = std::env::temp_dir().join(format!("hb-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("b.sock");
        let mut cfg = Config::new(sock.clone(), vec!["old".into(), "start".into()]);
        let ms = Duration::from_millis;
        cfg.hello_timeout = ms(2000);
        cfg.prepared_timeout = ms(2000);
        cfg.restored_timeout = ms(300);
        cfg.release_timeout = ms(300);
        cfg.stop_grace = ms(300);
        cfg.shutdown_grace = ms(300);
        cfg.frame_timeout = WAIT;
        cfg.exit_grace = ms(300);
        let (vtx, vms) = channel();
        let (stx, sigs) = channel();
        let reaps = Arc::new(Mutex::new(Vec::new()));
        let argvs = Arc::new(Mutex::new(Vec::new()));
        let fake = Fake {
            sock: sock.clone(),
            argvs: argvs.clone(),
            vms: vtx,
            sigs: stx,
            reaps: reaps.clone(),
        };
        let (sig_r, sig_w) = UnixStream::pair().unwrap();
        let mut b = Broker::new(cfg, fake, sig_r).unwrap();
        let thread = std::thread::spawn(move || b.run());
        H {
            sock,
            argvs,
            vms,
            sigs,
            reaps,
            sig_w,
            thread,
        }
    }

    fn send(s: &UnixStream, k: u8, body: &[u8], fds: &[BorrowedFd<'_>]) {
        fp::send_frame(s.as_fd(), k, body, fds).unwrap();
    }

    fn recv(s: &UnixStream) -> Frame {
        fp::recv_frame(s.as_fd()).unwrap().unwrap()
    }

    fn expect(s: &UnixStream, k: u8) -> Frame {
        let f = recv(s);
        assert_eq!(f.kind, k, "got kind {:#x}", f.kind);
        f
    }

    fn keyed(key: &[u8], blob: &[u8]) -> Vec<u8> {
        let mut b = Vec::new();
        fp::put_key(&mut b, key);
        b.extend(blob);
        b
    }

    fn hello(s: &UnixStream, gen: u64) {
        let mut b = gen.to_be_bytes().to_vec();
        b.extend(pid(gen).to_be_bytes());
        send(s, kind::HELLO, &b, &[]);
    }

    fn assert_silent(s: &UnixStream) {
        fp::set_timeouts(s.as_fd(), Duration::from_millis(200)).unwrap();
        let e = fp::recv_frame(s.as_fd()).unwrap_err();
        assert!(matches!(
            e.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        ));
        fp::set_timeouts(s.as_fd(), WAIT).unwrap();
    }

    impl H {
        fn ctl(&self) -> UnixStream {
            let s = UnixStream::connect(&self.sock).unwrap();
            fp::set_timeouts(s.as_fd(), WAIT).unwrap();
            s
        }

        fn vm(&self) -> (u64, Role, UnixStream) {
            self.vms.recv_timeout(WAIT).unwrap()
        }

        fn status(&self) -> String {
            let s = self.ctl();
            send(&s, kind::CTL_STATUS, &[], &[]);
            String::from_utf8(expect(&s, kind::CTL_STATUS_REPLY).body).unwrap()
        }

        fn wait_status(&self, line: &str) -> String {
            let end = Instant::now() + WAIT;
            loop {
                let st = self.status();
                if st.lines().any(|l| l == line) {
                    return st;
                }
                assert!(Instant::now() < end, "no {line} in\n{st}");
                std::thread::sleep(Duration::from_millis(10));
            }
        }

        fn wait_signal(&self, pid: u32, sig: i32) {
            loop {
                let got = self.sigs.recv_timeout(WAIT).unwrap();
                if got == (pid, sig) {
                    return;
                }
            }
        }

        /// Primary gen 1 promoted, standby gen 2 ready.
        fn boot(&self) -> (UnixStream, UnixStream) {
            let (g, r, vm1) = self.vm();
            assert_eq!((g, r), (1, Role::Primary));
            hello(&vm1, 1);
            expect(&vm1, kind::FRESH);
            let (g, r, vm2) = self.vm();
            assert_eq!((g, r), (2, Role::Standby));
            hello(&vm2, 2);
            self.wait_status("standby_ready=1");
            (vm1, vm2)
        }
    }

    #[test]
    fn fresh_start_promotes_first_vm() {
        let h = start("fresh");
        let (g, r, vm1) = h.vm();
        assert_eq!((g, r), (1, Role::Primary));
        assert!(h.status().contains("phase=booting\n"));
        hello(&vm1, 1);
        assert_eq!(expect(&vm1, kind::FRESH).body, [0]);
        let st = h.wait_status("primary_gen=1");
        for k in [
            "broker_pid",
            "primary_gen",
            "primary_pid",
            "standby_gen",
            "standby_pid",
            "standby_ready",
            "entries",
            "phase",
            "handoffs",
            "last_handoff_kind",
            "last_handoff_ms",
        ] {
            assert!(st.contains(&format!("{k}=")), "{k} missing in {st}");
        }
        let (g, r, vm2) = h.vm();
        assert_eq!((g, r), (2, Role::Standby));
        hello(&vm2, 2);
        let st = h.wait_status("standby_ready=1");
        assert!(st.contains("standby_gen=2\n") && st.contains("phase=idle\n"));
        assert!(st.contains("last_handoff_kind=-\n"));
        assert_silent(&vm2);
    }

    #[test]
    fn crash_adopts_into_standby() {
        let h = start("crash");
        let (vm1, vm2) = h.boot();
        let (pr, pw) = UnixStream::pair().unwrap();
        send(&vm1, kind::HOLD, &keyed(b"pane/1", b"a"), &[pw.as_fd()]);
        drop(pw);
        send(&vm1, kind::UPDATE, &keyed(b"pane/1", b"b"), &[]);
        drop(vm1);
        let f = expect(&vm2, kind::ADOPT);
        let (k, blob) = fp::take_key(&f.body).unwrap();
        assert_eq!((k, blob, f.fds.len()), (&b"pane/1"[..], &b"b"[..], 1));
        let mut w = UnixStream::from(f.fds.into_iter().next().unwrap());
        w.write_all(b"x").unwrap();
        let mut byte = [0u8];
        (&pr).read_exact(&mut byte).unwrap();
        assert_eq!(&byte, b"x");
        let end = expect(&vm2, kind::ADOPT_END);
        assert_eq!(end.body, [0, 0, 0, 1, 1]);
        assert!(h.status().contains("phase=adopting\n"));
        h.wait_signal(pid(1), libc::SIGKILL);
        send(&vm2, kind::RESTORED, &1u32.to_be_bytes(), &[]);
        let st = h.wait_status("primary_gen=2");
        assert!(st.contains("last_handoff_kind=crash\n") && st.contains("handoffs=1\n"));
        assert!(st.contains("entries=1\n"));
        let (g, r, _vm3) = h.vm();
        assert_eq!((g, r), (3, Role::Standby));
    }

    /// Primary 1 holding `pane/1`, standby 2 ready, restart requested: returns
    /// (vm1, target vm3, ctl) with vm1 already PREPAREd.
    fn to_preparing(h: &H) -> (UnixStream, UnixStream, UnixStream) {
        to_preparing_with(h, &[])
    }

    /// `to_preparing` with a CTL_RESTART body (the target's own VM argv).
    fn to_preparing_with(h: &H, body: &[u8]) -> (UnixStream, UnixStream, UnixStream) {
        let (vm1, _vm2) = h.boot();
        let (_pr, pw) = UnixStream::pair().unwrap();
        send(&vm1, kind::HOLD, &keyed(b"pane/1", b"a"), &[pw.as_fd()]);
        h.wait_status("entries=1");
        let c = h.ctl();
        send(&c, kind::CTL_RESTART, body, &[]);
        h.wait_signal(pid(2), libc::SIGTERM);
        let (g, r, vm3) = h.vm();
        assert_eq!((g, r), (3, Role::Target));
        assert!(h.status().contains("phase=booting\n"));
        hello(&vm3, 3);
        expect(&vm1, kind::PREPARE);
        (vm1, vm3, c)
    }

    #[test]
    fn graceful_restart_sequence() {
        let h = start("graceful");
        let (vm1, vm3, c) = to_preparing(&h);
        assert!(h.status().contains("phase=preparing\n"));
        send(&vm1, kind::UPDATE, &keyed(b"pane/1", b"final"), &[]);
        send(&vm1, kind::PREPARED, &[], &[]);
        let f = expect(&vm3, kind::ADOPT);
        assert_eq!(fp::take_key(&f.body).unwrap().1, b"final");
        assert_eq!(f.fds.len(), 1);
        assert_eq!(expect(&vm3, kind::ADOPT_END).body, [0, 0, 0, 1, 0]);
        send(&vm3, kind::RESTORED, &1u32.to_be_bytes(), &[]);
        expect(&vm1, kind::RELEASE);
        let r = expect(&c, kind::CTL_RESULT);
        assert_eq!(r.body[0], 1, "{}", String::from_utf8_lossy(&r.body));
        let st = h.wait_status("primary_gen=3");
        assert!(st.contains("last_handoff_kind=graceful\n"));
        assert!(st.contains("phase=releasing\n"));
        drop(vm1);
        h.wait_status("phase=idle");
        let (g, r, _vm4) = h.vm();
        assert_eq!((g, r), (4, Role::Standby));
    }

    fn argv_of(h: &H, gen: u64) -> Vec<OsString> {
        let argvs = h.argvs.lock().unwrap();
        argvs.iter().find(|(g, _)| *g == gen).unwrap().1.clone()
    }

    fn new_argv() -> Vec<OsString> {
        vec!["/r/0.1.1/bin/dynide_vm".into(), "start".into()]
    }

    #[test]
    fn restart_argv_round_trips() {
        let a = new_argv();
        assert_eq!(decode_argv(&encode_argv(&a)), Some(a));
        assert_eq!(decode_argv(&[]), None);
        assert_eq!(decode_argv(b"\0"), None);
        assert_eq!(decode_argv(b"no-terminator"), None);
    }

    #[test]
    fn graceful_restart_with_argv_adopts_it() {
        let h = start("gargv");
        let (vm1, vm3, c) = to_preparing_with(&h, &encode_argv(&new_argv()));
        assert_eq!(argv_of(&h, 3), new_argv());
        send(&vm1, kind::PREPARED, &[], &[]);
        expect(&vm3, kind::ADOPT);
        expect(&vm3, kind::ADOPT_END);
        send(&vm3, kind::RESTORED, &1u32.to_be_bytes(), &[]);
        expect(&vm1, kind::RELEASE);
        assert_eq!(expect(&c, kind::CTL_RESULT).body[0], 1);
        drop(vm1);
        h.wait_status("phase=idle");
        let (g, r, _vm4) = h.vm();
        assert_eq!((g, r), (4, Role::Standby));
        assert_eq!(argv_of(&h, 4), new_argv());
        h.wait_status("vm_argv=/r/0.1.1/bin/dynide_vm start");
    }

    #[test]
    fn failed_restart_with_argv_keeps_the_old_argv() {
        let h = start("gargvfail");
        let (vm1, vm3, c) = to_preparing_with(&h, &encode_argv(&new_argv()));
        send(&vm1, kind::PREPARED, &[], &[]);
        expect(&vm3, kind::ADOPT);
        expect(&vm3, kind::ADOPT_END);
        h.wait_signal(pid(3), libc::SIGKILL);
        drop(vm3);
        expect(&vm1, kind::THAW);
        assert_eq!(expect(&c, kind::CTL_RESULT).body[0], 0);
        let (g, r, _vm4) = h.vm();
        assert_eq!((g, r), (4, Role::Standby));
        assert_eq!(argv_of(&h, 4), vec![OsString::from("old"), "start".into()]);
        h.wait_status("vm_argv=old start");
    }

    #[test]
    fn graceful_failure_thaws_old() {
        let h = start("gfail");
        let (vm1, vm3, c) = to_preparing(&h);
        send(&vm1, kind::PREPARED, &[], &[]);
        expect(&vm3, kind::ADOPT);
        expect(&vm3, kind::ADOPT_END);
        h.wait_signal(pid(3), libc::SIGKILL);
        drop(vm3);
        expect(&vm1, kind::THAW);
        let r = expect(&c, kind::CTL_RESULT);
        assert_eq!(r.body[0], 0);
        let st = h.wait_status("phase=idle");
        assert!(st.contains("primary_gen=1\n") && st.contains("handoffs=0\n"));
    }

    #[test]
    fn requests_queue_during_handoff() {
        let h = start("requests");
        let (vm1, vm3, _c) = to_preparing(&h);
        let b = h.ctl();
        for p in [b"p1", b"p2", b"p3"] {
            send(&b, kind::CTL_REQUEST, p, &[]);
        }
        std::thread::sleep(Duration::from_millis(100));
        send(&vm1, kind::PREPARED, &[], &[]);
        expect(&vm3, kind::ADOPT);
        expect(&vm3, kind::ADOPT_END);
        send(&vm3, kind::RESTORED, &1u32.to_be_bytes(), &[]);
        expect(&vm1, kind::RELEASE);
        let mut refs = Vec::new();
        for p in [b"p1", b"p2", b"p3"] {
            let f = expect(&vm3, kind::REQUEST);
            assert_eq!(&f.body[8..], p);
            refs.push(f.body[..8].to_vec());
        }
        for (r, p) in refs.iter().zip([b"R1", b"R2", b"R3"]).rev() {
            let mut body = r.clone();
            body.extend(p);
            send(&vm3, kind::REPLY, &body, &[]);
        }
        for p in [b"R1", b"R2", b"R3"] {
            assert_eq!(expect(&b, kind::CTL_REPLY).body, p);
        }
    }

    #[test]
    fn drop_closes_fd() {
        let h = start("drop");
        let (vm1, _vm2) = h.boot();
        let (pr, pw) = UnixStream::pair().unwrap();
        send(&vm1, kind::HOLD, &keyed(b"pane/7", b""), &[pw.as_fd()]);
        drop(pw);
        h.wait_status("entries=1");
        send(&vm1, kind::DROP, &keyed(b"pane/7", b""), &[]);
        pr.set_read_timeout(Some(WAIT)).unwrap();
        let mut buf = [0u8; 1];
        assert_eq!((&pr).read(&mut buf).unwrap(), 0);
        h.wait_status("entries=0");
    }

    #[test]
    fn primary_exit_zero_stops_without_handoff() {
        let h = start("exit0");
        let (vm1, vm2) = h.boot();
        drop(vm1);
        h.reaps.lock().unwrap().push((pid(1), 0));
        (&h.sig_w).write_all(b"C").unwrap();
        let mut got = Vec::new();
        while got.last() != Some(&(pid(2), libc::SIGTERM)) {
            got.push(h.sigs.recv_timeout(WAIT).unwrap());
        }
        assert!(!got.contains(&(pid(1), libc::SIGKILL)), "{got:?}");
        assert!(h.status().contains("phase=stopping\n"));
        assert_silent(&vm2);
        h.reaps.lock().unwrap().push((pid(2), 0));
        (&h.sig_w).write_all(b"C").unwrap();
        let o = h.thread.join().unwrap().unwrap();
        assert_eq!((o.code, o.crashed), (0, false));
        assert!(!h.sock.exists());
    }

    #[test]
    fn primary_exit_nonzero_crashes() {
        let h = start("exit1");
        let (vm1, vm2) = h.boot();
        drop(vm1);
        h.reaps.lock().unwrap().push((pid(1), 1));
        (&h.sig_w).write_all(b"C").unwrap();
        let end = expect(&vm2, kind::ADOPT_END);
        assert_eq!(end.body, [0, 0, 0, 0, 1]);
        send(&vm2, kind::RESTORED, &0u32.to_be_bytes(), &[]);
        let st = h.wait_status("primary_gen=2");
        assert!(st.contains("last_handoff_kind=crash\n"));
    }

    #[test]
    fn fallback_after_three_failed_adoptions_sends_fresh_restore() {
        let h = start("fallback");
        let (vm1, vm2) = h.boot();
        drop(vm1);
        h.reaps.lock().unwrap().push((pid(1), 1));
        (&h.sig_w).write_all(b"C").unwrap();
        // attempt 1 reuses the standby, attempts 2 and 3 spawn targets; none RESTOREs
        expect(&vm2, kind::ADOPT_END);
        h.wait_signal(pid(2), libc::SIGKILL);
        let mut held = vec![vm2];
        for gen in [3, 4] {
            let (g, r, vm) = h.vm();
            assert_eq!((g, r), (gen, Role::Target));
            hello(&vm, gen);
            expect(&vm, kind::ADOPT_END);
            h.wait_signal(pid(gen), libc::SIGKILL);
            held.push(vm);
        }
        let (g, r, vm5) = h.vm();
        assert_eq!((g, r), (5, Role::Primary));
        hello(&vm5, 5);
        assert_eq!(expect(&vm5, kind::FRESH).body, [1]);
        h.wait_status("primary_gen=5");
    }

    /// Kinds received on `s` until EOF or 300 ms of silence.
    fn drain_kinds(s: &UnixStream) -> Vec<u8> {
        // EINVAL on macOS once the broker shut the socket: recv then sees EOF anyway
        let _ = fp::set_timeouts(s.as_fd(), Duration::from_millis(300));
        let mut kinds = Vec::new();
        while let Ok(Some(f)) = fp::recv_frame(s.as_fd()) {
            kinds.push(f.kind);
        }
        kinds
    }

    /// Signals until `want` are all seen (any order).
    fn wait_signals(h: &H, want: &[(u32, i32)]) {
        let mut left = want.to_vec();
        while !left.is_empty() {
            let got = h.sigs.recv_timeout(WAIT).unwrap();
            left.retain(|w| *w != got);
        }
    }

    /// Reaps `pids` (status 0) and expects a clean broker exit with the socket gone.
    fn finish(h: H, pids: &[u32]) {
        h.reaps.lock().unwrap().extend(pids.iter().map(|&p| (p, 0)));
        (&h.sig_w).write_all(b"C").unwrap();
        let o = h.thread.join().unwrap().unwrap();
        assert_eq!(o.code, 0);
        assert!(!h.sock.exists());
    }

    #[test]
    fn exit_grace_lapse_crashes() {
        let h = start("grace");
        let (vm1, vm2) = h.boot();
        let t0 = Instant::now();
        // link EOF and no exit status: wait out exit_grace, then SIGKILL + crash path
        drop(vm1);
        let end = expect(&vm2, kind::ADOPT_END);
        assert!(
            t0.elapsed() >= Duration::from_millis(300),
            "{:?}",
            t0.elapsed()
        );
        assert_eq!(end.body, [0, 0, 0, 0, 1]);
        assert_eq!(h.sigs.try_recv(), Ok((pid(1), libc::SIGKILL)));
        send(&vm2, kind::RESTORED, &0u32.to_be_bytes(), &[]);
        h.wait_status("primary_gen=2");
    }

    #[test]
    fn sigterm_while_standby_boots() {
        let h = start("termboot");
        let (_, _, vm1) = h.vm();
        hello(&vm1, 1);
        expect(&vm1, kind::FRESH);
        let (g, r, vm2) = h.vm();
        assert_eq!((g, r), (2, Role::Standby));
        (&h.sig_w).write_all(b"T").unwrap();
        wait_signals(&h, &[(pid(1), libc::SIGTERM), (pid(2), libc::SIGTERM)]);
        // a late HELLO from the booting standby gets nothing
        hello(&vm2, 2);
        assert!(drain_kinds(&vm2).is_empty());
        assert!(drain_kinds(&vm1).is_empty());
        finish(h, &[pid(1), pid(2)]);
    }

    #[test]
    fn sigterm_mid_graceful_adopts_nothing() {
        let h = start("termgraceful");
        let (vm1, vm3, c) = to_preparing(&h);
        (&h.sig_w).write_all(b"T").unwrap();
        wait_signals(&h, &[(pid(1), libc::SIGTERM), (pid(3), libc::SIGTERM)]);
        let r = expect(&c, kind::CTL_RESULT);
        assert_eq!(r.body[0], 0);
        // the old VM finishing its freeze must not start an adoption
        send(&vm1, kind::PREPARED, &[], &[]);
        assert!(!drain_kinds(&vm3).contains(&kind::ADOPT));
        assert!(h.status().contains("phase=stopping\n"));
        finish(h, &[pid(1), pid(2), pid(3)]);
    }

    #[test]
    fn sigterm_while_crash_target_boots() {
        let h = start("termcrash");
        let (_, _, vm1) = h.vm();
        hello(&vm1, 1);
        expect(&vm1, kind::FRESH);
        let (_, _, vm2) = h.vm();
        // the primary dies before the standby is ready: the crash plan waits for its HELLO
        drop(vm1);
        h.reaps.lock().unwrap().push((pid(1), 1));
        (&h.sig_w).write_all(b"C").unwrap();
        h.wait_status("phase=adopting");
        (&h.sig_w).write_all(b"T").unwrap();
        wait_signals(&h, &[(pid(2), libc::SIGTERM)]);
        hello(&vm2, 2);
        let kinds = drain_kinds(&vm2);
        assert!(!kinds.contains(&kind::ADOPT) && !kinds.contains(&kind::ADOPT_END));
        finish(h, &[pid(2)]);
    }

    #[test]
    fn frames_after_prepared_are_ignored() {
        let h = start("prepared");
        let (vm1, vm3, _c) = to_preparing(&h);
        send(&vm1, kind::PREPARED, &[], &[]);
        expect(&vm3, kind::ADOPT);
        expect(&vm3, kind::ADOPT_END);
        let (_pr, pw) = UnixStream::pair().unwrap();
        send(&vm1, kind::HOLD, &keyed(b"pane/9", b"late"), &[pw.as_fd()]);
        std::thread::sleep(Duration::from_millis(100));
        send(&vm3, kind::RESTORED, &1u32.to_be_bytes(), &[]);
        let st = h.wait_status("primary_gen=3");
        assert!(st.contains("entries=1\n"), "{st}");
    }

    #[test]
    fn hello_with_wrong_pid_is_killed() {
        let h = start("badpid");
        let (_, _, vm1) = h.vm();
        hello(&vm1, 1);
        expect(&vm1, kind::FRESH);
        let (_, _, vm2) = h.vm();
        let mut b = 2u64.to_be_bytes().to_vec();
        b.extend((pid(2) + 1).to_be_bytes());
        send(&vm2, kind::HELLO, &b, &[]);
        h.wait_signal(pid(2), libc::SIGKILL);
        let st = h.wait_status("standby_gen=-");
        assert!(st.contains("standby_ready=0\n"));
        assert!(drain_kinds(&vm2).is_empty());
    }

    #[test]
    fn clean_stop() {
        let h = start("stop");
        let (_vm1, _vm2) = h.boot();
        (&h.sig_w).write_all(b"T").unwrap();
        let mut got = vec![h.sigs.recv_timeout(WAIT).unwrap()];
        got.push(h.sigs.recv_timeout(WAIT).unwrap());
        got.sort();
        assert_eq!(got, [(pid(1), libc::SIGTERM), (pid(2), libc::SIGTERM)]);
        assert!(h.status().contains("phase=stopping\n"));
        h.reaps.lock().unwrap().extend([(pid(1), 0), (pid(2), 0)]);
        (&h.sig_w).write_all(b"C").unwrap();
        let o = h.thread.join().unwrap().unwrap();
        assert_eq!((o.code, o.crashed), (0, false));
        assert!(!h.sock.exists());
    }
}
