//! BEAM boundary: `HerdrServer.Native` NIFs over `Vt` and `Pty`. Facades live in
//! `HerdrServer.Native.Vt` and `HerdrServer.Native.Pty`; term shapes are in
//! `docs/herdr-live/results/m1.md` ("Events").

use std::cell::Cell;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, IntoRawFd, OwnedFd};
use std::path::Path;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use rustler::sys::ErlNifEnv;
use rustler::thread::is_scheduler_thread;
use rustler::{
    Atom, Binary, Encoder, Env, Error, LocalPid, Monitor, NewBinary, NifMap, NifResult, OwnedEnv,
    Resource, ResourceArc, Term,
};

use crate::input::{Key, KeyAction, KeyInput, Mods, MouseButton, MouseInput, MouseKind, NamedKey};
use crate::link::{Frame, Link, LinkSink, SEND_TIMEOUT};
use crate::pty::{
    AdoptOptions, Event, EventSink, ExitStatus, Pty, SpawnOptions, ThawError, WriteError,
};
use crate::vt::{lock, Colors, LinkKind, Mode, RowBatch, Tail, TextRange, Vt};
use ghostty_vt::{ColorScheme, RgbColor};

mod atoms {
    rustler::atoms! {
        ok, error, nil, stale, damage, exit, osc, dcs, bell, title, pwd, signal, panic, unknown,
        truncated, backpressure, closed, too_large, enoent, eacces, enotdir, enoexec, e2big,
        os, spawn, hyperlink, text, viewport, screen, rows,
        block, bar, underline, block_hollow, hup, term, kill, int,
        key, mods, event, kind, button, x, y, px, disabled, consumed, not_frozen, released,
        os_pid, adopted, hidden, exited, start_time, alt_screen,
        herdr_link, herdr_link_closed, eof, timeout, noproc, econnrefused, einval,
        connect_failed, fg, bg, cursor, palette, dark, light,
    }
}

pub struct VtRes(Arc<Vt>);

#[rustler::resource_impl]
impl Resource for VtRes {}

pub struct PtyRes {
    pty: Arc<Pty>,
    sink: Arc<BeamSink>,
}

#[rustler::resource_impl]
impl Resource for PtyRes {
    const IMPLEMENTS_DOWN: bool = true;

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, mon: Monitor) {
        lock(&self.sink.subs).retain(|(_, m)| *m != mon);
    }
}

/// An fd held by the BEAM (`HerdrServer.Native.Fd`): a pane master from `pty_dup_fd`, or
/// one received from the broker. Consumed (taken) by the NIF that uses it.
pub struct FdRes(pub Mutex<Option<OwnedFd>>);

#[rustler::resource_impl]
impl Resource for FdRes {}

/// Keeps a row's `Arc<[u8]>` alive for as long as the BEAM references its binary.
pub struct RowBytes(Arc<[u8]>);

#[rustler::resource_impl]
impl Resource for RowBytes {}

thread_local! {
    /// The calling process's env while a NIF that may emit events runs on a scheduler
    /// thread; `enif_send` from a managed thread needs it.
    static CALLER: Cell<*mut ErlNifEnv> = const { Cell::new(ptr::null_mut()) };
}

struct CallerGuard(*mut ErlNifEnv);

impl Drop for CallerGuard {
    fn drop(&mut self) {
        CALLER.with(|c| c.set(self.0));
    }
}

fn with_caller<R>(env: Env, f: impl FnOnce() -> R) -> R {
    let _guard = CallerGuard(CALLER.with(|c| c.replace(env.as_c_arg())));
    f()
}

/// Sends `msg(env)` to each pid, from either a kernel thread or a NIF under `with_caller`.
fn deliver(pids: &[LocalPid], msg: impl for<'a> Fn(Env<'a>) -> Term<'a>) {
    if pids.is_empty() {
        return;
    }
    if is_scheduler_thread() {
        let raw = CALLER.with(Cell::get);
        // A scheduler thread (normal or dirty) can only send through the calling NIF's env;
        // events emitted outside `with_caller` are dropped. Wrap any emitting NIF in it.
        debug_assert!(
            !raw.is_null(),
            "event sent from a scheduler outside with_caller"
        );
        if raw.is_null() {
            return;
        }
        let marker = ();
        // SAFETY: `raw` is the live env of the NIF call currently running on this thread
        // (set by `with_caller`, cleared when it returns); this Env does not outlive it.
        let env = unsafe { Env::new(&marker, raw) };
        for p in pids {
            let _ = env.send(p, msg(env));
        }
    } else {
        let mut owned = OwnedEnv::new();
        for p in pids {
            let _ = owned.send_and_clear(p, &msg);
        }
    }
}

pub struct BeamSink {
    id: u64,
    subs: Mutex<Vec<(LocalPid, Monitor)>>,
    exit: Mutex<Option<ExitStatus>>,
}

impl EventSink for BeamSink {
    fn send(&self, ev: Event) {
        // Held across the send so `subscribe` sees either the exit or the broadcast, never
        // both and never neither.
        let subs = lock(&self.subs);
        if let Event::Exit(s) = &ev {
            *lock(&self.exit) = Some(s.clone());
        }
        let pids: Vec<LocalPid> = subs.iter().map(|(p, _)| *p).collect();
        deliver(&pids, |env| encode_event(env, self.id, &ev));
    }
}

