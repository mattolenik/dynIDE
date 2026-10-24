//! One ghostty terminal plus a snapshot of packed rows (`docs/herdr-live/packed-cells.md`).
//! Parsing and encoding happen under the core lock; BEAM-facing reads use the snapshot.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, TryLockError};

use ghostty_vt::{
    ActiveScreen, CellColor, CellStyle, CellWide, CursorVisualStyle, Dirty, LinkTarget,
    RenderState, RowCells, RowIterator, Terminal,
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
    pub scrollbar: Scrollbar,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WriteEffects {
    pub bells: u16,
    pub pwd: Vec<Vec<u8>>,
    pub clipboard: Vec<Vec<u8>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextRange {
    Viewport,
    Screen,
    /// Inclusive screen rows.
    Rows(u32, u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkKind {
    Hyperlink,
    Text,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub image_id: u32,
    pub placement_id: u32,
    pub z: i32,
    pub viewport_col: i32,
    pub viewport_row: i32,
    pub grid_cols: u32,
    pub grid_rows: u32,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
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
            scrollbar: Scrollbar {
                total: sb.total,
                viewport: sb.len,
                offset: sb.offset,
            },
        })
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
            scrollbar: Scrollbar::default(),
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

    pub fn link_at(&self, x: u16, y: u16) -> Option<(String, LinkKind)> {
        match lock(&self.core).terminal.viewport_link_target(x, y as u32) {
            Ok(Some(LinkTarget::Uri(u))) => Some((u, LinkKind::Hyperlink)),
            Ok(Some(LinkTarget::Text { text, .. })) => Some((text, LinkKind::Text)),
            _ => None,
        }
    }

    pub fn graphics_placements(&self) -> Vec<Placement> {
        let core = lock(&self.core);
        let Ok(ps) = core
            .terminal
            .kitty_image_placements_with_data_filter(|_| false)
        else {
            return Vec::new();
        };
        ps.iter()
            .map(|p| {
                let r = &p.render;
                Placement {
                    image_id: p.image_id,
                    placement_id: p.placement_id,
                    z: p.z,
                    viewport_col: r.viewport_col,
                    viewport_row: r.viewport_row,
                    grid_cols: r.grid_cols,
                    grid_rows: r.grid_rows,
                    pixel_width: r.pixel_width,
                    pixel_height: r.pixel_height,
                    source_x: r.source_x,
                    source_y: r.source_y,
                    source_width: r.source_width,
                    source_height: r.source_height,
                }
            })
            .collect()
    }

    pub fn cursor(&self) -> Option<Cursor> {
        self.snapshot().cursor
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::{decode_row, Cell, Color};
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
}
