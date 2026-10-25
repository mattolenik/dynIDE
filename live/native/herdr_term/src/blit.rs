//! Frame blitting, ported from `src/protocol/render_ansi.rs`: decodes packed
//! rows, diffs them against the retained frame and emits only changed cells.
//!
//! Each frame is wrapped in synchronized output (`CSI ? 2026 h/l`), hides the
//! cursor before any cell write, starts from a known OSC 8 state, and
//! positions the cursor before showing it. After the sync block the final
//! cursor anchor is repeated so IMEs that miss updates inside synchronized
//! output still place their candidate window correctly. Host autowrap is off
//! (`ESC[?7l` at open), so ASCII cells advance inline without spilling.
//! No OSC 8 is emitted (ruling 11): cells carry only link ids.
//! Kitty graphics ops go last inside the sync block, wrapped in `ESC7..ESC8`
//! so their cursor moves leave the final cursor state intact.

use crate::cell::{self, Cell};
use crate::graphics::{self, Files, Transport};
use crate::output::{Encoder, FrameJob};
use std::cmp;
use std::io::Write;
use std::time::Instant;

/// The rows do not form a frame, or a row does not decode.
#[derive(Debug, PartialEq, Eq)]
pub struct BadFrame;

/// Checks rows are `0..h-1` in order, `h >= 1`, and all have the same
/// non-zero column count. Returns `(width, height)`.
pub fn validate_rows(rows: &[(u16, &[u8])]) -> Result<(u16, u16), BadFrame> {
    let height = u16::try_from(rows.len()).map_err(|_| BadFrame)?;
    let mut width = None;
    for (i, (index, row)) in rows.iter().enumerate() {
        let cols = cell::cols(row).map_err(|_| BadFrame)?;
        if usize::from(*index) != i || cols == 0 || width.is_some_and(|w| w != cols) {
            return Err(BadFrame);
        }
        width = Some(cols);
    }
    let width = width.ok_or(BadFrame)?;
    Ok((u16::try_from(width).map_err(|_| BadFrame)?, height))
}

/// What was last written to the host.
struct Frame {
    width: u16,
    height: u16,
    cells: Vec<Cell>,
    /// Packed bytes per row: equal bytes mean equal cells (canonical
    /// encoding), so unchanged rows skip decoding and diffing.
    rows: Vec<Vec<u8>>,
}

/// Stateful encoder that diffs packed frames into terminal bytes.
#[derive(Default)]
pub struct BlitEncoder {
    last: Option<Frame>,
    last_visible_cursor: Option<(u16, u16)>,
    last_cursor_shape: u8,
    /// Survives `reset`: files the host may still read, and the transport state.
    files: Files,
    pub graphics_bytes: u64,
}

impl Encoder for BlitEncoder {
    fn encode(&mut self, job: &FrameJob) -> Option<Vec<u8>> {
        BlitEncoder::encode(self, job).ok()
    }

    fn reset(&mut self) {
        BlitEncoder::reset(self);
    }

    fn graphics_stats(&self) -> (u64, Transport) {
        (self.graphics_bytes, self.files.state())
    }
}

impl BlitEncoder {
    /// Encodes `job` and commits it as the retained frame. On error nothing
    /// is retained or emitted.
    pub fn encode(&mut self, job: &FrameJob) -> Result<Vec<u8>, BadFrame> {
        let rows: Vec<(u16, &[u8])> = job.rows.iter().map(|(i, r)| (*i, r.as_slice())).collect();
        let (width, height) = validate_rows(&rows)?;
        let prev = self
            .last
            .as_ref()
            .filter(|p| !job.repaint && p.width == width && p.height == height);
        // Decode everything first so a bad row drops the frame untouched.
        // `None` = row bytes unchanged.
        let decoded = rows
            .iter()
            .enumerate()
            .map(|(y, (_, row))| match prev {
                Some(p) if p.rows[y] == *row => Ok(None),
                _ => cell::decode_row(row).map(Some),
            })
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| BadFrame)?;