fn bin<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut b = NewBinary::new(env, bytes.len());
    b.as_mut_slice().copy_from_slice(bytes);
    Binary::from(b).to_term(env)
}

fn payload<'a>(env: Env<'a>, bytes: &[u8], cut: bool) -> Term<'a> {
    match cut {
        false => bin(env, bytes),
        true => (atoms::truncated(), bin(env, bytes)).encode(env),
    }
}

fn encode_status<'a>(env: Env<'a>, s: &ExitStatus) -> Term<'a> {
    match s {
        ExitStatus::Code(c) => c.encode(env),
        ExitStatus::Signal(n) => (atoms::signal(), *n).encode(env),
        ExitStatus::Panic(m) => (atoms::panic(), m.as_str()).encode(env),
        ExitStatus::Unknown => atoms::unknown().encode(env),
    }
}

fn encode_event<'a>(env: Env<'a>, id: u64, ev: &Event) -> Term<'a> {
    match ev {
        Event::Damage(g) => (atoms::damage(), id, *g).encode(env),
        Event::Exit(s) => (atoms::exit(), id, encode_status(env, s)).encode(env),
        Event::Osc {
            code,
            payload: p,
            truncated,
        } => (atoms::osc(), id, *code, payload(env, p, *truncated)).encode(env),
        Event::Dcs {
            payload: p,
            truncated,
        } => (atoms::dcs(), id, payload(env, p, *truncated)).encode(env),
        Event::Bell => (atoms::bell(), id).encode(env),
        Event::Title(t) => (atoms::title(), id, bin(env, t)).encode(env),
        Event::Pwd(p) => (atoms::pwd(), id, bin(env, p)).encode(env),
    }
}

fn raise(msg: impl std::fmt::Display) -> Error {
    Error::RaiseTerm(Box::new(msg.to_string()))
}

/// `{gen, [{n, row}]}` with each row a zero-copy resource binary over the snapshot's Arc.
fn encode_batch<'a>(env: Env<'a>, (gen, rows): RowBatch) -> Term<'a> {
    let rows: Vec<(u16, Binary<'a>)> = rows
        .into_iter()
        .map(|(y, bytes)| {
            (
                y,
                ResourceArc::new(RowBytes(bytes)).make_binary(env, |r| &r.0),
            )
        })
        .collect();
    (gen, rows).encode(env)
}

fn name(t: Term) -> NifResult<String> {
    t.atom_to_string()
}

fn num(t: Term) -> NifResult<f32> {
    t.decode::<f64>()
        .or_else(|_| t.decode::<i64>().map(|i| i as f64))
        .map(|f| f as f32)
}

fn decode_mods(t: Term) -> NifResult<Mods> {
    let mut m = Mods::default();
    for a in t.decode::<Vec<Term>>()? {
        match name(a)?.as_str() {
            "shift" => m.shift = true,
            "ctrl" => m.ctrl = true,
            "alt" => m.alt = true,
            "super" => m.super_ = true,
            _ => return Err(Error::BadArg),
        }
    }
    Ok(m)
}

fn decode_key(t: Term) -> NifResult<KeyInput> {
    let k = t.map_get(atoms::key())?;
    let key = match k.is_binary() {
        true => Key::Char(k.decode()?),
        false => Key::Named(NamedKey::from_name(&name(k)?).ok_or(Error::BadArg)?),
    };
    let event = match name(t.map_get(atoms::event())?)?.as_str() {
        "press" => KeyAction::Press,
        "release" => KeyAction::Release,
        "repeat" => KeyAction::Repeat,
        _ => return Err(Error::BadArg),
    };
    Ok(KeyInput {
        key,
        mods: decode_mods(t.map_get(atoms::mods())?)?,
        event,
        text: t.map_get(atoms::text())?.decode()?,
    })
}

fn decode_mouse(t: Term) -> NifResult<MouseInput> {
    let kind = match name(t.map_get(atoms::kind())?)?.as_str() {
        "press" => MouseKind::Press,
        "release" => MouseKind::Release,
        "move" => MouseKind::Move,
        "drag" => MouseKind::Drag,
        "scroll" => MouseKind::Scroll,
        _ => return Err(Error::BadArg),
    };
    let b = t.map_get(atoms::button())?;
    let button = match name(b)?.as_str() {
        "nil" => None,
        "left" => Some(MouseButton::Left),
        "middle" => Some(MouseButton::Middle),
        "right" => Some(MouseButton::Right),
        "wheel_up" => Some(MouseButton::WheelUp),
        "wheel_down" => Some(MouseButton::WheelDown),
        "wheel_left" => Some(MouseButton::WheelLeft),
        "wheel_right" => Some(MouseButton::WheelRight),
        _ => return Err(Error::BadArg),
    };
    let p = t.map_get(atoms::px())?;
    let px = match p.decode::<Atom>() {
        Ok(a) if a == atoms::nil() => None,
        _ => {
            let (a, b) = p.decode::<(Term, Term)>()?;
            Some((num(a)?, num(b)?))
        }
    };
    Ok(MouseInput {
        kind,
        button,
        x: t.map_get(atoms::x())?.decode()?,
        y: t.map_get(atoms::y())?.decode()?,
        mods: decode_mods(t.map_get(atoms::mods())?)?,
        px,
    })
}

// ---- Vt ----

