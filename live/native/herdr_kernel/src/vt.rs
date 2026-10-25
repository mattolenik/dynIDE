//! One ghostty terminal plus a snapshot of packed rows (`docs/herdr-live/packed-cells.md`).
//! Parsing and encoding happen under the core lock; BEAM-facing reads use the snapshot.

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, TryLockError};

use base64::Engine as _;
use ghostty_vt::{
    ActiveScreen, CellColor, CellStyle, CellWide, ColorScheme, CursorVisualStyle, DefaultColor,
    Dirty, KittyImageFormat, KittyImagePlacement, LinkTarget, RenderState, RgbColor, RowCells,
    RowIterator, Terminal,
};

use crate::cell::RowEncoder;
use crate::input::Encoders;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VtError {
    Ghostty(ghostty_vt::Error),
}

impl From<ghostty_vt::Error> for VtError {
    fn from(e: ghostty_vt::Error) -> Self {
        VtError::Ghostty(e)
    }
}

/// Modes mirrored into the snapshot.
///
/// `mode_get` takes a packed `GhosttyMode` (`vendor/libghostty-vt/include/ghostty/vt/modes.h`):
/// bits 0-14 are the mode number and bit 15 is the ANSI flag, 0 for DEC private. So a DEC
/// private mode is addressed by its bare number (`?2004` is `2004`), matching the
/// `ghostty_vt::MODE_*` constants; an ANSI mode would need `n | 0x8000`. None are listed here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    CursorKeys,
    Origin,
    Wraparound,
    CursorBlinking,
    CursorVisible,
    MouseX10,
    MouseNormal,
    MouseButton,
    MouseAny,
    FocusEvents,
    MouseUtf8,
    MouseSgr,
    AlternateScroll,
    MouseSgrPixels,
    BracketedPaste,
    SynchronizedOutput,
    GraphemeCluster,
    ColorSchemeReport,
    /// `active_screen() == Alternate`; not a `mode_get` id.
    AltScreen,
}

const MODES: [(Mode, &str, u16); Mode::COUNT] = [
    (Mode::CursorKeys, "cursor_keys", 1),
    (Mode::Origin, "origin", 6),
    (Mode::Wraparound, "wraparound", 7),
    (Mode::CursorBlinking, "cursor_blinking", 12),
    (Mode::CursorVisible, "cursor_visible", 25),
    (Mode::MouseX10, "mouse_x10", 9),
    (Mode::MouseNormal, "mouse_normal", 1000),
    (Mode::MouseButton, "mouse_button", 1002),
    (Mode::MouseAny, "mouse_any", 1003),
    (Mode::FocusEvents, "focus_events", 1004),
    (Mode::MouseUtf8, "mouse_utf8", 1005),
    (Mode::MouseSgr, "mouse_sgr", 1006),
    (Mode::AlternateScroll, "alternate_scroll", 1007),
    (Mode::MouseSgrPixels, "mouse_sgr_pixels", 1016),
    (Mode::BracketedPaste, "bracketed_paste", 2004),
    (Mode::SynchronizedOutput, "synchronized_output", 2026),
    (Mode::GraphemeCluster, "grapheme_cluster", 2027),
    (Mode::ColorSchemeReport, "color_scheme_report", 2031),
    (Mode::AltScreen, "alt_screen", 0),
];

impl Mode {
    pub const COUNT: usize = 19;

    pub fn from_name(name: &str) -> Option<Mode> {
        MODES
            .iter()
            .find(|(_, n, _)| *n == name)
            .map(|(m, _, _)| *m)
    }