        let mut out = Vec::new();
        let _ = out.write_all(b"\x1b[?2026h\x1b[?25l\x1b]8;;\x1b\\");
        let mut sgr = Sgr::default();
        match prev {
            None => {
                if self.last.is_none() {
                    let _ = out.write_all(b"\x1b[2J");
                }
                for (y, cells) in decoded.iter().enumerate() {
                    if let Some(cells) = cells {
                        write_all_cells(&mut out, y as u16, cells, &mut sgr);
                    }
                }
                let _ = out.write_all(b"\x1b[0m");
            }
            Some(p) => {
                let w = usize::from(width);
                for (y, cells) in decoded.iter().enumerate() {
                    if let Some(cells) = cells {
                        let old = &p.cells[y * w..(y + 1) * w];
                        write_changed_cells(&mut out, y as u16, cells, old, &mut sgr);
                    }
                }
                if sgr.written() {
                    let _ = out.write_all(b"\x1b[0m");
                }
            }
        }

        let cursor = self.resolve_host_cursor_state(job, width, height);
        write_host_cursor_state(&mut out, cursor, &mut self.last_cursor_shape);
        if !job.graphics.is_empty() {
            let start = out.len();
            out.extend_from_slice(b"\x1b7");
            graphics::encode(&mut out, &job.graphics, &mut self.files, Instant::now());
            out.extend_from_slice(b"\x1b8");
            self.graphics_bytes += (out.len() - start) as u64;
        }
        let _ = out.write_all(b"\x1b[?2026l");
        write_ime_anchor_cursor_state(&mut out, cursor);

        self.commit(width, height, &job.rows, decoded);
        Ok(out)
    }

    /// Forgets the retained frame and cursor memory: the next frame clears
    /// and redraws everything (the host was reset to `ESC[0 q`).
    pub fn reset(&mut self) {
        self.last = None;
        self.last_visible_cursor = None;
        self.last_cursor_shape = 0;
    }

    fn commit(
        &mut self,
        width: u16,
        height: u16,
        rows: &[(u16, Vec<u8>)],
        decoded: Vec<Option<Vec<Cell>>>,
    ) {
        let w = usize::from(width);
        let frame = match self.last.take() {
            Some(mut f) if f.width == width && f.height == height => {
                for (y, cells) in decoded.into_iter().enumerate() {
                    if let Some(cells) = cells {
                        f.cells[y * w..(y + 1) * w].clone_from_slice(&cells);
                        f.rows[y].clone_from(&rows[y].1);
                    }
                }
                f
            }
            _ => Frame {
                width,
                height,
                // Full redraws decode every row.
                cells: decoded.into_iter().flatten().flatten().collect(),
                rows: rows.iter().map(|(_, r)| r.clone()).collect(),
            },
        };
        self.last = Some(frame);
    }

    fn resolve_host_cursor_state(
        &mut self,
        job: &FrameJob,
        width: u16,
        height: u16,
    ) -> HostCursorState {
        let clamp = |(x, y): (u16, u16)| (x.min(width - 1), y.min(height - 1));
        match job.cursor {
            Some(position) => {
                let position = clamp(position);
                self.last_visible_cursor = Some(position);
                HostCursorState {
                    position,
                    visible: true,
                    shape: if job.shape <= 6 { job.shape } else { 0 },
                }
            }
            None => HostCursorState {
                position: self
                    .last_visible_cursor
                    .map_or((width - 1, height - 1), clamp),
                visible: false,
                shape: 0,
            },
        }
    }
}

#[derive(Clone, Copy)]
struct HostCursorState {
    position: (u16, u16),
    visible: bool,
    /// DECSCUSR parameter (0–6). 0 means terminal default.
    shape: u8,
}

fn write_cursor_position(out: &mut Vec<u8>, (x, y): (u16, u16)) {
    // CUP is 1-based.
    let _ = write!(out, "\x1b[{};{}H", u32::from(y) + 1, u32::from(x) + 1);
}

fn write_visibility(out: &mut Vec<u8>, visible: bool) {
    let _ = out.write_all(if visible { b"\x1b[?25h" } else { b"\x1b[?25l" });
}