#[rustler::nif]
fn vt_new(cols: u16, rows: u16, max_scrollback: usize) -> NifResult<(Atom, ResourceArc<VtRes>)> {
    let vt = Vt::new(cols, rows, max_scrollback).map_err(|e| raise(format!("{e:?}")))?;
    Ok((atoms::ok(), ResourceArc::new(VtRes(vt))))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vt_encode_snapshot(env: Env, vt: ResourceArc<VtRes>) -> NifResult<Term> {
    let bytes =
        vt.0.encode_snapshot()
            .map_err(|e| raise(format!("{e:?}")))?;
    Ok(bin(env, &bytes))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vt_restore<'a>(env: Env<'a>, bytes: Binary, max_scrollback: usize) -> Term<'a> {
    match Vt::restore(bytes.as_slice(), max_scrollback) {
        Ok(vt) => (atoms::ok(), ResourceArc::new(VtRes(vt))).encode(env),
        Err(e) => (atoms::error(), format!("{e:?}")).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vt_feed(vt: ResourceArc<VtRes>, bytes: Binary) -> u64 {
    vt.0.write(bytes.as_slice());
    vt.0.refresh()
}

// ponytail: takes the blocking core lock and rebuilds the snapshot, so DirtyCpu; upgrade path is applying it on the reader thread between chunks.
#[rustler::nif(schedule = "DirtyCpu")]
fn vt_resize(
    vt: ResourceArc<VtRes>,
    cols: u16,
    rows: u16,
    px: Option<(u32, u32)>,
) -> NifResult<Atom> {
    vt.0.resize(cols, rows, px)
        .map_err(|e| raise(format!("{e:?}")))?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn vt_dirty_rows(env: Env, vt: ResourceArc<VtRes>) -> Term {
    encode_batch(env, vt.0.dirty_rows())
}

/// Scalar: the published snapshot's gen (no core lock, no row copies).
#[rustler::nif]
fn vt_gen(vt: ResourceArc<VtRes>) -> u64 {
    vt.0.gen()
}

#[rustler::nif]
fn vt_rows_since(env: Env, vt: ResourceArc<VtRes>, gen: u64) -> Term {
    encode_batch(env, vt.0.rows_since(gen))
}

#[rustler::nif]
fn vt_full_rows(env: Env, vt: ResourceArc<VtRes>) -> Term {
    encode_batch(env, vt.0.full_rows())
}

/// The primary screen's last `n` rows as VT, or `:alt_screen`.
#[rustler::nif(schedule = "DirtyCpu")]
fn vt_tail_ansi(env: Env, vt: ResourceArc<VtRes>, n: usize) -> NifResult<Term> {
    match vt.0.tail_ansi(n).map_err(|e| raise(format!("{e:?}")))? {
        Tail::Ansi(s) => Ok(bin(env, s.as_bytes())),
        Tail::AltScreen => Ok(atoms::alt_screen().encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vt_read_text(vt: ResourceArc<VtRes>, range: Atom, first: u32, last: u32) -> NifResult<String> {
    let r = match range {
        a if a == atoms::viewport() => TextRange::Viewport,
        a if a == atoms::screen() => TextRange::Screen,
        a if a == atoms::rows() => TextRange::Rows(first, last),
        _ => return Err(Error::BadArg),
    };
    vt.0.read_text(r).map_err(|e| raise(format!("{e:?}")))
}

/// `{x1, y1, x2, y2}` screen points; see `Vt::read_selection`.
#[rustler::nif(schedule = "DirtyCpu")]
fn vt_read_selection(
    vt: ResourceArc<VtRes>,
    x1: u16,
    y1: u32,
    x2: u16,
    y2: u32,
) -> NifResult<String> {
    vt.0.read_selection((x1, y1), (x2, y2))
        .map_err(|e| raise(format!("{e:?}")))
}

/// `[{row, packed_row, wrapped}]`; see `Vt::screen_rows`.
#[rustler::nif(schedule = "DirtyCpu")]
fn vt_screen_rows(env: Env, vt: ResourceArc<VtRes>, first: u32, last: u32) -> NifResult<Term> {
    let rows =
        vt.0.screen_rows(first, last)
            .map_err(|e| raise(format!("{e:?}")))?;
    let rows: Vec<Term> = rows
        .iter()
        .map(|(y, packed, wrapped)| (*y, bin(env, packed), *wrapped).encode(env))
        .collect();
    Ok(rows.encode(env))
}

fn rgb(t: Term) -> NifResult<Option<RgbColor>> {
    if t.is_atom() && t.decode::<Atom>()? == atoms::nil() {
        return Ok(None);
    }
    Ok(Some(decode_rgb(t.decode()?)?))
}

/// Range-checked: rustler's integer decoders truncate rather than reject.
fn decode_rgb((r, g, b): (u32, u32, u32)) -> NifResult<RgbColor> {
    let c = |v: u32| u8::try_from(v).map_err(|_| Error::BadArg);
    Ok(RgbColor {
        r: c(r)?,
        g: c(g)?,
        b: c(b)?,
    })
}

fn color_field<'a>(m: Term<'a>, key: Atom) -> NifResult<Option<RgbColor>> {
    m.map_get(key).ok().map_or(Ok(None), rgb)
}

fn decode_colors(m: Term) -> NifResult<Colors> {
    let palette = match m.map_get(atoms::palette()) {
        Err(_) => Vec::new(),
        Ok(p) => {
            let entries: std::collections::HashMap<u32, (u32, u32, u32)> = p.decode()?;
            let mut v = entries
                .into_iter()
                .map(|(i, c)| Ok((u8::try_from(i).map_err(|_| Error::BadArg)?, decode_rgb(c)?)))
                .collect::<NifResult<Vec<(u8, RgbColor)>>>()?;
            v.sort_by_key(|(i, _)| *i);
            v
        }
    };
    Ok(Colors {
        fg: color_field(m, atoms::fg())?,
        bg: color_field(m, atoms::bg())?,
        cursor: color_field(m, atoms::cursor())?,
        palette,
    })
}

/// Sets ghostty's default colours (options only, no snapshot rebuild).
#[rustler::nif]
fn vt_set_colors(vt: ResourceArc<VtRes>, colors: Term) -> NifResult<Atom> {
    if !colors.is_map() {
        return Err(Error::BadArg);
    }
    vt.0.set_colors(&decode_colors(colors)?)
        .map_err(|e| raise(format!("{e:?}")))?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn vt_set_color_scheme(vt: ResourceArc<VtRes>, scheme: Atom) -> NifResult<Atom> {
    let s = match scheme {
        a if a == atoms::dark() => Some(ColorScheme::Dark),
        a if a == atoms::light() => Some(ColorScheme::Light),
        a if a == atoms::nil() => None,
        _ => return Err(Error::BadArg),
    };
    vt.0.set_color_scheme(s);
    Ok(atoms::ok())
}

#[derive(NifMap)]
struct ScrollbarMap {
    total: usize,
    viewport: usize,
    offset: usize,
}

#[rustler::nif]
fn vt_scrollbar(vt: ResourceArc<VtRes>) -> ScrollbarMap {
    let s = vt.0.scrollbar();
    ScrollbarMap {
        total: s.total,
        viewport: s.viewport,
        offset: s.offset,
    }
}

/// `{cols, rows}` of the last snapshot (no core lock).
#[rustler::nif]
fn vt_size(vt: ResourceArc<VtRes>) -> (u16, usize) {
    let s = vt.0.snapshot();
    (s.cols, s.rows.len())
}

// ponytail: takes the blocking core lock and rebuilds the snapshot, so DirtyCpu; upgrade path is applying it on the reader thread between chunks.
#[rustler::nif(schedule = "DirtyCpu")]
fn vt_scroll_to(vt: ResourceArc<VtRes>, offset: usize) -> NifResult<Atom> {
    vt.0.scroll_to(offset)
        .map_err(|e| raise(format!("{e:?}")))?;
    Ok(atoms::ok())
}

fn maybe_stale<'a>(env: Env<'a>, v: impl Encoder, stale: bool) -> Term<'a> {
    match stale {
        false => v.encode(env),
        true => (atoms::stale(), v).encode(env),
    }
}

#[rustler::nif]
fn vt_mode<'a>(env: Env<'a>, vt: ResourceArc<VtRes>, mode: Term<'a>) -> NifResult<Term<'a>> {
    let m = Mode::from_name(&name(mode)?).ok_or(Error::BadArg)?;
    let (v, stale) = vt.0.mode(m);
    Ok(maybe_stale(env, v, stale))
}

#[rustler::nif]
fn vt_modify_other_keys(env: Env, vt: ResourceArc<VtRes>) -> Term {
    let (v, stale) = vt.0.modify_other_keys();
    maybe_stale(env, v, stale)
}

#[rustler::nif]
fn vt_kitty_keyboard_flags(env: Env, vt: ResourceArc<VtRes>) -> Term {
    let (v, stale) = vt.0.kitty_keyboard_flags();
    maybe_stale(env, v, stale)
}

#[derive(NifMap)]
struct LinkMap {
    uri: String,
    kind: Atom,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vt_link_at(vt: ResourceArc<VtRes>, x: u16, y: u16) -> Option<LinkMap> {
    vt.0.link_at(x, y).map(|(uri, k)| LinkMap {
        uri,
        kind: match k {
            LinkKind::Hyperlink => atoms::hyperlink(),
            LinkKind::Text => atoms::text(),
        },
    })
}

#[derive(NifMap)]
struct PlacementMap {
    image_id: u32,
    placement_id: u32,
    z: i32,
    viewport_col: i32,
    viewport_row: i32,
    grid_cols: u32,
    grid_rows: u32,
    pixel_width: u32,
    pixel_height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
}

#[rustler::nif(schedule = "DirtyCpu")]
fn vt_graphics_placements(vt: ResourceArc<VtRes>) -> Vec<PlacementMap> {
    vt.0.graphics_placements()
        .into_iter()
        .map(|p| PlacementMap {
            image_id: p.image_id,
            placement_id: p.placement_id,
            z: p.z,
            viewport_col: p.viewport_col,
            viewport_row: p.viewport_row,
            grid_cols: p.grid_cols,
            grid_rows: p.grid_rows,
            pixel_width: p.pixel_width,
            pixel_height: p.pixel_height,
            source_x: p.source_x,
            source_y: p.source_y,
            source_width: p.source_width,
            source_height: p.source_height,
        })
        .collect()
}

#[derive(NifMap)]
struct CursorMap {
    x: u16,
    y: u16,
    visible: bool,
    blinking: bool,
    shape: Atom,
}

#[rustler::nif]
fn vt_cursor(vt: ResourceArc<VtRes>) -> Option<CursorMap> {
    use crate::vt::CursorShape::*;
    vt.0.cursor().map(|c| CursorMap {
        x: c.x,
        y: c.y,
        visible: c.visible,
        blinking: c.blinking,
        shape: match c.shape {
            Block => atoms::block(),
            Bar => atoms::bar(),
            Underline => atoms::underline(),
            BlockHollow => atoms::block_hollow(),
        },
    })
}

#[rustler::nif]
fn vt_encode_key<'a>(env: Env<'a>, vt: ResourceArc<VtRes>, ev: Term<'a>) -> NifResult<Term<'a>> {
    Ok(bin(env, &vt.0.encode_key(&decode_key(ev)?)))
}

#[rustler::nif]
fn vt_encode_mouse<'a>(env: Env<'a>, vt: ResourceArc<VtRes>, ev: Term<'a>) -> NifResult<Term<'a>> {
    Ok(match vt.0.encode_mouse(&decode_mouse(ev)?) {
        Some(b) => bin(env, &b),
        None => atoms::nil().encode(env),
    })
}

#[rustler::nif]
fn vt_encode_focus(env: Env, vt: ResourceArc<VtRes>, focused: bool) -> Term {
    bin(env, &vt.0.encode_focus(focused))
}

// ---- Pty ----

#[allow(clippy::too_many_arguments)] // mirrors the facade's `spawn/8`
#[rustler::nif(schedule = "DirtyIo")]
fn pty_spawn<'a>(
    env: Env<'a>,
    vt: ResourceArc<VtRes>,
    id: u64,
    cmd: String,
    argv: Vec<String>,
    envs: Vec<(String, String)>,
    cwd: Option<String>,
    cols: u16,
    rows: u16,
) -> Term<'a> {
    let sink = new_sink(id);
    let opts = SpawnOptions {
        id,
        cmd,
        args: argv,
        env: envs,
        cwd,
        cols,
        rows,
    };
    match Pty::spawn(Arc::clone(&vt.0), opts, sink.clone()) {
        Ok(pty) => {
            let pid = pty.os_pid();
            (atoms::ok(), ResourceArc::new(PtyRes { pty, sink }), pid).encode(env)
        }
        Err(e) => (atoms::error(), spawn_error(env, &e)).encode(env),
    }
}

fn new_sink(id: u64) -> Arc<BeamSink> {
    Arc::new(BeamSink {
        id,
        subs: Mutex::new(Vec::new()),
        exit: Mutex::new(None),
    })
}

#[allow(clippy::too_many_arguments)] // mirrors the facade's `adopt/8`
#[rustler::nif(schedule = "DirtyIo")]
fn pty_adopt<'a>(
    env: Env<'a>,
    vt: ResourceArc<VtRes>,
    id: u64,
    fd: ResourceArc<FdRes>,
    os_pid: u32,
    exited: bool,
    title: Option<Binary>,
    pwd: Option<Binary>,
    start_time: Option<u64>,
) -> Term<'a> {
    let Some(fd) = lock(&fd.0).take() else {
        return (atoms::error(), atoms::consumed()).encode(env);
    };
    let sink = new_sink(id);
    let opts = AdoptOptions {
        id,
        pid: os_pid,
        exited,
        title: title.map(|b| b.as_slice().to_vec()),
        pwd: pwd.map(|b| b.as_slice().to_vec()),
        start_time,
    };
    match Pty::adopt(Arc::clone(&vt.0), fd, opts, sink.clone()) {
        Ok(pty) => (atoms::ok(), ResourceArc::new(PtyRes { pty, sink })).encode(env),
        Err(e) => (atoms::error(), spawn_error(env, &e)).encode(env),
    }
}

/// CLOEXEC dup of a raw fd the caller still owns (e.g. a gen_tcp socket's).
fn dup_raw(raw: i64) -> std::io::Result<OwnedFd> {
    let raw = i32::try_from(raw)
        .ok()
        .filter(|r| *r >= 0)
        .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    // SAFETY: the caller keeps `raw` open for the duration of this call; the borrow
    // ends at the dup.
    unsafe { BorrowedFd::borrow_raw(raw) }.try_clone_to_owned()
}

#[rustler::nif]
fn fd_dup_raw(env: Env, raw: i64) -> Term {
    match dup_raw(raw) {
        Ok(fd) => (atoms::ok(), ResourceArc::new(FdRes(Mutex::new(Some(fd))))).encode(env),
        Err(e) => (atoms::error(), e.to_string()).encode(env),
    }
}

/// Takes the fd out of the resource; the caller owns the raw fd and must close or adopt it.
#[rustler::nif]
fn fd_into_raw(env: Env, fd: ResourceArc<FdRes>) -> Term {
    match lock(&fd.0).take() {
        Some(f) => (atoms::ok(), f.into_raw_fd()).encode(env),
        None => (atoms::error(), atoms::consumed()).encode(env),
    }
}

/// The fd number, still owned by the resource: for `:gen_tcp.fdopen`, whose port never
/// closes an fd it did not open (inet_drv marks it prebound).
#[rustler::nif]
fn fd_raw(env: Env, fd: ResourceArc<FdRes>) -> Term {
    match lock(&fd.0).as_ref() {
        Some(f) => (atoms::ok(), f.as_raw_fd()).encode(env),
        None => (atoms::error(), atoms::consumed()).encode(env),
    }
}

/// Closes the fd now instead of when the resource is collected.
#[rustler::nif]
fn fd_close(env: Env, fd: ResourceArc<FdRes>) -> Term {
    match lock(&fd.0).take() {
        Some(f) => {
            drop(f);
            atoms::ok().encode(env)
        }
        None => (atoms::error(), atoms::consumed()).encode(env),
    }
}

#[rustler::nif]
fn pty_dup_fd(env: Env, pty: ResourceArc<PtyRes>) -> Term {
    match pty.pty.dup_fd() {
        Ok(fd) => (atoms::ok(), ResourceArc::new(FdRes(Mutex::new(Some(fd))))).encode(env),
        Err(e) => (atoms::error(), spawn_error(env, &e)).encode(env),
    }
}

/// Joins the reader and writer (bounded by the writer's 50 ms tick).
#[rustler::nif(schedule = "DirtyIo")]
fn pty_freeze(env: Env, pty: ResourceArc<PtyRes>) -> Term {
    bin(env, &pty.pty.freeze())
}

/// DirtyIo: waits on the lock `pty_freeze` holds while joining.
#[rustler::nif(schedule = "DirtyIo")]
fn pty_take_pending(env: Env, pty: ResourceArc<PtyRes>) -> Term {
    bin(env, &pty.pty.take_pending())
}

#[rustler::nif(schedule = "DirtyIo")]
fn pty_thaw(env: Env, pty: ResourceArc<PtyRes>) -> Term {
    match pty.pty.thaw() {
        Ok(()) => atoms::ok().encode(env),
        Err(ThawError::Released) => (atoms::error(), atoms::released()).encode(env),
        Err(ThawError::Io(e)) => (atoms::error(), spawn_error(env, &e)).encode(env),
    }
}

/// DirtyIo: waits on the lock `pty_freeze` holds while joining.
#[rustler::nif(schedule = "DirtyIo")]
fn pty_release(env: Env, pty: ResourceArc<PtyRes>) -> Term {
    match pty.pty.release() {
        Ok(()) => atoms::ok().encode(env),
        Err(_) => (atoms::error(), atoms::not_frozen()).encode(env),
    }
}

#[rustler::nif]
fn pty_info(env: Env, pty: ResourceArc<PtyRes>) -> NifResult<Term> {
    let i = pty.pty.info();
    let opt = |b: &Option<Vec<u8>>| match b {
        Some(b) => bin(env, b),
        None => atoms::nil().encode(env),
    };
    let exited = match &i.exited {
        Some(s) => encode_status(env, s),
        None => atoms::nil().encode(env),
    };
    Term::map_from_pairs(
        env,
        &[
            (atoms::os_pid().encode(env), i.pid.encode(env)),
            (atoms::adopted().encode(env), i.adopted.encode(env)),
            (atoms::hidden().encode(env), i.hidden.encode(env)),
            (atoms::title().encode(env), opt(&i.title)),
            (atoms::pwd().encode(env), opt(&i.pwd)),
            (atoms::exited().encode(env), exited),
            (atoms::start_time().encode(env), i.start_time.encode(env)),
        ],
    )
}

/// The child's working directory (OS, else OSC 7), or nil. One syscall.
#[rustler::nif]
fn pty_cwd(env: Env, pty: ResourceArc<PtyRes>) -> Term {
    match pty.pty.cwd() {
        Some(p) => bin(env, p.as_bytes()),
        None => atoms::nil().encode(env),
    }
}

fn spawn_error<'a>(env: Env<'a>, e: &std::io::Error) -> Term<'a> {
    match e.raw_os_error() {
        Some(libc::ENOENT) => atoms::enoent().encode(env),
        Some(libc::EACCES) => atoms::eacces().encode(env),
        Some(libc::ENOTDIR) => atoms::enotdir().encode(env),
        Some(libc::ENOEXEC) => atoms::enoexec().encode(env),
        Some(libc::E2BIG) => atoms::e2big().encode(env),
        Some(n) => (atoms::os(), n).encode(env),
        None => (atoms::spawn(), e.to_string()).encode(env),
    }
}