    fn read(self, t: &Terminal) -> bool {
        match self {
            Mode::AltScreen => matches!(t.active_screen(), Ok(ActiveScreen::Alternate)),
            m => t.mode_get(MODES[m as usize].2).unwrap_or(false),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Scrollbar {
    pub total: usize,
    pub viewport: usize,
    pub offset: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Bar,
    Underline,
    BlockHollow,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub x: u16,
    pub y: u16,
    pub visible: bool,
    pub blinking: bool,
    pub shape: CursorShape,
}

/// `(gen, [(row_index, packed_row)])`.
pub type RowBatch = (u64, Vec<(u16, Arc<[u8]>)>);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub gen: u64,
    pub bytes: Arc<[u8]>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub gen: u64,
    pub cols: u16,
    pub rows: Vec<Row>,
    pub cursor: Option<Cursor>,
    pub modes: [bool; Mode::COUNT],
    pub kitty_flags: u8,
    pub modify_other_keys: bool,
    pub scrollbar: Scrollbar,
    /// Visible kitty placements sorted by z, without pixel data.
    pub graphics: Arc<[Placement]>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WriteEffects {
    pub bells: u16,
    pub pwd: Vec<Vec<u8>>,
    pub clipboard: Vec<Vec<u8>>,
}

/// Upper bound on `Vt::tail_ansi` rows; larger requests are clamped.
pub const MAX_TAIL_ROWS: usize = 10_000;

/// The primary screen's last rows as VT, or AltScreen when a full-screen app owns it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tail {
    Ansi(String),
    AltScreen,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextRange {
    Viewport,
    Screen,
    /// Inclusive screen rows.
    Rows(u32, u32),
}

/// Default colours for ghostty to report and render with; None unsets. `palette`
/// entries overlay ghostty's built-in palette.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Colors {
    pub fg: Option<RgbColor>,
    pub bg: Option<RgbColor>,
    pub cursor: Option<RgbColor>,
    pub palette: Vec<(u8, RgbColor)>,
}

/// Most rows one `screen_rows` call returns.
pub const SCREEN_ROWS_MAX: u32 = 1000;

/// `(screen_row, packed_row, soft_wraps_into_next)`.
pub type ScreenRow = (u32, Vec<u8>, bool);

/// Rows `search` reads per core lock, so the reader waits at most this many rows.
const SEARCH_LOCK_ROWS: u32 = 256;
/// Rows one `search` call reads at most, whatever `max_rows` asks: one DirtyCpu call stays
/// bounded regardless of the caller.
pub const SEARCH_MAX_ROWS: u32 = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Forward,
    Backward,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchOpts {
    /// Rows read at most (one call's budget).
    pub max_rows: u32,
    /// Stop after the row on which this many matches were reached.
    pub max_matches: usize,
    pub case_sensitive: bool,
    /// First screen row read; clamped to the last row going backward.
    pub from: u32,
    pub direction: Direction,
}

/// `(screen_row, first_col, cells)` of one match.
pub type SearchMatch = (u32, u32, u32);

/// One row's text with the cell each glyph came from: wide tails are skipped, an empty
/// cell reads as a space (as `HerdrServer.Client.Words.text_cells`).
#[derive(Default)]
struct RowText {
    text: String,
    /// per glyph: (byte offset in `text`, first col, last col)
    cells: Vec<(usize, u32, u32)>,
    col: u32,
}

impl RowText {
    fn clear(&mut self) {
        self.text.clear();
        self.cells.clear();
        self.col = 0;
    }

    fn push(&mut self, wide: CellWide, cps: &[u32], fold: bool) {
        let x = self.col;
        self.col += 1;
        let last = match wide {
            CellWide::SpacerTail => return,
            CellWide::Wide => x + 1,
            CellWide::Narrow | CellWide::SpacerHead => x,
        };
        let at = self.text.len();
        if matches!(wide, CellWide::Narrow | CellWide::Wide) {
            for c in cps.iter().filter_map(|&c| char::from_u32(c)) {
                match fold {
                    true => self.text.extend(c.to_lowercase()),
                    false => self.text.push(c),
                }
            }
        }
        if self.text.len() == at {
            self.text.push(' ');
        }
        self.cells.push((at, x, last));
    }

    /// Non-overlapping matches of `needle` that start and end on glyph boundaries.
    fn matches(&self, needle: &str, row: u32, out: &mut Vec<SearchMatch>) {
        let cell = |off: usize| self.cells.binary_search_by_key(&off, |c| c.0).ok();
        for (off, m) in self.text.match_indices(needle) {
            let end = off + m.len();
            let past = match end == self.text.len() {
                true => Some(self.cells.len()),
                false => cell(end),
            };
            let (Some(a), Some(b)) = (cell(off), past) else {
                continue;
            };
            let (first, last) = (self.cells[a].1, self.cells[b - 1].2);
            out.push((row, first, last - first + 1));
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkKind {
    Hyperlink,
    Text,
}

/// A visible kitty placement, in `HerdrScene.Scene.Graphic` terms.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub image_id: u32,
    pub fingerprint: u64,
    pub placement_id: u32,
    pub z: i32,
    /// Viewport top-left cell; negative when partly scrolled off.
    pub x: i32,
    pub y: i32,
    pub cols: u32,
    pub rows: u32,
    pub x_off: u32,
    pub y_off: u32,
    /// `(sx, sy, sw, sh)` in image pixels.
    pub src: (u32, u32, u32, u32),
    /// Rendered size in pixels.
    pub px: (u32, u32),
    pub width: u32,
    pub height: u32,
    pub format: KittyImageFormat,
    pub bytes: usize,
}

/// Ghostty reports an implicit placement (no `p=`) by its internal id (a per-screen counter
/// from 0), so only the first is 0; the contract wants a positive id, so the nth 0-id
/// placement of an image (list order) gets `u32::MAX - n`.
// ponytail: internal and external ids share one namespace in ghostty's C API, so an
// implicit placement with internal id k collides with an explicit `p=k` of the same image;
// expose ghostty's placement tag in crates/ghostty-vt if that shows up.
fn number_implicit(ps: &mut [Placement]) {
    let mut seen: HashMap<u32, u32> = HashMap::new();
    for p in ps.iter_mut().filter(|p| p.placement_id == 0) {
        let n = seen.entry(p.image_id).or_insert(0);
        p.placement_id = u32::MAX - *n;
        *n += 1;
    }
}

/// One stored image's pixels as the child sent them (decoded unless PNG-forwarded).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    pub format: KittyImageFormat,
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

fn replay_graphics(t: &Terminal, cap: usize) -> Result<Vec<u8>, VtError> {
    if !t.kitty_graphics_may_have_placements()? {
        return Ok(Vec::new());
    }
    let virt = t.kitty_virtual_placements()?;
    let sb = t.scrollbar()?;
    // rows the viewport sits above the active area (user scrolled back)
    let back = sb.total.saturating_sub(sb.len + sb.offset) as i32;
    let rows = i32::from(t.rows()?);
    let placed: Vec<KittyImagePlacement> = match t.mode_get(MODES[Mode::Origin as usize].2)? {
        true => Vec::new(),
        false => t
            .kitty_image_placements_with_data_filter(|_| false)?
            .into_iter()
            .filter(|p| !p.is_virtual && p.render.viewport_col >= 0)
            .filter(|p| (0..rows).contains(&(p.render.viewport_row - back)))
            .collect(),
    };

    let mut out = Vec::new();
    let mut carried = HashSet::new();
    let mut seen = HashSet::new();
    let mut budget = cap;
    let ids = virt
        .iter()
        .map(|v| v.image_id)
        .chain(placed.iter().map(|p| p.image_id));
    for id in ids {
        // once per image: a skipped one is not copied again for its next placement
        if !seen.insert(id) {
            continue;
        }
        // the length check comes before the copy, under the core lock
        let Some((d, data)) = t.kitty_image(id, budget)? else {
            continue;
        };
        if data.is_empty() || data.len() > budget {
            continue;
        }
        budget -= data.len();
        carried.insert(id);
        let (w, h) = (d.image_width, d.image_height);
        let control = match d.format {
            KittyImageFormat::Png => format!("a=t,q=2,f=100,i={id}"),
            KittyImageFormat::Rgb => format!("a=t,q=2,f=24,s={w},v={h},i={id}"),
            KittyImageFormat::Rgba => format!("a=t,q=2,f=32,s={w},v={h},i={id}"),
        };
        let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
        let chunks: Vec<&[u8]> = b64.as_bytes().chunks(4096).collect();
        for (i, chunk) in chunks.iter().enumerate() {
            let more = u8::from(i + 1 < chunks.len());
            match i {
                0 => out.extend_from_slice(format!("\x1b_G{control},m={more};").as_bytes()),
                _ => out.extend_from_slice(format!("\x1b_Gm={more};").as_bytes()),
            }
            out.extend_from_slice(chunk);
            out.extend_from_slice(b"\x1b\\");
        }
    }
    if carried.is_empty() {
        return Ok(Vec::new());
    }

    let mut cmd = String::new();
    for v in virt.iter().filter(|v| carried.contains(&v.image_id)) {
        let _ = write!(cmd, "\x1b_Ga=p,q=2,U=1,i={},z={}", v.image_id, v.z);
        for (k, n) in [("p", v.placement_id), ("c", v.columns), ("r", v.rows)] {
            if n > 0 {
                let _ = write!(cmd, ",{k}={n}");
            }
        }
        cmd.push_str("\x1b\\");
    }
    let mut moved = false;
    for p in placed.iter().filter(|p| carried.contains(&p.image_id)) {
        moved = true;
        let r = &p.render;
        let _ = write!(
            cmd,
            "\x1b[{};{}H\x1b_Ga=p,q=2,C=1,i={},c={},r={},x={},y={},w={},h={},X={},Y={},z={}",
            r.viewport_row - back + 1,
            r.viewport_col + 1,
            p.image_id,
            r.grid_cols,
            r.grid_rows,
            r.source_x,
            r.source_y,
            r.source_width,
            r.source_height,
            p.x_offset,
            p.y_offset,
            p.z
        );
        // ghostty reports implicit placements by internal id from 0: replaying the 0 one
        // implicitly gets 0 again in the fresh storage
        if p.placement_id > 0 {
            let _ = write!(cmd, ",p={}", p.placement_id);
        }
        cmd.push_str("\x1b\\");
    }
    // only after a CUP of ours: under origin mode a CUP would be margin-relative
    if moved {
        let _ = write!(cmd, "\x1b[{};{}H", t.cursor_y()? + 1, t.cursor_x()? + 1);
    }
    out.extend_from_slice(cmd.as_bytes());
    Ok(out)
}

fn placement(p: &KittyImagePlacement) -> Option<Placement> {
    let r = &p.render;
    if r.grid_cols == 0 || r.grid_rows == 0 || p.image_width == 0 || p.image_height == 0 {
        return None;
    }
    Some(Placement {
        image_id: p.image_id,
        fingerprint: p.data_fingerprint,
        placement_id: p.placement_id,
        z: p.z,
        x: r.viewport_col,
        y: r.viewport_row,
        cols: r.grid_cols,
        rows: r.grid_rows,
        x_off: p.x_offset,
        y_off: p.y_offset,
        src: (r.source_x, r.source_y, r.source_width, r.source_height),
        px: (r.pixel_width, r.pixel_height),
        width: p.image_width,
        height: p.image_height,
        format: p.format,
        bytes: p.data_len,
    })
}

struct VtCore {
    terminal: Terminal,
    render_state: RenderState,
    row_iter: RowIterator,
    row_cells: RowCells,
    links: HashMap<String, u32>,
    dirty_all: bool,
    cell_px: (u32, u32),
    /// Last built snapshot; kept here so concurrent refreshes cannot reuse a gen.
    last: Arc<Snapshot>,
}

pub struct Vt {
    core: Mutex<VtCore>,
    snapshot: Mutex<Arc<Snapshot>>,
    read_cursor: AtomicU64,
    /// Lock order: core, then encoders. Only `write`/`resize` hold both.
    pub(crate) encoders: Mutex<Encoders>,
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

fn color(c: Option<CellColor>) -> u32 {
    match c {
        None => 0,
        Some(CellColor::Palette(i)) => 1 << 24 | i as u32,
        Some(CellColor::Rgb(c)) => 2 << 24 | (c.r as u32) << 16 | (c.g as u32) << 8 | c.b as u32,
    }
}

fn attrs(s: &CellStyle) -> u16 {
    let flags = [
        s.bold,
        s.italic,
        s.faint,
        s.blink,
        s.inverse,
        s.invisible,
        s.strikethrough,
        s.overline,
    ];
    let bits = flags
        .iter()
        .enumerate()
        .fold(0u16, |a, (i, &f)| a | (f as u16) << i);
    bits | (s.underline as u16 & 0b111) << 8
}

fn blank_row(cols: u16) -> Vec<u8> {
    let mut enc = RowEncoder::with_cols(cols as usize);
    for _ in 0..cols {
        enc.push(b"", 0, 0, 0, 0, 1, 0);
    }
    enc.finish()
}

impl VtCore {
    /// Encodes render-state rows (None = clean, skipped). Borrows fields separately so the
    /// live terminal can resolve hyperlinks while the row iterator is held.
    fn encode_rows(&mut self, full: bool, cols: u16) -> Result<Vec<Option<Vec<u8>>>, VtError> {
        let VtCore {
            terminal,
            render_state,
            row_iter,
            row_cells,
            links,
            ..
        } = self;
        let mut out = Vec::new();
        let mut rows = render_state.populate_row_iterator(row_iter)?;
        let mut scratch = (Vec::new(), String::new());
        while rows.next() {
            let y = out.len() as u32;
            if !full && !rows.dirty()? {
                out.push(None);
                continue;
            }
            let mut enc = RowEncoder::with_cols(cols as usize);
            let mut cells = rows.populate_cells(row_cells)?;
            let mut x = 0u16;
            while x < cols && cells.next() {
                if cells.is_default_blank()? {
                    enc.push(b"", 0, 0, 0, 0, 1, 0);
                    x += 1;
                    continue;
                }
                let basic = cells.basic_data()?;
                let width = match basic.wide {
                    CellWide::Wide => 2,
                    CellWide::SpacerTail => 0,
                    CellWide::Narrow | CellWide::SpacerHead => 1,
                };
                let glyph: &[u8] = match basic.wide {
                    CellWide::Narrow | CellWide::Wide => {
                        cells.grapheme_text_into(&mut scratch.0, &mut scratch.1)?;
                        scratch.1.as_bytes()
                    }
                    CellWide::SpacerTail | CellWide::SpacerHead => b"",
                };
                let link = match basic.has_hyperlink {
                    false => 0,
                    true => match terminal.viewport_hyperlink_uri(x, y)? {
                        None => 0,
                        Some(uri) => {
                            let next = links.len() as u32 + 1;
                            *links.entry(uri).or_insert(next)
                        }
                    },
                };
                let s = &basic.style;
                enc.push(
                    glyph,
                    color(s.fg_color),
                    color(s.bg_color),
                    color(s.underline_color),
                    attrs(s),
                    width,
                    link,
                );
                x += 1;
            }
            for _ in x..cols {
                enc.push(b"", 0, 0, 0, 0, 1, 0);
            }
            rows.clear_dirty()?;
            out.push(Some(enc.finish()));
        }
        Ok(out)
    }

    fn build(&mut self) -> Result<Snapshot, VtError> {
        self.render_state.update(&self.terminal)?;
        let cols = self.render_state.cols()?;
        let n = self.render_state.rows()? as usize;
        let prev = Arc::clone(&self.last);
        let full = self.dirty_all
            || self.render_state.dirty()? == Dirty::Full
            || prev.cols != cols
            || prev.rows.len() != n;
        let gen = prev.gen + 1;
        let mut encoded = self.encode_rows(full, cols)?;
        self.render_state.set_dirty(Dirty::Clean)?;
        let rows = (0..n)
            .map(|y| {
                let old = prev.rows.get(y);
                match (encoded.get_mut(y).and_then(Option::take), old) {
                    // Unchanged bytes keep their Arc and gen, so a row that ghostty
                    // flags dirty (e.g. the old cursor row) is not re-sent.
                    (Some(b), Some(o)) if *o.bytes == *b => o.clone(),
                    (Some(b), _) => Row {
                        gen,
                        bytes: b.into(),
                    },
                    (None, Some(o)) => o.clone(),
                    (None, None) => Row {
                        gen,
                        bytes: blank_row(cols).into(),
                    },
                }
            })
            .collect();
        let c = self.render_state.cursor()?;
        let cursor = c.viewport.map(|v| Cursor {
            x: v.x,
            y: v.y,
            visible: c.visible,
            blinking: c.blinking,
            shape: match c.visual_style {
                CursorVisualStyle::Block => CursorShape::Block,
                CursorVisualStyle::Bar => CursorShape::Bar,
                CursorVisualStyle::Underline => CursorShape::Underline,
                CursorVisualStyle::BlockHollow => CursorShape::BlockHollow,
            },
        });
        let sb = self.terminal.scrollbar()?;
        let mut modes = [false; Mode::COUNT];
        for (m, _, _) in MODES {
            modes[m as usize] = m.read(&self.terminal);
        }
        self.dirty_all = false;
        Ok(Snapshot {
            gen,
            cols,
            rows,
            cursor,
            modes,
            kitty_flags: self.terminal.kitty_keyboard_flags().unwrap_or(0),
            modify_other_keys: self.terminal.modify_other_keys_enabled().unwrap_or(false),
            scrollbar: Scrollbar {
                total: sb.total,
                viewport: sb.len,
                offset: sb.offset,
            },
            graphics: self.graphics(&prev),
        })
    }

    /// Placements for the snapshot; the common no-image case skips the storage walk.
    fn graphics(&self, prev: &Snapshot) -> Arc<[Placement]> {
        if !self
            .terminal
            .kitty_graphics_may_have_placements()
            .unwrap_or(false)
        {
            return Arc::new([]);
        }
        let Ok(ps) = self
            .terminal
            .kitty_image_placements_with_data_filter(|_| false)
        else {
            // Keep the last good list rather than flashing images off on a ghostty error.
            return Arc::clone(&prev.graphics);
        };
        let mut ps: Vec<Placement> = ps.iter().filter_map(placement).collect();
        number_implicit(&mut ps);
        match *prev.graphics == *ps {
            true => Arc::clone(&prev.graphics),
            false => ps.into(),
        }
    }
}

impl Vt {
    pub fn new(cols: u16, rows: u16, max_scrollback: usize) -> Result<Arc<Vt>, VtError> {
        Self::from_terminal(Terminal::new(cols, rows, max_scrollback)?)
    }

    /// Rebuilds a Vt from `encode_snapshot` bytes; size comes from the snapshot.
    pub fn restore(bytes: &[u8], max_scrollback: usize) -> Result<Arc<Vt>, VtError> {
        Self::from_terminal(Terminal::from_snapshot(bytes, max_scrollback)?)
    }

    pub fn encode_snapshot(&self) -> Result<Vec<u8>, VtError> {
        Ok(lock(&self.core).terminal.encode_snapshot()?)
    }

    /// VT bytes that re-create this terminal's kitty images in a `restore`d copy, which
    /// ghostty's snapshot leaves out: each image a stored virtual placement or an on-screen
    /// placement of the active screen uses, while their pixels total at most `cap`, then
    /// those placements (with explicit `c`/`r`, as the restored copy has no cell pixel
    /// size yet), then the cursor back where it was. Empty when there is nothing to carry.
    // ponytail: placements partly scrolled off the top, in scrollback, on the inactive
    // screen or under origin mode, and images with no placement, are not carried; the
    // final CUP drops a pending wrap. Carry them with a ghostty snapshot record if missed.
    pub fn graphics_replay(&self, cap: usize) -> Vec<u8> {
        let core = lock(&self.core);
        replay_graphics(&core.terminal, cap).unwrap_or_default()
    }

    fn from_terminal(mut terminal: Terminal) -> Result<Arc<Vt>, VtError> {
        terminal.enable_kitty_graphics()?;
        // Ruling 4 (m5): continuation tracking so a snapshot never fails mid-escape.
        terminal.set_continuation_max_bytes(ghostty_vt::CONTINUATION_MAX_BYTES)?;
        let empty = Arc::new(Snapshot {
            gen: 0,
            cols: 0,
            rows: Vec::new(),
            cursor: None,
            modes: [false; Mode::COUNT],
            kitty_flags: 0,
            modify_other_keys: false,
            scrollbar: Scrollbar::default(),
            graphics: Arc::new([]),
        });
        let vt = Arc::new(Vt {
            core: Mutex::new(VtCore {
                terminal,
                render_state: RenderState::new()?,
                row_iter: RowIterator::new()?,
                row_cells: RowCells::new()?,
                links: HashMap::new(),
                dirty_all: true,
                cell_px: (0, 0),
                last: Arc::clone(&empty),
            }),
            snapshot: Mutex::new(empty),
            read_cursor: AtomicU64::new(0),
            encoders: Mutex::new(Encoders::new()?),
        });
        vt.refresh_encoders(&lock(&vt.core));
        vt.try_refresh()?;
        Ok(vt)
    }

    pub fn set_write_pty(&self, f: impl FnMut(&[u8]) + Send + 'static) {
        // Only fails if ghostty rejects the option, which it accepts for any live terminal.
        let _ = lock(&self.core).terminal.set_write_pty_callback(f);
    }

    pub fn write(&self, bytes: &[u8]) -> WriteEffects {
        let mut core = lock(&self.core);
        core.terminal.write(bytes);
        let fx = WriteEffects {
            bells: core.terminal.take_bell_count(),
            pwd: core.terminal.take_pwd_changes(),
            clipboard: core.terminal.take_clipboard_writes(),
        };
        self.refresh_encoders(&core);
        fx
    }

    /// Reconfigures the cached key and mouse encoders from the live terminal.
    fn refresh_encoders(&self, core: &VtCore) {
        lock(&self.encoders).configure(&core.terminal, core.cell_px);
    }

    pub fn refresh(&self) -> u64 {
        match self.try_refresh() {
            Ok(gen) => gen,
            Err(_) => {
                // Keep the last good snapshot; re-encode everything next time.
                lock(&self.core).dirty_all = true;
                self.snapshot().gen
            }
        }
    }

    fn try_refresh(&self) -> Result<u64, VtError> {
        let snap = {
            let mut core = lock(&self.core);
            let snap = Arc::new(core.build()?);
            core.last = Arc::clone(&snap);
            snap
        };
        let gen = snap.gen;
        let mut cur = lock(&self.snapshot);
        if cur.gen < gen {
            *cur = snap;
        }
        Ok(gen)
    }

    /// Test hook for `Pty::inject_reader_panic`: panics with the core lock held, poisoning it.
    pub(crate) fn panic_holding_core(&self) {
        let _core = lock(&self.core);
        panic!("injected reader panic");
    }

    pub fn mark_all_dirty(&self) {
        lock(&self.core).dirty_all = true;
    }

    pub fn snapshot(&self) -> Arc<Snapshot> {
        Arc::clone(&lock(&self.snapshot))
    }

    /// The published snapshot's gen; it moves whenever a row changes.
    pub fn gen(&self) -> u64 {
        lock(&self.snapshot).gen
    }

    pub fn rows_since(&self, gen: u64) -> RowBatch {
        let s = self.snapshot();
        let rows = s
            .rows
            .iter()
            .enumerate()
            .filter(|(_, r)| r.gen > gen)
            .map(|(y, r)| (y as u16, Arc::clone(&r.bytes)))
            .collect();
        (s.gen, rows)
    }

    pub fn dirty_rows(&self) -> RowBatch {
        let out = self.rows_since(self.read_cursor.load(Ordering::Acquire));
        // fetch_max: a concurrent caller must never move the cursor backwards.
        self.read_cursor.fetch_max(out.0, Ordering::AcqRel);
        out
    }

    pub fn full_rows(&self) -> RowBatch {
        self.rows_since(0)
    }

    pub fn reset_read_cursor(&self) {
        self.read_cursor.store(0, Ordering::Release);
    }

    pub fn resize(
        &self,
        cols: u16,
        rows: u16,
        cell_px: Option<(u32, u32)>,
    ) -> Result<u64, VtError> {
        {
            let mut core = lock(&self.core);
            if let Some(px) = cell_px {
                core.cell_px = px;
            }
            let (w, h) = core.cell_px;
            core.terminal.resize(cols, rows, w, h)?;
            core.dirty_all = true;
            self.refresh_encoders(&core);
        }
        self.try_refresh()
    }

    pub fn read_text(&self, r: TextRange) -> Result<String, VtError> {
        let core = lock(&self.core);
        let t = &core.terminal;
        let right = t.cols()?.saturating_sub(1);
        Ok(match r {
            TextRange::Viewport => {
                t.read_text_viewport((0, 0), (right, t.rows()?.saturating_sub(1) as u32), false)?
            }
            TextRange::Screen => {
                let last = t.total_rows()?.saturating_sub(1) as u32;
                t.read_text_screen((0, 0), (right, last), false)?
            }
            TextRange::Rows(a, b) => t.read_text_screen((0, a), (right, b), false)?,
        })
    }

    /// The last `n` non-blank-trailing rows of history plus screen as VT (unwrapped,
    /// trimmed). Trailing blank rows below the last content row are skipped. `n` is
    /// clamped to `MAX_TAIL_ROWS`.
    pub fn tail_ansi(&self, n: usize) -> Result<Tail, VtError> {
        let n = n.min(MAX_TAIL_ROWS);
        let core = lock(&self.core);
        let t = &core.terminal;
        if t.active_screen()? == ActiveScreen::Alternate {
            return Ok(Tail::AltScreen);
        }
        let right = t.cols()?.saturating_sub(1);
        let mut end = t.total_rows()?;
        // Only the screen's bottom rows can be blank padding; bound the walk by its height.
        let floor = end.saturating_sub(t.rows()? as usize);
        while end > floor
            && t.read_text_screen((0, end as u32 - 1), (right, end as u32 - 1), false)?
                .trim()
                .is_empty()
        {
            end -= 1;
        }
        if n == 0 || end == 0 {
            return Ok(Tail::Ansi(String::new()));
        }
        let start = end.saturating_sub(n) as u32;
        let s = t.read_ansi_screen((0, start), (right, end as u32 - 1), false, true)?;
        Ok(Tail::Ansi(s))
    }

    /// Plain text between two screen points (inclusive, either order), soft wraps
    /// joined and trailing whitespace trimmed. Points past the screen clamp to it.
    pub fn read_selection(&self, a: (u16, u32), b: (u16, u32)) -> Result<String, VtError> {
        let core = lock(&self.core);
        let t = &core.terminal;
        let right = t.cols()?.saturating_sub(1);
        let bottom = u32::try_from(t.total_rows()?.saturating_sub(1)).unwrap_or(u32::MAX);
        let clamp = |(x, y): (u16, u32)| (x.min(right), y.min(bottom));
        let (a, b) = (clamp(a), clamp(b));
        let (start, end) = match (a.1, a.0) <= (b.1, b.0) {
            true => (a, b),
            false => (b, a),
        };
        Ok(t.read_text_screen(start, end, false)?)
    }

    /// Inclusive screen rows `first..=last` (at most `SCREEN_ROWS_MAX`, rows past the end
    /// omitted), packed with glyph and width only.
    pub fn screen_rows(&self, first: u32, last: u32) -> Result<Vec<ScreenRow>, VtError> {
        let core = lock(&self.core);
        let t = &core.terminal;
        let total = u32::try_from(t.total_rows()?).unwrap_or(u32::MAX);
        let last = last
            .min(first.saturating_add(SCREEN_ROWS_MAX - 1))
            .min(total.saturating_sub(1));
        let cols = t.cols()? as usize;
        let mut out = Vec::new();
        let mut glyph = String::new();
        for y in first..=last {
            if y >= total {
                break;
            }
            let mut enc = RowEncoder::with_cols(cols);
            let wrapped = t.for_each_screen_row_cell(y, |wide, cps| {
                glyph.clear();
                let width = match wide {
                    CellWide::Wide => 2,
                    CellWide::SpacerTail => 0,
                    CellWide::Narrow | CellWide::SpacerHead => 1,
                };
                if matches!(wide, CellWide::Narrow | CellWide::Wide) {
                    glyph.extend(cps.iter().filter_map(|&c| char::from_u32(c)));
                }
                enc.push(glyph.as_bytes(), 0, 0, 0, 0, width, 0);
            })?;
            out.push((y, enc.finish(), wrapped));
        }
        Ok(out)
    }

    /// Matches of `query` (case folded per char with `to_lowercase`, as the rows are, unless
    /// `case_sensitive`) over at most `o.max_rows` (capped at `SEARCH_MAX_ROWS`) rows from `o.from` in `o.direction`, matched on each row's glyphs
    /// (columns and lengths in cells). Rows are read whole: matches come in reading order of
    /// rows and left to right within a row, and the call stops after the row on which
    /// `o.max_matches` was reached (so it may return a few more). Returns the matches and
    /// the next unread row, or `None` once the scan passed the first or last row.
    pub fn search(
        &self,
        query: &str,
        o: &SearchOpts,
    ) -> Result<(Vec<SearchMatch>, Option<u32>), VtError> {
        let needle = match o.case_sensitive {
            true => query.to_string(),
            // per char, as `RowText::push` folds the rows: `str::to_lowercase` would give a
            // word-final sigma `ς` that no folded row has
            false => query.chars().flat_map(char::to_lowercase).collect(),
        };
        let mut out = Vec::new();
        let mut line = RowText::default();
        let mut row = o.from;
        let mut left = o.max_rows.min(SEARCH_MAX_ROWS);
        if needle.is_empty() {
            return Ok((out, None));
        }
        loop {
            // one lock per SEARCH_LOCK_ROWS rows: the pty reader never waits on a whole call
            let core = lock(&self.core);
            let t = &core.terminal;
            let total = u32::try_from(t.total_rows()?).unwrap_or(u32::MAX);
            if total == 0 || (o.direction == Direction::Forward && row >= total) {
                return Ok((out, None));
            }
            row = row.min(total - 1);
            for _ in 0..SEARCH_LOCK_ROWS {
                line.clear();
                t.for_each_screen_row_cell(row, |wide, cps| {
                    line.push(wide, cps, !o.case_sensitive)
                })?;
                line.matches(&needle, row, &mut out);
                left = left.saturating_sub(1);
                let next = match o.direction {
                    Direction::Forward => row.checked_add(1).filter(|&r| r < total),
                    Direction::Backward => row.checked_sub(1),
                };
                let Some(next) = next else {
                    return Ok((out, None));
                };
                row = next;
                if left == 0 || out.len() >= o.max_matches {
                    return Ok((out, Some(row)));
                }
            }
        }
    }

    pub fn set_colors(&self, c: &Colors) -> Result<(), VtError> {
        let mut core = lock(&self.core);
        let t = &mut core.terminal;
        t.set_default_color(DefaultColor::Foreground, c.fg)?;
        t.set_default_color(DefaultColor::Background, c.bg)?;
        t.set_default_color(DefaultColor::Cursor, c.cursor)?;
        t.reset_default_palette()?;
        if !c.palette.is_empty() {
            let mut palette = t.default_palette()?;
            for &(i, rgb) in &c.palette {
                palette[i as usize] = rgb;
            }
            t.set_default_palette(&palette)?;
        }
        Ok(())
    }

    pub fn set_color_scheme(&self, scheme: Option<ColorScheme>) {
        lock(&self.core).terminal.set_color_scheme(scheme);
    }

    pub fn scrollbar(&self) -> Scrollbar {
        self.snapshot().scrollbar
    }

    pub fn scroll_to(&self, offset: usize) -> Result<u64, VtError> {
        {
            let mut core = lock(&self.core);
            core.terminal.scroll_viewport_row(offset);
            core.dirty_all = true;
        }
        self.try_refresh()
    }

    /// Live read when the core is free, else the snapshot value with `stale = true`.
    fn live_or_snapshot<T>(
        &self,
        live: impl FnOnce(&VtCore) -> T,
        snap: impl FnOnce(&Snapshot) -> T,
    ) -> (T, bool) {
        let core = match self.core.try_lock() {
            Ok(g) => g,
            Err(TryLockError::Poisoned(e)) => e.into_inner(),
            Err(TryLockError::WouldBlock) => return (snap(&self.snapshot()), true),
        };
        (live(&core), false)
    }

    pub fn mode(&self, m: Mode) -> (bool, bool) {
        self.live_or_snapshot(|c| m.read(&c.terminal), |s| s.modes[m as usize])
    }

    pub fn kitty_keyboard_flags(&self) -> (u8, bool) {
        self.live_or_snapshot(
            |c| c.terminal.kitty_keyboard_flags().unwrap_or(0),
            |s| s.kitty_flags,
        )
    }

    pub fn modify_other_keys(&self) -> (bool, bool) {
        self.live_or_snapshot(
            |c| c.terminal.modify_other_keys_enabled().unwrap_or(false),
            |s| s.modify_other_keys,
        )
    }

    pub fn link_at(&self, x: u16, y: u16) -> Option<(String, LinkKind)> {
        match lock(&self.core).terminal.viewport_link_target(x, y as u32) {
            Ok(Some(LinkTarget::Uri(u))) => Some((u, LinkKind::Hyperlink)),
            Ok(Some(LinkTarget::Text { text, .. })) => Some((text, LinkKind::Text)),
            _ => None,
        }
    }

    /// The snapshot's placements (sorted by z); never waits on the core lock.
    pub fn graphics_placements(&self) -> Arc<[Placement]> {
        Arc::clone(&self.snapshot().graphics)
    }

    /// Copies image `id`'s pixels; None when it is gone, unplaced, or has no data.
    /// Ghostty-vt lists no placement for an image still stored compressed, so that is None.
    // ponytail: holds the core lock (stalling the reader) while the pixels are copied; copy
    // from a refcounted image handle outside the lock if large images stall output.
    pub fn graphics_image(&self, id: u32) -> Option<Image> {
        let core = lock(&self.core);
        // one copy under the core lock: a placeholder image yields a placement per row run
        let mut taken = false;
        let ps = core
            .terminal
            .kitty_image_placements_with_data_filter(|d| {
                let take = !taken && d.image_id == id;
                taken |= take;
                take
            })
            .ok()?;
        let p = ps
            .into_iter()
            .find(|p| p.image_id == id && !p.data.is_empty())?;
        Some(Image {
            format: p.format,
            width: p.image_width,
            height: p.image_height,
            data: p.data,
        })
    }

    pub fn cursor(&self) -> Option<Cursor> {
        self.snapshot().cursor
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::{decode_row, Cell, Color};
    use ghostty_vt::{ColorScheme, RgbColor};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    fn vt() -> Arc<Vt> {
        Vt::new(20, 5, 10_000).expect("vt")
    }

    fn row(vt: &Vt, y: usize) -> Vec<Cell> {
        decode_row(&vt.snapshot().rows[y].bytes).expect("decode")
    }

    fn text(cells: &[Cell]) -> String {
        cells
            .iter()
            .map(|c| if c.glyph.is_empty() { " " } else { &c.glyph })
            .collect::<String>()
            .trim_end()
            .to_string()
    }

    fn indexes(rows: &[(u16, Arc<[u8]>)]) -> Vec<u16> {
        rows.iter().map(|(y, _)| *y).collect()
    }

    #[test]
    fn vt_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Vt>();
    }

    #[test]
    fn write_then_refresh_has_text() {
        let vt = vt();
        vt.write(b"hi");
        vt.refresh();
        let cells = row(&vt, 0);
        assert_eq!(cells.len(), 20);
        assert_eq!(cells[0].glyph, "h");
        assert_eq!(cells[1].glyph, "i");
    }

    #[test]
    fn dirty_rows_only_changed() {
        let vt = vt();
        vt.refresh();
        vt.dirty_rows();
        vt.write(b"\x1b[3;1Hx");
        let gen = vt.refresh();
        let (g, rows) = vt.dirty_rows();
        assert_eq!(g, gen);
        assert_eq!(indexes(&rows), vec![2]);
        assert_eq!(decode_row(&rows[0].1).expect("decode")[0].glyph, "x");
        assert_eq!(vt.dirty_rows().1, vec![]);
    }

    #[test]
    fn two_writes_one_refresh_keeps_both_rows() {
        let vt = vt();
        vt.dirty_rows();
        vt.write(b"\x1b[2;1Ha");
        vt.write(b"\x1b[4;1Hb");
        vt.refresh();
        assert_eq!(indexes(&vt.dirty_rows().1), vec![1, 3]);
    }

    #[test]
    fn reset_read_cursor_returns_all_rows() {
        let vt = vt();
        vt.dirty_rows();
        assert_eq!(vt.dirty_rows().1.len(), 0);
        vt.reset_read_cursor();
        assert_eq!(indexes(&vt.dirty_rows().1), vec![0, 1, 2, 3, 4]);
        assert_eq!(vt.full_rows().1.len(), 5);
    }

    #[test]
    fn colors_attrs_wide_link() {
        let vt = vt();
        vt.write(b"\x1b[1;31;48;2;1;2;3m\xe4\xb8\xad\x1b[0m");
        vt.write(b"\x1b]8;;https://example.com\x1b\\ab\x1b]8;;\x1b\\c");
        vt.refresh();
        let cells = row(&vt, 0);
        assert_eq!(cells[0].glyph, "中");
        assert_eq!(cells[0].attrs & 1, 1);
        assert_eq!(cells[0].fg, Color::Palette(1));
        assert_eq!(cells[0].bg, Color::Rgb(1, 2, 3));
        assert_eq!(cells[0].width, 2);
        assert_eq!(cells[0].link, 0);
        assert_eq!(cells[1].width, 0);
        assert_eq!(cells[1].glyph, "");
        assert_eq!((cells[2].glyph.as_str(), cells[2].link), ("a", 1));
        assert_eq!((cells[3].glyph.as_str(), cells[3].link), ("b", 1));
        assert_eq!((cells[4].glyph.as_str(), cells[4].link), ("c", 0));
        assert_eq!(cells[2].fg, Color::Default);
        assert_eq!(cells[2].attrs, 0);
    }

    #[test]
    fn underline_style_in_attrs() {
        let vt = vt();
        vt.write(b"\x1b[4:3;3mu");
        vt.refresh();
        let c = &row(&vt, 0)[0];
        assert_eq!(c.attrs, 1 << 1 | 3 << 8);
    }

    #[test]
    fn mode_stale_when_locked() {
        let vt = vt();
        vt.write(b"\x1b[?2004h");
        vt.refresh();
        assert_eq!(vt.mode(Mode::BracketedPaste), (true, false));
        let (locked_tx, locked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let holder = Arc::clone(&vt);
        let t = std::thread::spawn(move || {
            let _core = lock(&holder.core);
            locked_tx.send(()).expect("send");
            let _ = release_rx.recv();
        });
        locked_rx.recv().expect("locked");
        let start = Instant::now();
        let got = vt.mode(Mode::BracketedPaste);
        let flags = vt.kitty_keyboard_flags();
        assert!(start.elapsed() < Duration::from_millis(1));
        assert_eq!(got, (true, true));
        assert_eq!(flags, (0, true));
        release_tx.send(()).expect("release");
        t.join().expect("join");
    }

    #[test]
    fn mode_names_and_alt_screen() {
        assert_eq!(Mode::from_name("mouse_sgr"), Some(Mode::MouseSgr));
        assert_eq!(Mode::from_name("alt_screen"), Some(Mode::AltScreen));
        assert_eq!(Mode::from_name("nope"), None);
        let vt = vt();
        assert_eq!(vt.mode(Mode::AltScreen), (false, false));
        assert_eq!(vt.mode(Mode::Wraparound), (true, false));
        vt.write(b"\x1b[?1049h\x1b[?1006h");
        assert_eq!(vt.mode(Mode::AltScreen), (true, false));
        assert_eq!(vt.mode(Mode::MouseSgr), (true, false));
        vt.refresh();
        let snap = vt.snapshot();
        assert!(snap.modes[Mode::AltScreen as usize]);
        assert!(snap.modes[Mode::MouseSgr as usize]);
    }

    #[test]
    fn resize_marks_all_dirty() {
        let vt = vt();
        vt.dirty_rows();
        let gen = vt.resize(30, 7, Some((8, 16))).expect("resize");
        let (g, rows) = vt.dirty_rows();
        assert_eq!(g, gen);
        assert_eq!(indexes(&rows), (0..7).collect::<Vec<u16>>());
        assert!(rows
            .iter()
            .all(|(_, r)| decode_row(r).expect("decode").len() == 30));
        assert_eq!(vt.snapshot().cols, 30);
    }

    #[test]
    fn scroll_to_changes_rows() {
        let vt = vt();
        for i in 0..10 {
            vt.write(format!("line{i}\r\n").as_bytes());
        }
        vt.refresh();
        assert_eq!(text(&row(&vt, 0)), "line6");
        let sb = vt.scrollbar();
        assert!(sb.total > sb.viewport);
        assert_eq!(sb.viewport, 5);
        assert_eq!(sb.offset, sb.total - sb.viewport);
        vt.dirty_rows();
        vt.scroll_to(0).expect("scroll");
        assert_eq!(text(&row(&vt, 0)), "line0");
        assert_eq!(vt.scrollbar().offset, 0);
        assert_eq!(vt.dirty_rows().1.len(), 5);
    }

    #[test]
    fn read_text_viewport() {
        let vt = vt();
        vt.write(b"hello\r\nworld");
        let t = vt.read_text(TextRange::Viewport).expect("read");
        assert!(t.starts_with("hello\nworld"), "{t:?}");
        let r = vt.read_text(TextRange::Rows(1, 1)).expect("read");
        assert_eq!(r.trim_end(), "world");
        assert!(vt
            .read_text(TextRange::Screen)
            .expect("read")
            .contains("world"));
    }

    #[test]
    fn link_at_returns_uri() {
        let vt = vt();
        vt.write(b"\x1b]8;;https://example.com\x1b\\ab\x1b]8;;\x1b\\ see http://x.y/z");
        assert_eq!(
            vt.link_at(1, 0),
            Some(("https://example.com".to_string(), LinkKind::Hyperlink))
        );
        assert_eq!(vt.link_at(19, 4), None);
        assert!(matches!(vt.link_at(8, 0), Some((t, LinkKind::Text)) if t == "http://x.y/z"));
    }

    #[test]
    fn cursor_tracks_position() {
        let vt = vt();
        vt.write(b"\x1b[3;7H");
        vt.refresh();
        let c = vt.cursor().expect("cursor");
        assert_eq!((c.x, c.y, c.visible), (6, 2, true));
        assert_eq!(c.shape, CursorShape::Block);
        vt.write(b"\x1b[?25l\x1b[6 q");
        vt.refresh();
        let c = vt.cursor().expect("cursor");
        assert!(!c.visible);
        assert_eq!(c.shape, CursorShape::Bar);
    }

    #[test]
    fn write_effects_and_pty_replies() {
        let vt = vt();
        let (tx, rx) = mpsc::channel();
        vt.set_write_pty(move |b| {
            let _ = tx.send(b.to_vec());
        });
        let fx = vt.write(b"\x07\x07\x1b]7;file://h/tmp\x07\x1b[6n");
        assert_eq!(fx.bells, 2);
        assert_eq!(fx.pwd, vec![b"file://h/tmp".to_vec()]);
        assert_eq!(rx.try_recv().expect("dsr reply"), b"\x1b[1;1R".to_vec());
    }

    fn replies(vt: &Vt) -> mpsc::Receiver<Vec<u8>> {
        let (tx, rx) = mpsc::channel();
        vt.set_write_pty(move |b| {
            let _ = tx.send(b.to_vec());
        });
        rx
    }

    fn drain(rx: &mpsc::Receiver<Vec<u8>>) -> Vec<u8> {
        rx.try_iter().flatten().collect()
    }

    #[test]
    fn set_colors_answers_osc_queries() {
        let vt = vt();
        let rx = replies(&vt);
        vt.write(b"\x1b]10;?\x1b\\\x1b]11;?\x1b\\");
        assert_eq!(drain(&rx), b"", "unset fg/bg get no reply");
        let red = RgbColor { r: 255, g: 0, b: 0 };
        vt.set_colors(&Colors {
            fg: Some(RgbColor { r: 1, g: 2, b: 3 }),
            bg: None,
            cursor: None,
            palette: vec![(1, red)],
        })
        .expect("set_colors");
        vt.write(b"\x1b]10;?\x1b\\");
        assert_eq!(drain(&rx), b"\x1b]10;rgb:0101/0202/0303\x1b\\".to_vec());
        vt.write(b"\x1b]11;?\x1b\\\x1b[c");
        assert_eq!(drain(&rx), b"\x1b[?62;22c".to_vec(), "bg unset: only DA1");
        vt.write(b"\x1b]4;1;?\x1b\\");
        assert_eq!(drain(&rx), b"\x1b]4;1;rgb:ffff/0000/0000\x1b\\".to_vec());
        // Entries not given keep ghostty's built-in default.
        let mut default = Vec::new();
        {
            let fresh = Vt::new(20, 5, 0).expect("vt");
            let frx = replies(&fresh);
            fresh.write(b"\x1b]4;2;?\x1b\\");
            default.extend(drain(&frx));
        }
        vt.write(b"\x1b]4;2;?\x1b\\");
        assert_eq!(drain(&rx), default);
        // None unsets again.
        vt.set_colors(&Colors::default()).expect("unset");
        vt.write(b"\x1b]10;?\x1b\\");
        assert_eq!(drain(&rx), b"");
    }

    #[test]
    fn color_scheme_answers_996() {
        let vt = vt();
        let rx = replies(&vt);
        vt.write(b"\x1b[?996n");
        assert_eq!(drain(&rx), b"");
        vt.set_color_scheme(Some(ColorScheme::Dark));
        vt.write(b"\x1b[?996n");
        assert_eq!(drain(&rx), b"\x1b[?997;1n".to_vec());
        vt.set_color_scheme(Some(ColorScheme::Light));
        vt.write(b"\x1b[?996n");
        assert_eq!(drain(&rx), b"\x1b[?997;2n".to_vec());
    }

    #[test]
    fn read_selection_joins_soft_wraps_and_clamps() {
        let vt = vt();
        // 25 chars on a 20-col vt soft-wraps into a second row.
        vt.write(b"abcdefghijklmnopqrstuvwxy\r\nnext  ");
        assert_eq!(
            vt.read_selection((0, 0), (19, 1)).expect("read"),
            "abcdefghijklmnopqrstuvwxy"
        );
        assert_eq!(vt.read_selection((2, 0), (4, 0)).expect("read"), "cde");
        // Reversed points and out-of-range points clamp.
        assert_eq!(vt.read_selection((999, 999), (0, 2)).expect("read"), "next");
    }

    #[test]
    fn screen_rows_glyphs_widths_and_wrap() {
        let vt = vt();
        vt.write("ab\u{4e16}\r\n".as_bytes());
        vt.write(b"abcdefghijklmnopqrstuvwxy");
        let rows = vt.screen_rows(0, 100).expect("rows");
        assert_eq!(rows.len(), 5, "rows past the end are omitted");
        let (y, packed, wrapped) = &rows[0];
        assert_eq!((*y, *wrapped), (0, false));
        let cells = decode_row(packed).expect("decode");
        assert_eq!(cells.len(), 20);
        let widths: Vec<u8> = cells.iter().map(|c| c.width).collect();
        assert_eq!(&widths[..5], &[1, 1, 2, 0, 1]);
        assert_eq!(cells[2].glyph, "\u{4e16}");
        assert!(cells
            .iter()
            .all(|c| c.fg == Color::Default && c.attrs == 0 && c.link == 0));
        assert!(rows[1].2, "row 1 soft-wraps into row 2");
        assert!(!rows[2].2);
        assert_eq!(text(&decode_row(&rows[2].1).expect("decode")), "uvwxy");
        assert_eq!(vt.screen_rows(3, 3).expect("rows").len(), 1);
        assert!(vt.screen_rows(50, 60).expect("rows").is_empty());
    }

    #[test]
    fn screen_rows_capped_at_1000() {
        let vt = Vt::new(10, 5, 1_000_000).expect("vt");
        for i in 0..1100 {
            vt.write(format!("{i}\r\n").as_bytes());
        }
        let rows = vt.screen_rows(0, 5000).expect("rows");
        assert_eq!(rows.len(), 1000);
        assert_eq!(rows[999].0, 999);
    }

    fn opts(from: u32, direction: Direction) -> SearchOpts {
        SearchOpts {
            max_rows: 20_000,
            max_matches: 1000,
            case_sensitive: true,
            from,
            direction,
        }
    }

    // rows 0..=4 of a 20x5 screen
    fn search_vt() -> Arc<Vt> {
        let vt = vt();
        vt.write(b"foo bar\r\nnone\r\nx bar bar\r\nFOO\r\nbarbar");
        vt
    }

    #[test]
    fn search_forward_and_backward() {
        let vt = search_vt();
        let fwd = vt
            .search("bar", &opts(0, Direction::Forward))
            .expect("search");
        assert_eq!(
            fwd,
            (
                vec![(0, 4, 3), (2, 2, 3), (2, 6, 3), (4, 0, 3), (4, 3, 3)],
                None
            )
        );
        let back = vt
            .search("bar", &opts(2, Direction::Backward))
            .expect("search");
        assert_eq!(back, (vec![(2, 2, 3), (2, 6, 3), (0, 4, 3)], None));
        // `from` past the end: forward is done, backward starts at the last row
        let past = vt
            .search("bar", &opts(99, Direction::Forward))
            .expect("search");
        assert_eq!(past, (vec![], None));
        let back = vt
            .search("bar", &opts(99, Direction::Backward))
            .expect("search");
        assert_eq!(back.0[0], (4, 0, 3));
        assert_eq!(
            vt.search("", &opts(0, Direction::Forward)).expect("search"),
            (vec![], None)
        );
    }

    #[test]
    fn search_case_insensitive() {
        let vt = search_vt();
        let mut o = opts(0, Direction::Forward);
        assert_eq!(vt.search("FOO", &o).expect("search").0, vec![(3, 0, 3)]);
        o.case_sensitive = false;
        assert_eq!(
            vt.search("FOO", &o).expect("search").0,
            vec![(0, 0, 3), (3, 0, 3)]
        );
    }

    #[test]
    fn search_max_matches_stops_after_the_row() {
        let vt = search_vt();
        let o = SearchOpts {
            max_matches: 2,
            ..opts(0, Direction::Forward)
        };
        // row 2 has the second and third match: the whole row comes back
        assert_eq!(
            vt.search("bar", &o).expect("search"),
            (vec![(0, 4, 3), (2, 2, 3), (2, 6, 3)], Some(3))
        );
        let o = SearchOpts {
            max_matches: 1,
            ..opts(3, Direction::Backward)
        };
        assert_eq!(
            vt.search("bar", &o).expect("search"),
            (vec![(2, 2, 3), (2, 6, 3)], Some(1))
        );
    }

    #[test]
    fn search_max_rows_budget() {
        let vt = Vt::new(10, 5, 1_000_000).expect("vt");
        for i in 0..1100 {
            vt.write(format!("{i}\r\n").as_bytes());
        }
        let o = SearchOpts {
            max_rows: 600,
            ..opts(0, Direction::Forward)
        };
        // 600 rows read across lock chunks of 256: rows 0..=599, next 600
        assert_eq!(vt.search("1050", &o).expect("search"), (vec![], Some(600)));
        // the rest reaches the end: done
        let o = SearchOpts { from: 600, ..o };
        assert_eq!(
            vt.search("1050", &o).expect("search"),
            (vec![(1050, 0, 4)], None)
        );
        let o = SearchOpts {
            max_rows: 300,
            ..opts(1050, Direction::Backward)
        };
        assert_eq!(
            vt.search("999", &o).expect("search"),
            (vec![(999, 0, 3)], Some(750))
        );
        let o = SearchOpts {
            max_rows: 10,
            ..opts(5, Direction::Backward)
        };
        assert_eq!(vt.search("3", &o).expect("search"), (vec![(3, 0, 1)], None));
    }

    #[test]
    fn search_max_rows_is_capped() {
        let vt = Vt::new(10, 5, 100_000_000).expect("vt");
        let mut text = String::new();
        for i in 0..SEARCH_MAX_ROWS + 100 {
            text.push_str(&format!("{i}\r\n"));
        }
        vt.write(text.as_bytes());
        let o = SearchOpts {
            max_rows: u32::MAX,
            ..opts(0, Direction::Forward)
        };
        assert_eq!(
            vt.search("absent", &o).expect("search"),
            (vec![], Some(SEARCH_MAX_ROWS))
        );
    }

    #[test]
    fn search_folds_the_query_per_char() {
        let vt = vt();
        vt.write("ΟΔΟΣ".as_bytes());
        let o = SearchOpts {
            case_sensitive: false,
            ..opts(0, Direction::Forward)
        };
        // "ΟΔΟΣ".to_lowercase() is "οδος" (final sigma); the row folds to "οδοσ"
        assert_eq!(vt.search("ΟΔΟΣ", &o).expect("search").0, vec![(0, 0, 4)]);
        assert_eq!(vt.search("οδοσ", &o).expect("search").0, vec![(0, 0, 4)]);
    }

    #[test]
    fn search_wide_chars_count_in_cells() {
        let vt = vt();
        vt.write("\u{4e2d}x \u{4e2d}\u{6587}\r\na\x1b[2;3Hb".as_bytes());
        let o = opts(0, Direction::Forward);
        assert_eq!(vt.search("x", &o).expect("search").0, vec![(0, 2, 1)]);
        assert_eq!(
            vt.search("\u{4e2d}\u{6587}", &o).expect("search").0,
            vec![(0, 4, 4)]
        );
        assert_eq!(
            vt.search("\u{4e2d}", &o).expect("search").0,
            vec![(0, 0, 2), (0, 4, 2)]
        );
        // an empty cell reads as a space
        assert_eq!(vt.search("a b", &o).expect("search").0, vec![(1, 0, 3)]);
    }

    #[test]
    fn modify_other_keys_mode() {
        let vt = vt();
        assert_eq!(vt.modify_other_keys(), (false, false));
        vt.write(b"\x1b[>4;2m");
        assert_eq!(vt.modify_other_keys(), (true, false));
    }

    #[test]
    fn blank_row_is_cols_wide() {
        // build()'s (None, None) arm is unreachable through the public API (a size change
        // forces a full encode), so the helper it calls is tested directly.
        let cells = decode_row(&blank_row(7)).expect("decode");
        assert_eq!(cells.len(), 7);
        assert!(cells.iter().all(|c| c.glyph.is_empty() && c.width == 1));
    }

    #[test]
    fn no_placements_without_images() {
        assert!(vt().graphics_placements().is_empty());
    }

    fn image_vt() -> Arc<Vt> {
        let vt = Vt::new(20, 10, 1000).expect("vt");
        vt.resize(20, 10, Some((10, 20))).expect("resize");
        vt
    }

    // 2x2 RGB, bytes 1..=12.
    const RGB_APC: &[u8] = b"\x1b_Ga=T,f=24,s=2,v=2,i=7,c=4,r=2;AQIDBAUGBwgJCgsM\x1b\\";

    #[test]
    fn placement_has_contract_fields() {
        let vt = image_vt();
        vt.write(RGB_APC);
        vt.refresh();
        let ps = vt.graphics_placements();
        assert_eq!(ps.len(), 1);
        let p = ps[0];
        assert_eq!((p.image_id, p.x, p.y, p.cols, p.rows), (7, 0, 0, 4, 2));
        assert_eq!((p.width, p.height, p.bytes), (2, 2, 12));
        assert_eq!(p.format, KittyImageFormat::Rgb);
        assert_eq!(p.placement_id, u32::MAX);
        let img = vt.graphics_image(7).expect("image");
        assert_eq!(img.data, (1..=12).collect::<Vec<u8>>());
        assert_eq!(
            (img.width, img.height, img.format),
            (2, 2, KittyImageFormat::Rgb)
        );
        assert!(vt.graphics_image(8).is_none());
    }

    #[test]
    fn placement_scrolls_and_returns() {
        let vt = image_vt();
        vt.write(RGB_APC);
        // The cursor ends on the image's last row (1); 9 newlines scroll it up by 1.
        vt.write(&b"\n".repeat(9));
        vt.refresh();
        let ps = vt.graphics_placements();
        assert_eq!(ps.len(), 1);
        assert_eq!((ps[0].y, ps[0].rows), (-1, 2));
        vt.write(&b"\n".repeat(15));
        vt.refresh();
        assert!(vt.graphics_placements().is_empty());
        vt.scroll_to(0).expect("scroll");
        let ps = vt.graphics_placements();
        assert_eq!(ps.len(), 1);
        assert_eq!(ps[0].y, 0);
    }

    #[test]
    fn implicit_placements_get_distinct_ids() {
        let vt = image_vt();
        vt.write(b"\x1b_Ga=t,f=24,s=2,v=2,i=7;AQIDBAUGBwgJCgsM\x1b\\");
        vt.write(b"\x1b_Ga=p,i=7,c=2,r=1\x1b\\\x1b[5;10H\x1b_Ga=p,i=7,c=2,r=1\x1b\\");
        vt.refresh();
        let ps = vt.graphics_placements();
        assert_eq!(ps.len(), 2);
        // ghostty hands implicit placements its internal ids (0, 1, ...); 0 is remapped.
        assert!(ps.iter().all(|p| p.placement_id > 0));
        assert_ne!(ps[0].placement_id, ps[1].placement_id);
        assert!(ps.iter().any(|p| p.placement_id == u32::MAX));
    }

    #[test]
    fn zlib_upload_serves_decompressed_pixels() {
        // ghostty inflates `o=z` on load, so storage never holds compressed data here; a
        // still-compressed image would get no placement from ghostty-vt and so no data.
        let vt = image_vt();
        vt.write(b"\x1b_Ga=T,f=24,o=z,s=2,v=2,i=7,c=4,r=2;eJxjZGJmYWVj5+Dk4uYBAAF4AE8=\x1b\\");
        vt.refresh();
        assert_eq!(vt.graphics_placements()[0].bytes, 12);
        let img = vt.graphics_image(7).expect("image");
        assert_eq!(img.data, (1..=12).collect::<Vec<u8>>());
    }

    #[test]
    fn delete_all_empties_placements() {
        let vt = image_vt();
        vt.write(RGB_APC);
        vt.refresh();
        assert_eq!(vt.graphics_placements().len(), 1);
        vt.write(b"\x1b_Ga=d,d=A\x1b\\");
        vt.refresh();
        assert!(vt.graphics_placements().is_empty());
    }

    #[test]
    fn unicode_placeholder_places_and_packs_as_space() {
        let vt = image_vt();
        vt.write(b"\x1b_Gq=2,a=t,t=d,f=32,s=1,v=1,i=1193046,m=0;/wAA/w==\x1b\\");
        vt.write(b"\x1b_Gq=2,a=p,U=1,i=1193046,c=2,r=1\x1b\\");
        vt.write(
            "\x1b[2;3H\x1b[38;2;18;52;86m\u{10eeee}\u{0305}\u{0305}\u{10eeee}\u{0305}\u{030d}\x1b[0m"
                .as_bytes(),
        );
        vt.refresh();
        let ps = vt.graphics_placements();
        assert_eq!(ps.len(), 1);
        assert_eq!(
            (ps[0].image_id, ps[0].x, ps[0].y, ps[0].cols),
            (1193046, 2, 1, 2)
        );
        assert!(ps[0].placement_id > 0);
        let cells = row(&vt, 1);
        assert_eq!(cells[2].glyph, " ");
        assert_eq!(cells[3].glyph, " ");
    }

    /// What adopt does: restore, feed the carried bytes, then the next resize brings the
    /// cell pixel size back.
    fn adopt(vt: &Vt) -> Arc<Vt> {
        let replay = vt.graphics_replay(16 << 20);
        let vt2 = roundtrip(vt, 1000);
        vt2.write(&replay);
        vt2.resize(20, 10, Some((10, 20))).expect("resize");
        vt2.refresh();
        vt2
    }

    #[test]
    fn snapshot_alone_drops_kitty_images() {
        let vt = image_vt();
        vt.write(RGB_APC);
        vt.refresh();
        assert_eq!(vt.graphics_placements().len(), 1);
        let vt2 = roundtrip(&vt, 1000);
        vt2.resize(20, 10, Some((10, 20))).expect("resize");
        vt2.refresh();
        assert!(vt2.graphics_placements().is_empty());
        assert!(vt2.graphics_image(7).is_none());
    }

    #[test]
    fn graphics_replay_carries_placements_and_pixels() {
        let vt = image_vt();
        vt.write(b"\x1b[3;5H");
        vt.write(RGB_APC);
        // explicit id, offsets, source rect and z; then a second implicit placement
        vt.write(b"\x1b[6;2H\x1b_Ga=p,i=7,p=3,c=2,r=1,x=1,y=0,w=1,h=2,X=2,Y=3,z=-4\x1b\\");
        vt.write(b"\x1b[8;12H\x1b_Ga=p,i=7,c=3,r=1\x1b\\");
        // a unicode-placeholder image
        vt.write(b"\x1b_Gq=2,a=t,t=d,f=32,s=1,v=1,i=1193046,m=0;/wAA/w==\x1b\\");
        vt.write(b"\x1b_Gq=2,a=p,U=1,i=1193046,c=2,r=1\x1b\\");
        vt.write(
            "\x1b[2;3H\x1b[38;2;18;52;86m\u{10eeee}\u{0305}\u{0305}\u{10eeee}\u{0305}\u{030d}\x1b[0m\x1b[9;4H"
                .as_bytes(),
        );
        vt.refresh();
        let before = vt.graphics_placements();
        assert_eq!(before.len(), 4);

        let vt2 = adopt(&vt);
        let sorted = |ps: &[Placement]| {
            let mut v = ps.to_vec();
            v.sort_by_key(|p| (p.image_id, p.placement_id, p.y, p.x));
            v
        };
        assert_eq!(sorted(&vt2.graphics_placements()), sorted(&before));
        assert_eq!(vt2.graphics_image(7), vt.graphics_image(7));
        assert_eq!(vt2.graphics_image(1193046), vt.graphics_image(1193046));
        assert_eq!(vt2.cursor().map(|c| (c.x, c.y)), Some((3, 8)));
    }

    #[test]
    fn graphics_replay_respects_cap_and_skips_off_screen_tops() {
        let vt = image_vt();
        assert!(vt.graphics_replay(16 << 20).is_empty());
        vt.write(RGB_APC);
        vt.refresh();
        assert!(vt.graphics_replay(11).is_empty());
        assert!(!vt.graphics_replay(12).is_empty());
        // scrolled one row off the top: not carried
        vt.write(&b"\n".repeat(9));
        vt.refresh();
        assert_eq!(vt.graphics_placements()[0].y, -1);
        assert!(vt.graphics_replay(16 << 20).is_empty());
    }

    #[test]
    fn graphics_replay_over_budget_image_is_skipped_once_with_all_its_placements() {
        let vt = image_vt();
        vt.write(RGB_APC);
        vt.write(b"\x1b[5;1H\x1b_Ga=p,q=2,i=7,p=2,c=2,r=1\x1b\\");
        vt.write(b"\x1b[7;1H\x1b_Ga=T,q=2,f=24,s=2,v=2,i=8,c=2,r=1;AQIDBAUGBwgJCgsM\x1b\\");
        vt.refresh();
        let s = String::from_utf8(vt.graphics_replay(12)).expect("utf8");
        assert_eq!(s.matches("a=t,").count(), 1, "{s}");
        let carried = if s.contains("a=t,q=2,f=24,s=2,v=2,i=7") {
            7
        } else {
            8
        };
        let other = 15 - carried;
        assert!(!s.contains(&format!("i={other},")), "{s}");
        // the length is known before any copy
        let core = lock(&vt.core);
        let (d, data) = core
            .terminal
            .kitty_image(7, 11)
            .expect("ok")
            .expect("image");
        assert_eq!((d.data_len, data.len()), (12, 0));
    }

    #[test]
    fn graphics_replay_under_origin_mode_carries_virtual_only_and_no_cup() {
        let vt = image_vt();
        vt.write(RGB_APC);
        vt.write(b"\x1b_Gq=2,a=t,t=d,f=32,s=1,v=1,i=9,m=0;/wAA/w==\x1b\\");
        vt.write(b"\x1b_Gq=2,a=p,U=1,i=9,c=2,r=1\x1b\\\x1b[2;5r\x1b[?6h");
        vt.refresh();
        let s = String::from_utf8(vt.graphics_replay(16 << 20)).expect("utf8");
        assert!(s.contains("U=1,i=9") && !s.contains("i=7"), "{s}");
        assert!(!s.contains("\x1b["), "no CUP under origin mode: {s:?}");
    }

    fn roundtrip(vt: &Vt, max: usize) -> Arc<Vt> {
        let bytes = vt.encode_snapshot().expect("encode");
        Vt::restore(&bytes, max).expect("restore")
    }

    #[test]
    fn snapshot_roundtrip_primary_scrollback() {
        let vt = Vt::new(80, 24, 1_000_000).expect("vt");
        for n in 1..=500 {
            vt.write(format!("{n}\r\n").as_bytes());
        }
        let before = vt.read_text(TextRange::Screen).expect("read");
        let vt2 = roundtrip(&vt, 1_000_000);
        let after = vt2.read_text(TextRange::Screen).expect("read");
        assert_eq!(before, after);
        assert!(after.contains("1\n"));
        assert!(after.contains("500"));
    }

    /// Each kill -9 or kernel-restart handoff is one encode/restore trip; history must
    /// survive many of them (m6 task 4d: one page was pruned per trip from trip 18).
    #[test]
    fn snapshot_round_trips_keep_scrollback() {
        const MAX: usize = 10_000_000;
        let lines = |vt: &Vt| {
            vt.read_text(TextRange::Screen)
                .expect("read")
                .lines()
                .filter(|l| l.trim_start().starts_with('L'))
                .count()
        };
        let mut vt = Vt::new(100, 30, MAX).expect("vt");
        for n in 1..=3000 {
            vt.write(format!("L{n}\r\n").as_bytes());
        }
        assert_eq!(lines(&vt), 3000);
        for i in 1..=30 {
            vt = roundtrip(&vt, MAX);
            vt.write(format!("L{}\r\n", 3000 + i).as_bytes());
            assert_eq!(lines(&vt), 3000 + i, "trip {i}");
        }
    }

    #[test]
    fn snapshot_roundtrip_alt_screen() {
        let vt = Vt::new(80, 24, 1_000_000).expect("vt");
        for n in 1..=100 {
            vt.write(format!("{n}\r\n").as_bytes());
        }
        vt.write(b"\x1b[?1049h\x1b[2J\x1b[Hhtop-like");
        let vt2 = roundtrip(&vt, 1_000_000);
        assert!(vt2.mode(Mode::AltScreen).0);
        assert!(vt2
            .read_text(TextRange::Viewport)
            .expect("read")
            .contains("htop-like"));
        vt2.write(b"\x1b[?1049l");
        let view = vt2.read_text(TextRange::Viewport).expect("read");
        assert!(view.lines().any(|l| l.trim_end() == "100"), "{view}");
    }

    #[test]
    fn snapshot_keeps_modes() {
        let vt = vt();
        vt.write(b"\x1b[?2004h\x1b[?1h\x1b[?1006h\x1b[>5u");
        let vt2 = roundtrip(&vt, 10_000);
        for m in [Mode::BracketedPaste, Mode::CursorKeys, Mode::MouseSgr] {
            assert_eq!(vt2.mode(m).0, vt.mode(m).0, "{m:?}");
            assert!(vt2.mode(m).0, "{m:?}");
        }
        assert_eq!(vt2.kitty_keyboard_flags().0, vt.kitty_keyboard_flags().0);
        assert_eq!(vt2.kitty_keyboard_flags().0, 5);
    }

    #[test]
    fn snapshot_keeps_cursor() {
        let vt = Vt::new(80, 24, 10_000).expect("vt");
        vt.write(b"\x1b[5;10H");
        let vt2 = roundtrip(&vt, 10_000);
        let c = vt2.cursor().expect("cursor");
        assert_eq!((c.x, c.y), (9, 4));
        assert_eq!(vt2.full_rows().1.len(), 24);
    }

    #[test]
    fn snapshot_mid_escape() {
        let vt = vt();
        vt.write(b"\x1b[3");
        let vt2 = roundtrip(&vt, 10_000);
        vt2.write(b"1mX");
        vt2.refresh();
        let fresh = self::vt();
        fresh.write(b"\x1b[31mX");
        fresh.refresh();
        let got = row(&vt2, 0);
        assert_eq!(got[0].glyph, "X");
        assert_eq!(got[0].fg, Color::Palette(1));
        assert_eq!(got[0], row(&fresh, 0)[0]);
    }

    #[test]
    fn snapshot_reencode_after_mid_escape_restore() {
        let vt = vt();
        vt.write(b"\x1b[3");
        let vt2 = roundtrip(&vt, 10_000);
        let vt3 = roundtrip(&vt2, 10_000);
        vt3.write(b"1mX");
        vt3.refresh();
        let got = row(&vt3, 0);
        assert_eq!(got[0].glyph, "X");
        assert_eq!(got[0].fg, Color::Palette(1));
    }

    #[test]
    fn restore_garbage_errors() {
        assert!(Vt::restore(b"nope", 1000).is_err());
    }

    #[test]
    fn snapshot_size_and_time() {
        let vt = Vt::new(80, 24, 10_000_000).expect("vt");
        let line = format!("{}\r\n", "x".repeat(79));
        for _ in 0..10_000 {
            vt.write(line.as_bytes());
        }
        let t = Instant::now();
        let bytes = vt.encode_snapshot().expect("encode");
        let encode_us = t.elapsed().as_micros();
        let t = Instant::now();
        let vt2 = Vt::restore(&bytes, 10_000_000).expect("restore");
        let decode_us = t.elapsed().as_micros();
        println!(
            "SNAPSHOT bytes={} encode_us={encode_us} decode_us={decode_us}",
            bytes.len()
        );
        assert_eq!(
            vt2.read_text(TextRange::Screen).expect("read"),
            vt.read_text(TextRange::Screen).expect("read")
        );
    }

    fn strip_sgr(s: &str) -> String {
        let mut out = String::new();
        let mut it = s.chars().peekable();
        while let Some(c) = it.next() {
            if c == '\x1b' {
                for d in it.by_ref() {
                    if d.is_ascii_alphabetic() && d != '[' {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    #[test]
    fn tail_ansi_last_rows() {
        let vt = vt();
        let lines: Vec<String> = (1..=50).map(|i| i.to_string()).collect();
        vt.write(lines.join("\r\n").as_bytes());
        let Ok(Tail::Ansi(t)) = vt.tail_ansi(10) else {
            panic!("not ansi")
        };
        let got: Vec<String> = strip_sgr(&t)
            .replace('\r', "")
            .lines()
            .map(|l| l.trim_end().to_string())
            .collect();
        assert_eq!(got, lines[40..].to_vec(), "{t:?}");
        assert_eq!(vt.tail_ansi(0), Ok(Tail::Ansi(String::new())));
        assert_eq!(vt.tail_ansi(usize::MAX), vt.tail_ansi(MAX_TAIL_ROWS));
        assert_eq!(
            Vt::new(20, 5, 100).expect("vt").tail_ansi(5),
            Ok(Tail::Ansi(String::new()))
        );
    }

    #[test]
    fn tail_ansi_skips_trailing_blank_rows() {
        let vt = vt();
        vt.write(b"a\r\nb\r\n");
        let Ok(Tail::Ansi(t)) = vt.tail_ansi(1) else {
            panic!("not ansi")
        };
        assert_eq!(strip_sgr(&t).trim(), "b", "{t:?}");
    }

    #[test]
    fn tail_ansi_keeps_sgr() {
        let vt = vt();
        vt.write(b"\x1b[31mred\x1b[0m");
        let Ok(Tail::Ansi(t)) = vt.tail_ansi(3) else {
            panic!("not ansi")
        };
        assert!(t.contains("\x1b[") && t.contains("red"), "{t:?}");
    }

    #[test]
    fn tail_ansi_alt_screen() {
        let vt = vt();
        vt.write(b"x\x1b[?1049h");
        assert_eq!(vt.tail_ansi(3), Ok(Tail::AltScreen));
    }
}