fn write_host_cursor_state(out: &mut Vec<u8>, cursor: HostCursorState, last_shape: &mut u8) {
    write_cursor_position(out, cursor.position);
    if cursor.shape != *last_shape {
        let _ = write!(out, "\x1b[{} q", cursor.shape);
        *last_shape = cursor.shape;
    }
    // Show only once the cursor is at its final position.
    write_visibility(out, cursor.visible);
}

fn write_ime_anchor_cursor_state(out: &mut Vec<u8>, cursor: HostCursorState) {
    write_cursor_position(out, cursor.position);
    write_visibility(out, cursor.visible);
}

// ---------------------------------------------------------------------------
// SGR
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Layer {
    Fg,
    Bg,
    Ul,
}

/// SGR fragment for a packed colour; `None` for a default underline colour
/// (omitted). Unknown tags are the default.
fn color_to_sgr(val: u32, layer: Layer) -> Option<String> {
    let (default, base) = match layer {
        Layer::Fg => (Some("39"), 38),
        Layer::Bg => (Some("49"), 48),
        Layer::Ul => (None, 58),
    };
    match val >> 24 {
        1 => Some(format!("{base};5;{}", val & 0xFF)),
        2 => Some(format!(
            "{base};2;{};{};{}",
            (val >> 16) & 0xFF,
            (val >> 8) & 0xFF,
            val & 0xFF
        )),
        _ => default.map(str::to_owned),
    }
}

/// SGR parameters for packed attrs, in the reference's order (spec bit order
/// differs: bit 0 bold, 1 italic, 2 faint, 3 blink, 4 inverse, 5 invisible,
/// 6 strikethrough, 7 overline; bits 8..10 underline style).
fn modifier_to_sgr_parts(attrs: u16) -> Vec<&'static str> {
    const BEFORE_UNDERLINE: [(u16, &str); 3] = [(1 << 0, "1"), (1 << 2, "2"), (1 << 1, "3")];
    const AFTER_UNDERLINE: [(u16, &str); 5] = [
        (1 << 3, "5"),
        (1 << 4, "7"),
        (1 << 5, "8"),
        (1 << 6, "9"),
        (1 << 7, "53"),
    ];
    let pick = |table: &'static [(u16, &'static str)]| {
        table
            .iter()
            .filter(move |(bit, _)| attrs & bit != 0)
            .map(|(_, part)| *part)
    };
    let mut parts: Vec<&'static str> = pick(&BEFORE_UNDERLINE).collect();
    match (attrs >> 8) & 0x7 {
        0 => {}
        2 => parts.push("4:2"),
        3 => parts.push("4:3"),
        4 => parts.push("4:4"),
        5 => parts.push("4:5"),
        _ => parts.push("4"),
    }
    parts.extend(pick(&AFTER_UNDERLINE));
    parts
}

/// A complete SGR for a cell's style, starting from a reset.
fn build_sgr(cell: &Cell) -> String {
    let mut parts = vec!["0".to_owned()];
    parts.extend(
        modifier_to_sgr_parts(cell.attrs)
            .into_iter()
            .map(str::to_owned),
    );
    parts.extend(color_to_sgr(cell.fg, Layer::Fg));
    parts.extend(color_to_sgr(cell.bg, Layer::Bg));
    parts.extend(color_to_sgr(cell.ul, Layer::Ul));
    format!("\x1b[{}m", parts.join(";"))
}

/// The style last written within a frame.
#[derive(Default)]
struct Sgr {
    style: Option<(u32, u32, u32, u16)>,
    sgr: String,
}

impl Sgr {
    fn written(&self) -> bool {
        !self.sgr.is_empty()
    }
}

// ---------------------------------------------------------------------------
// Cells
// ---------------------------------------------------------------------------

/// Columns a cell covers; a spacer tail (width 0) is never drawn.
fn cell_width(cell: &Cell) -> usize {
    usize::from(cell.width)
}