#[rustler::nif]
fn pty_write<'a>(env: Env<'a>, pty: ResourceArc<PtyRes>, data: Term<'a>) -> NifResult<Term<'a>> {
    let bytes = Binary::from_iolist(data)?;
    Ok(match pty.pty.write(bytes.as_slice()) {
        Ok(()) => atoms::ok().encode(env),
        Err(WriteError::Backpressure) => (atoms::error(), atoms::backpressure()).encode(env),
        Err(WriteError::Closed) => (atoms::error(), atoms::closed()).encode(env),
        Err(WriteError::TooLarge) => (atoms::error(), atoms::too_large()).encode(env),
    })
}

#[rustler::nif]
fn pty_resize(
    pty: ResourceArc<PtyRes>,
    cols: u16,
    rows: u16,
    cell_px: Option<(u32, u32)>,
) -> NifResult<Atom> {
    // Per-cell px (as in `vt_resize`) to the winsize's total px.
    let total =
        |cell: u32, n: u16| u16::try_from(cell.saturating_mul(n as u32)).unwrap_or(u16::MAX);
    let px = cell_px.map(|(w, h)| (total(w, cols), total(h, rows)));
    pty.pty.resize(cols, rows, px).map_err(raise)?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn pty_kill(pty: ResourceArc<PtyRes>, sig: Term) -> NifResult<Atom> {
    let signo = match sig.decode::<Atom>() {
        Ok(a) if a == atoms::hup() => libc::SIGHUP,
        Ok(a) if a == atoms::term() => libc::SIGTERM,
        Ok(a) if a == atoms::kill() => libc::SIGKILL,
        Ok(a) if a == atoms::int() => libc::SIGINT,
        Ok(_) => return Err(Error::BadArg),
        Err(_) => match sig.decode::<i32>()? {
            n if n > 0 => n,
            _ => return Err(Error::BadArg),
        },
    };
    pty.pty.kill(signo).map_err(|e| match e.raw_os_error() {
        Some(libc::EINVAL) => Error::BadArg,
        _ => raise(e),
    })?;
    Ok(atoms::ok())
}

#[rustler::nif]
fn pty_subscribe(env: Env, pty: ResourceArc<PtyRes>, pid: LocalPid) -> Atom {
    // Some(exit) only when this call added the pid: a pid already subscribed got the exit
    // through the broadcast (or an earlier subscribe).
    let exited = {
        let mut subs = lock(&pty.sink.subs);
        match subs.iter().any(|(p, _)| *p == pid) {
            true => None,
            false => match env.monitor(&pty, &pid) {
                Some(m) => {
                    subs.push((pid, m));
                    lock(&pty.sink.exit).clone()
                }
                // Already dead: nothing to deliver to.
                None => return atoms::ok(),
            },
        }
    };
    with_caller(env, || pty.pty.request_full_damage());
    // An exit captured above was broadcast before this pid joined; a later one reaches
    // it through the broadcast.
    if let Some(s) = exited {
        let _ = env.send(&pid, (atoms::exit(), pty.sink.id, encode_status(env, &s)));
    }
    atoms::ok()
}

// ponytail: takes the blocking core lock and rebuilds the snapshot, so DirtyCpu; upgrade path is applying it on the reader thread between chunks.
#[rustler::nif(schedule = "DirtyCpu")]
fn pty_set_hidden(env: Env, pty: ResourceArc<PtyRes>, hidden: bool) -> Atom {
    with_caller(env, || pty.pty.set_hidden(hidden));
    atoms::ok()
}

// ---- Link ----

/// The broker link (`HerdrServer.Native.Link`). The owner is monitored: its death closes
/// the socket, which ends the reader thread.
pub struct LinkRes(Link);

#[rustler::resource_impl]
impl Resource for LinkRes {
    const IMPLEMENTS_DOWN: bool = true;

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _mon: Monitor) {
        self.0.close();
    }
}

/// Holds the resource so frames can name their link; the reader exits on close.
struct LinkBeamSink {
    owner: LocalPid,
    link: ResourceArc<LinkRes>,
}

impl LinkSink for LinkBeamSink {
    fn frame(&self, f: Frame) {
        let fds: Vec<ResourceArc<FdRes>> = f
            .fds
            .into_iter()
            .map(|fd| ResourceArc::new(FdRes(Mutex::new(Some(fd)))))
            .collect();
        deliver(&[self.owner], |env| {
            (
                atoms::herdr_link(),
                self.link.clone(),
                f.kind,
                bin(env, &f.body),
                fds.clone(),
            )
                .encode(env)
        });
    }

    fn closed(&self, reason: Option<String>) {
        deliver(&[self.owner], |env| {
            let r = match &reason {
                None => atoms::eof().encode(env),
                Some(m) => m.as_str().encode(env),
            };
            (atoms::herdr_link_closed(), self.link.clone(), r).encode(env)
        });
    }
}

/// Known link errors as atoms; `None` for the rest.
fn link_reason(e: &std::io::Error) -> Option<Atom> {
    use std::io::ErrorKind::*;
    Some(match (e.kind(), e.raw_os_error()) {
        (_, Some(libc::ENOENT)) => atoms::enoent(),
        (_, Some(libc::EACCES)) => atoms::eacces(),
        (_, Some(libc::ECONNREFUSED)) => atoms::econnrefused(),
        (_, Some(libc::EPIPE | libc::ECONNRESET | libc::ENOTCONN)) => atoms::closed(),
        (WouldBlock | TimedOut, _) => atoms::timeout(),
        // herdr_fdpass's "frame too large".
        (InvalidInput, None) => atoms::too_large(),
        _ => return None,
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn link_connect(env: Env, path: String, owner: LocalPid) -> Term {
    let fail = |e: &std::io::Error| {
        let r = match e.kind() {
            // std's over-long socket path (no errno).
            std::io::ErrorKind::InvalidInput => atoms::einval(),
            _ => link_reason(e).unwrap_or_else(atoms::connect_failed),
        };
        (atoms::error(), r).encode(env)
    };
    let link = match Link::connect(Path::new(&path), SEND_TIMEOUT) {
        Ok(l) => l,
        Err(e) => return fail(&e),
    };
    let res = ResourceArc::new(LinkRes(link));
    if env.monitor(&res, &owner).is_none() {
        res.0.close();
        return (atoms::error(), atoms::noproc()).encode(env);
    }
    let sink = LinkBeamSink {
        owner,
        link: res.clone(),
    };
    match res.0.start(sink) {
        Ok(()) => (atoms::ok(), res).encode(env),
        Err(e) => {
            res.0.close();
            fail(&e)
        }
    }
}

/// Each fd is sent as a fresh dup: a pty's master, or an unconsumed `FdRes` (left in place;
/// a dup also lets one `FdRes` appear twice without locking its mutex twice).
#[rustler::nif(schedule = "DirtyIo")]
fn link_send<'a>(
    env: Env<'a>,
    link: ResourceArc<LinkRes>,
    kind: u8,
    body: Term<'a>,
    fds: Vec<Term<'a>>,
) -> NifResult<Term<'a>> {
    let body = Binary::from_iolist(body)?;
    let mut owned: Vec<OwnedFd> = Vec::with_capacity(fds.len());
    for t in fds {
        let dup = if let Ok(f) = t.decode::<ResourceArc<FdRes>>() {
            match lock(&f.0).as_ref() {
                Some(fd) => fd.try_clone(),
                None => return Ok((atoms::error(), atoms::consumed()).encode(env)),
            }
        } else {
            t.decode::<ResourceArc<PtyRes>>()?.pty.dup_fd()
        };
        match dup {
            Ok(fd) => owned.push(fd),
            Err(e) => return Ok((atoms::error(), e.to_string()).encode(env)),
        }
    }
    let borrowed: Vec<_> = owned.iter().map(|f| f.as_fd()).collect();
    Ok(match link.0.send(kind, body.as_slice(), &borrowed) {
        Ok(()) => atoms::ok().encode(env),
        Err(e) => match link_reason(&e) {
            Some(a) => (atoms::error(), a).encode(env),
            None => (atoms::error(), e.to_string()).encode(env),
        },
    })
}

#[rustler::nif]
fn link_close(link: ResourceArc<LinkRes>) -> Atom {
    link.0.close();
    atoms::ok()
}

/// Set at load from `load_data` (`Mix.env() == :test`). One .so serves every Mix env, so
/// test hooks are always compiled in and are inert (`{:error, :disabled}`) outside test.
static TEST_HOOKS: AtomicBool = AtomicBool::new(false);

#[rustler::nif]
fn test_inject_reader_panic(env: Env, pty: ResourceArc<PtyRes>) -> Term {
    if !TEST_HOOKS.load(Ordering::Acquire) {
        return (atoms::error(), atoms::disabled()).encode(env);
    }
    pty.pty.inject_reader_panic();
    atoms::ok().encode(env)
}

/// True when SIGCHLD is ignored or SA_NOCLDWAIT is set: the kernel would auto-reap our
/// children and the per-pid waiter would lose their exit status.
fn sigchld_auto_reaps() -> bool {
    // SAFETY: a zeroed sigaction is a valid out-parameter; a null `act` only queries.
    let mut old: libc::sigaction = unsafe { std::mem::zeroed() };
    let r = unsafe { libc::sigaction(libc::SIGCHLD, ptr::null(), &mut old) };
    r != 0 || old.sa_sigaction == libc::SIG_IGN || old.sa_flags & libc::SA_NOCLDWAIT != 0
}

/// ERTS itself sets SIGCHLD to SIG_IGN with SA_NOCLDWAIT (its children are reaped by
/// erl_child_setup, so it never waits). Restore the default disposition, which is not a
/// handler; ERTS never waits on a child of its own, so it is unaffected.
fn restore_default_sigchld() {
    // SAFETY: a zeroed sigaction with SIG_DFL, no flags and an empty mask is valid.
    let mut act: libc::sigaction = unsafe { std::mem::zeroed() };
    act.sa_sigaction = libc::SIG_DFL;
    unsafe {
        libc::sigemptyset(&mut act.sa_mask);
        libc::sigaction(libc::SIGCHLD, &act, ptr::null_mut());
    }
}

// Covered by the ExUnit exit-status tests: ERTS starts with auto-reaping SIGCHLD, so
// `{:exit, id, 0}` arriving proves the restore. (A cargo test would race the pty tests.)
pub fn load(_env: Env, info: Term) -> bool {
    TEST_HOOKS.store(info.decode::<bool>().unwrap_or(false), Ordering::Release);
    // Kernel panics surface as exit events and NIF raises; never print them (no stderr).
    std::panic::set_hook(Box::new(|_| {}));
    if sigchld_auto_reaps() {
        restore_default_sigchld();
    }
    // Refuse to load if SIGCHLD still auto-reaps: exit statuses would be lost. ERTS reports
    // this only as "Library load-call unsuccessful (1)".
    !sigchld_auto_reaps()
}

#[cfg(test)]
mod fd_tests {
    use super::dup_raw;
    use std::io::{Read, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn dup_raw_survives_closing_the_original() {
        let (a, mut b) = UnixStream::pair().expect("pair");
        let dup = dup_raw(i64::from(a.as_raw_fd())).expect("dup");
        drop(a);
        let mut a2 = UnixStream::from(dup);
        a2.write_all(b"hi").expect("write");
        let mut buf = [0u8; 2];
        b.read_exact(&mut buf).expect("read");
        assert_eq!(&buf, b"hi");
    }

    #[test]
    fn dup_raw_rejects_negative() {
        assert!(dup_raw(-1).is_err());
    }
}