/// Whether the host cursor lands on the next column after drawing `cell`.
fn advances_inline(cell: &Cell) -> bool {
    cell.width == 1 && drawn_glyph(cell).is_ascii()
}

/// The bytes sent to the host for a cell: a space for an empty glyph or one
/// carrying a C0, DEL or C1 control, so row content can never inject escape
/// sequences into the host terminal. The cell keeps its width.
fn drawn_glyph(cell: &Cell) -> &[u8] {
    let glyph = cell.glyph.as_bytes();
    let control = glyph.iter().any(|&b| b < 0x20 || b == 0x7f)
        // C1 (U+0080..U+009F) is C2 80..C2 9F in UTF-8 (glyphs are valid UTF-8).
        || (!glyph.is_ascii() && glyph.windows(2).any(|w| w[0] == 0xC2 && (0x80..=0x9F).contains(&w[1])));
    if glyph.is_empty() || control {
        b" "
    } else {
        glyph
    }
}

fn write_cell(out: &mut Vec<u8>, cursor_position: Option<(u16, u16)>, cell: &Cell, sgr: &mut Sgr) {
    if let Some(position) = cursor_position {
        write_cursor_position(out, position);
    }
    let style = (cell.fg, cell.bg, cell.ul, cell.attrs);
    if sgr.style != Some(style) {
        let next = build_sgr(cell);
        if next != sgr.sgr {
            let _ = out.write_all(next.as_bytes());
            sgr.sgr = next;
        }
        sgr.style = Some(style);
    }
    let _ = out.write_all(drawn_glyph(cell));
}

/// Writes every cell of row `y` (full redraw).
fn write_all_cells(out: &mut Vec<u8>, y: u16, cells: &[Cell], sgr: &mut Sgr) {
    let mut to_skip = 0usize;
    let mut next_inline_col = None;
    for (x, cell) in cells.iter().enumerate() {
        // Row width was validated to fit u16.
        let x = x as u16;
        if to_skip > 0 {
            to_skip -= 1;
            continue;
        }
        if cell.width == 0 {
            next_inline_col = None;
            continue;
        }
        let cursor_position = (next_inline_col != Some(x)).then_some((x, y));
        write_cell(out, cursor_position, cell, sgr);
        next_inline_col = advances_inline(cell).then_some(x.saturating_add(1));
        to_skip = cell_width(cell).saturating_sub(1);
    }
}

/// Writes the cells of row `y` that differ from `prev`. A cell that was
/// covered by a wide cell (or now is) is redrawn with its own CUP.
fn write_changed_cells(out: &mut Vec<u8>, y: u16, cells: &[Cell], prev: &[Cell], sgr: &mut Sgr) {
    let mut invalidated = 0usize;
    let mut to_skip = 0usize;
    let mut next_inline_col = None;
    for (x, (cell, prev_cell)) in cells.iter().zip(prev).enumerate() {
        // Row width was validated to fit u16.
        let x = x as u16;
        if cell.width != 0 && (cell != prev_cell || invalidated > 0) && to_skip == 0 {
            let cursor_position = (next_inline_col != Some(x) || invalidated > 0).then_some((x, y));
            write_cell(out, cursor_position, cell, sgr);
            next_inline_col = advances_inline(cell).then_some(x.saturating_add(1));
        }
        to_skip = cell_width(cell).saturating_sub(1);
        let affected_width = cmp::max(cell_width(cell), cell_width(prev_cell));
        invalidated = cmp::max(affected_width, invalidated).saturating_sub(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::{ascii_row, encode_row, text, Cell};

    fn job(rows: Vec<Vec<u8>>) -> FrameJob {
        FrameJob {
            rows: rows
                .into_iter()
                .enumerate()
                .map(|(i, r)| (i as u16, r))
                .collect(),
            ..FrameJob::default()
        }
    }

    fn grid(w: usize, h: usize, ch: char) -> Vec<Vec<u8>> {
        vec![ascii_row(&ch.to_string().repeat(w)); h]
    }

    fn s(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes).into_owned()
    }

    fn count(hay: &str, needle: &str) -> usize {
        hay.matches(needle).count()
    }

    fn wide(g: &str) -> [Cell; 2] {
        let mut c = text(g);
        c.width = 2;
        // Default is the empty width-0 spacer tail.
        [c, Cell::default()]
    }

    /// Output with framing stripped: what lies between the OSC 8 reset and
    /// the end of cell writes (the final cursor CUP).
    fn encode(enc: &mut BlitEncoder, j: &FrameJob) -> String {
        s(&enc.encode(j).expect("encode"))
    }

    #[test]
    fn one_cell_change_emits_only_that_cell() {
        let mut enc = BlitEncoder::default();
        encode(&mut enc, &job(grid(80, 24, 'a')));
        let mut rows = grid(80, 24, 'a');
        let mut line: Vec<char> = "a".repeat(80).chars().collect();
        line[10] = 'b';
        rows[5] = ascii_row(&line.iter().collect::<String>());
        let out = encode(&mut enc, &job(rows));
        assert_eq!(count(&out, "b"), 1, "{out:?}");
        assert_eq!(count(&out, "a"), 0, "{out:?}");
        assert_eq!(count(&out, "\x1b[6;11H"), 1, "{out:?}");
        assert!(out.find("\x1b[6;11H").unwrap() < out.find('b').unwrap());
        assert!(out.starts_with("\x1b[?2026h"));
        assert!(out.contains("\x1b[?2026l"));
        assert!(!out.contains("\x1b[2J"));
    }

    #[test]
    fn identical_frame_emits_no_cells() {
        let mut enc = BlitEncoder::default();
        encode(&mut enc, &job(grid(4, 2, 'a')));
        let out = encode(&mut enc, &job(grid(4, 2, 'a')));
        assert_eq!(
            out,
            "\x1b[?2026h\x1b[?25l\x1b]8;;\x1b\\\x1b[2;4H\x1b[?25l\x1b[?2026l\x1b[2;4H\x1b[?25l"
        );
    }

    #[test]
    fn first_frame_clears_and_draws_all() {
        let mut enc = BlitEncoder::default();
        let out = encode(&mut enc, &job(vec![ascii_row("ab"), ascii_row("cd")]));
        assert_eq!(
            out,
            "\x1b[?2026h\x1b[?25l\x1b]8;;\x1b\\\x1b[2J\
             \x1b[1;1H\x1b[0;39;49mab\x1b[2;1Hcd\x1b[0m\
             \x1b[2;2H\x1b[?25l\x1b[?2026l\x1b[2;2H\x1b[?25l"
        );
    }

    #[test]
    fn repaint_flag_forces_full() {
        let mut enc = BlitEncoder::default();
        encode(&mut enc, &job(grid(3, 2, 'a')));
        let mut j = job(grid(3, 2, 'a'));
        j.repaint = true;
        let out = encode(&mut enc, &j);
        assert_eq!(count(&out, "a"), 6, "{out:?}");
        assert!(!out.contains("\x1b[2J"), "clear only after reset");
        enc.reset();
        let out = encode(&mut enc, &job(grid(3, 2, 'a')));
        assert_eq!(count(&out, "a"), 6);
        assert!(out.contains("\x1b[2J"));
    }

    #[test]
    fn resize_forces_full() {
        let mut enc = BlitEncoder::default();
        encode(&mut enc, &job(grid(3, 2, 'a')));
        let out = encode(&mut enc, &job(grid(4, 2, 'a')));
        assert_eq!(count(&out, "a"), 8, "{out:?}");
        let out = encode(&mut enc, &job(grid(4, 3, 'a')));
        assert_eq!(count(&out, "a"), 12, "{out:?}");
        let out = encode(&mut enc, &job(grid(1, 1, 'a')));
        assert_eq!(count(&out, "a"), 1, "{out:?}");
    }

    #[test]
    fn bad_frames_are_errors_and_keep_retained() {
        let mut enc = BlitEncoder::default();
        encode(&mut enc, &job(grid(3, 2, 'a')));
        assert!(enc
            .encode(&job(vec![ascii_row("abc"), ascii_row("ab")]))
            .is_err());
        let mut bad = ascii_row("abc");
        bad[0] = 0xC3;
        assert!(enc.encode(&job(vec![ascii_row("abc"), bad])).is_err());
        let out = encode(&mut enc, &job(grid(3, 2, 'a')));
        assert_eq!(count(&out, "a"), 0, "retained frame unchanged: {out:?}");
    }

    #[test]
    fn cursor_hidden_before_cells_shown_after_position() {
        let mut enc = BlitEncoder::default();
        let mut j = job(grid(5, 3, 'a'));
        j.cursor = Some((2, 1));
        let out = encode(&mut enc, &j);
        let hide = out.find("\x1b[?25l").unwrap();
        let first_cell = out.find('a').unwrap();
        let cup = out.rfind("\x1b[2;3H\x1b[?25h\x1b[?2026l").unwrap();
        assert!(hide < first_cell && first_cell < cup, "{out:?}");
        assert!(out.ends_with("\x1b[?2026l\x1b[2;3H\x1b[?25h"), "{out:?}");
        // Clamped into the frame.
        j.cursor = Some((99, 99));
        let out = encode(&mut enc, &j);
        assert!(out.contains("\x1b[3;5H\x1b[?25h"), "{out:?}");
    }

    #[test]
    fn decscusr_only_on_shape_change() {
        let mut enc = BlitEncoder::default();
        let mut j = job(grid(2, 1, 'a'));
        j.cursor = Some((0, 0));
        j.shape = 6;
        assert!(encode(&mut enc, &j).contains("\x1b[1;1H\x1b[6 q\x1b[?25h"));
        assert!(!encode(&mut enc, &j).contains(" q"));
        j.shape = 2;
        assert_eq!(count(&encode(&mut enc, &j), "\x1b[2 q"), 1);
        j.shape = 0;
        assert_eq!(count(&encode(&mut enc, &j), "\x1b[0 q"), 1);
        // Out-of-range shape is the terminal default.
        j.shape = 2;
        encode(&mut enc, &j);
        j.shape = 9;
        assert_eq!(count(&encode(&mut enc, &j), "\x1b[0 q"), 1);
    }

    #[test]
    fn nil_cursor_parks_hidden() {
        let mut enc = BlitEncoder::default();
        let out = encode(&mut enc, &job(grid(3, 2, 'a')));
        assert!(
            out.contains("\x1b[2;3H\x1b[?25l\x1b[?2026l"),
            "bottom-right: {out:?}"
        );
        let mut j = job(grid(3, 2, 'a'));
        j.cursor = Some((1, 0));
        j.shape = 4;
        encode(&mut enc, &j);
        let out = encode(&mut enc, &job(grid(3, 2, 'a')));
        assert!(
            out.ends_with("\x1b[1;2H\x1b[0 q\x1b[?25l\x1b[?2026l\x1b[1;2H\x1b[?25l"),
            "parks at last visible, shape reset: {out:?}"
        );
    }

    #[test]
    fn wide_cell_change_redraws_neighbour() {
        let mut enc = BlitEncoder::default();
        let [w, t] = wide("中");
        let wide_row = encode_row(&[w, t, text("z")]);
        let narrow_row = encode_row(&[text("a"), text(" "), text("z")]);
        let out = encode(&mut enc, &job(vec![wide_row.clone()]));
        assert!(
            out.contains("\x1b[1;1H\x1b[0;39;49m中\x1b[1;3Hz"),
            "{out:?}"
        );
        // wide -> narrow: both columns redrawn, each with its own CUP.
        let out = encode(&mut enc, &job(vec![narrow_row.clone()]));
        assert!(out.contains("\x1b[1;1H\x1b[0;39;49ma\x1b[1;2H "), "{out:?}");
        assert!(!out.contains('z'), "{out:?}");
        // narrow -> wide: the wide glyph, spacer skipped.
        let out = encode(&mut enc, &job(vec![wide_row]));
        assert!(out.contains("\x1b[1;1H\x1b[0;39;49m中\x1b[0m"), "{out:?}");
        assert!(!out.contains("\x1b[1;2H"), "{out:?}");
    }

    #[test]
    fn adjacent_ascii_changes_share_one_cup() {
        let mut enc = BlitEncoder::default();
        encode(&mut enc, &job(vec![ascii_row("aaaaa")]));
        let out = encode(&mut enc, &job(vec![ascii_row("abbba")]));
        assert!(out.contains("\x1b[1;2H\x1b[0;39;49mbbb\x1b[0m"), "{out:?}");
        assert_eq!(
            count(&out, "H"),
            3,
            "one cell CUP plus two cursor CUPs: {out:?}"
        );
        // A non-ASCII narrow cell breaks the inline run.
        let out = encode(&mut enc, &job(vec![ascii_row("aéxba")]));
        assert!(
            out.contains("\x1b[1;2H\x1b[0;39;49mé\x1b[1;3Hx\x1b[0m"),
            "{out:?}"
        );
    }

    #[test]
    fn overflow_rows_at_different_offsets_diff_equal() {
        let long = "👨‍👩‍👧‍👦";
        let mut enc = BlitEncoder::default();
        let [w, t] = wide(long);
        let [w2, t2] = wide(long);
        encode(&mut enc, &job(vec![encode_row(&[text("a"), w, t])]));
        let b = text("b".repeat(13).as_str());
        let out = encode(&mut enc, &job(vec![encode_row(&[b, w2, t2])]));
        assert!(!out.contains(long), "{out:?}");
        assert_eq!(count(&out, &"b".repeat(13)), 1, "{out:?}");
    }

    #[test]
    fn styles_change_sgr_once_per_run() {
        let mut enc = BlitEncoder::default();
        let mut red = text("r");
        red.fg = 1 << 24 | 1;
        red.attrs = 1 | 3 << 8;
        let out = encode(
            &mut enc,
            &job(vec![encode_row(&[red.clone(), red, text("p")])]),
        );
        assert!(
            out.contains("\x1b[1;1H\x1b[0;1;4:3;38;5;1;49mrr\x1b[0;39;49mp\x1b[0m"),
            "{out:?}"
        );
    }

    #[test]
    fn control_glyphs_are_drawn_as_space() {
        for evil in ["\x1b]52;c;x\x07", "\u{9b}31m", "a\x7f"] {
            let mut enc = BlitEncoder::default();
            let row = encode_row(&[text("a"), text(evil), text("b")]);
            let out = encode(&mut enc, &job(vec![row]));
            assert!(out.contains("\x1b[0;39;49ma b\x1b[0m"), "{evil:?}: {out:?}");
            assert!(!out.contains("]52") && !out.contains('\u{9b}') && !out.contains('\x07'));
            assert!(!out.contains('\x7f'), "{evil:?}: {out:?}");
        }
        // Non-control multibyte glyphs (C2 A0 and up) are kept.
        let mut enc = BlitEncoder::default();
        let out = encode(&mut enc, &job(vec![encode_row(&[text("\u{a9}")])]));
        assert!(out.contains('\u{a9}'), "{out:?}");
    }

    #[test]
    fn validate_rows_shapes() {
        let a: &[u8] = &ascii_row("abc");
        let b: &[u8] = &ascii_row("ab");
        assert_eq!(validate_rows(&[(0, a), (1, a)]), Ok((3, 2)));
        assert_eq!(validate_rows(&[]), Err(BadFrame), "empty");
        assert_eq!(validate_rows(&[(0, a), (2, a)]), Err(BadFrame), "gap");
        assert_eq!(validate_rows(&[(1, a), (0, a)]), Err(BadFrame), "unsorted");
        assert_eq!(validate_rows(&[(1, a)]), Err(BadFrame), "not from 0");
        assert_eq!(validate_rows(&[(0, a), (1, b)]), Err(BadFrame), "unequal");
        assert_eq!(
            validate_rows(&[(0, &[0u8; 9][..])]),
            Err(BadFrame),
            "record multiple"
        );
        assert_eq!(
            validate_rows(&[(0, &[0u8; 4][..])]),
            Err(BadFrame),
            "zero columns"
        );
    }

    #[test]
    fn color_to_sgr_fg_default_palette_rgb() {
        assert_eq!(color_to_sgr(0, Layer::Fg).as_deref(), Some("39"));
        assert_eq!(
            color_to_sgr(0x01_00_00_AB, Layer::Fg).as_deref(),
            Some("38;5;171")
        );
        assert_eq!(
            color_to_sgr(0x02_FF_80_40, Layer::Fg).as_deref(),
            Some("38;2;255;128;64")
        );
        assert_eq!(
            color_to_sgr(0x07_00_00_01, Layer::Fg).as_deref(),
            Some("39")
        );
    }

    #[test]
    fn color_to_sgr_bg_and_ul() {
        assert_eq!(color_to_sgr(0, Layer::Bg).as_deref(), Some("49"));
        assert_eq!(
            color_to_sgr(0x01_00_00_00, Layer::Bg).as_deref(),
            Some("48;5;0")
        );
        assert_eq!(
            color_to_sgr(0x02_FF_80_40, Layer::Bg).as_deref(),
            Some("48;2;255;128;64")
        );
        assert_eq!(color_to_sgr(0, Layer::Ul), None);
        assert_eq!(
            color_to_sgr(0x01_00_00_05, Layer::Ul).as_deref(),
            Some("58;5;5")
        );
        assert_eq!(
            color_to_sgr(0x02_01_02_03, Layer::Ul).as_deref(),
            Some("58;2;1;2;3")
        );
    }

    #[test]
    fn modifier_to_sgr_parts_each_flag() {
        assert!(modifier_to_sgr_parts(0).is_empty());
        let all = modifier_to_sgr_parts(0xFF | 1 << 8);
        assert_eq!(all, ["1", "2", "3", "4", "5", "7", "8", "9", "53"]);
        assert_eq!(modifier_to_sgr_parts(1 << 1), ["3"], "italic");
        assert_eq!(modifier_to_sgr_parts(1 << 2), ["2"], "faint");
        for (style, part) in [(2, "4:2"), (3, "4:3"), (4, "4:4"), (5, "4:5")] {
            assert_eq!(modifier_to_sgr_parts(style << 8), [part]);
        }
    }

    #[test]
    fn build_sgr_produces_valid_sequence() {
        let cell = Cell {
            fg: 1 << 24 | 1,
            bg: 2 << 24 | 0x10_20_30,
            ul: 1 << 24 | 9,
            attrs: 1,
            ..Cell::default()
        };
        assert_eq!(build_sgr(&cell), "\x1b[0;1;38;5;1;48;2;16;32;48;58;5;9m");
    }

    #[test]
    fn build_sgr_resets_previous_modifiers_when_cell_is_plain() {
        assert_eq!(build_sgr(&Cell::default()), "\x1b[0;39;49m");
    }

    #[test]
    fn graphics_ops_go_inside_sync_after_cells_wrapped_in_decsc() {
        use crate::graphics::Op;
        let mut enc = BlitEncoder::default();
        let mut j = job(vec![ascii_row("ab")]);
        j.graphics = vec![Op::DeleteImage(3)];
        let out = encode(&mut enc, &j);
        let ops = "\x1b7\x1b_Ga=d,d=I,i=3,q=2;\x1b\\\x1b8";
        let at = out.find(ops).expect("ops wrapped in ESC7..ESC8");
        assert!(out.rfind('b').unwrap() < at, "{out:?}");
        assert_eq!(&out[at + ops.len()..at + ops.len() + 8], "\x1b[?2026l");
        // No cell changed: the ops are still emitted.
        let out = encode(&mut enc, &j);
        assert!(!out.contains('b') && out.contains(ops), "{out:?}");
        // No ops: no DECSC.
        assert!(!encode(&mut enc, &job(vec![ascii_row("ab")])).contains("\x1b7"));
        assert_eq!(enc.graphics_bytes, 2 * ops.len() as u64);
    }
}
