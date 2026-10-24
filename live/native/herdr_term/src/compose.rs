//! Policy-free row assembly for `Compose.frame/4` with `:nif`: joins
//! already-built packed-cell pieces into full screen rows. It knows the
//! packed cell layout and nothing about panes, borders, themes or overlays.
//!
//! Byte-for-byte the Elixir assembler (`Compose.assemble/2` over
//! `Cells.fit/3` and `Cell.concat/1`) for canonical rows: records are copied
//! as bytes and overflow refs are re-pointed into one new trailer in column
//! order, which is what the Elixir decode/encode produces for canonical input.

use crate::cell::{CellError, RECORD};

const OVERFLOW: u8 = 0xFF;
const WIDTH: usize = 26;
/// `Cell.blank_row/1`'s record: empty glyph, default colours, width 1.
const BLANK: [u8; RECORD] = {
    let mut r = [0; RECORD];
    r[WIDTH] = 1;
    r
};

/// Columns `off..off + w` of `row` placed at screen column `x`.
#[derive(Debug, Clone, Copy)]
pub struct Seg<'a> {
    pub x: usize,
    pub w: usize,
    pub row: &'a [u8],
    pub off: usize,
}

fn u32_at(b: &[u8], at: usize) -> usize {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]) as usize
}

/// `(records, trailer)` of a row, checking the framing (overflow refs are
/// checked as they are copied).
fn split(row: &[u8]) -> Result<(&[u8], &[u8]), CellError> {
    let body = row.len().checked_sub(4).ok_or(CellError::Length)?;
    let records = body
        .checked_sub(u32_at(row, body))
        .ok_or(CellError::Length)?;
    if records % RECORD != 0 {
        return Err(CellError::Length);
    }
    Ok((&row[..records], &row[records..body]))
}

/// One output row being built: records plus its trailer.
struct Out {
    records: Vec<u8>,
    trailer: Vec<u8>,
}

impl Out {
    fn new(cols: usize) -> Self {
        Out {
            records: Vec::with_capacity(cols * RECORD + 4),
            trailer: Vec::new(),
        }
    }

    fn blanks(&mut self, n: usize) {
        for _ in 0..n {
            self.records.extend_from_slice(&BLANK);
        }
    }

    /// `Cells.fit(row, off, w)`: blank-padded past the end, a width-0 head
    /// becomes narrow, a wide last cell becomes a blank narrow cell.
    fn fit(&mut self, row: &[u8], off: usize, w: usize) -> Result<(), CellError> {
        let (records, trailer) = split(row)?;
        let cols = records.len() / RECORD;
        let n = w.min(cols.saturating_sub(off));
        let at = self.records.len();
        if n > 0 {
            self.records
                .extend_from_slice(&records[off * RECORD..(off + n) * RECORD]);
            if self.records[at + WIDTH] == 0 {
                self.records[at + WIDTH] = 1;
            }
            let last = at + (n - 1) * RECORD;
            if self.records[last + WIDTH] == 2 {
                self.records[last..last + 12].fill(0);
                self.records[last + WIDTH] = 1;
            }
        }
        // a plain row has no overflow refs: the copy above is the whole job
        if !trailer.is_empty() {
            for rec in self.records[at..].as_chunks_mut::<RECORD>().0 {
                if rec[0] == OVERFLOW {
                    let (o, len) = (u32_at(&rec[..], 4), u32_at(&rec[..], 8));
                    let end = o.checked_add(len).ok_or(CellError::Overflow)?;
                    let bytes = trailer.get(o..end).ok_or(CellError::Overflow)?;
                    let to = u32::try_from(self.trailer.len()).map_err(|_| CellError::Overflow)?;
                    rec[4..8].copy_from_slice(&to.to_le_bytes());
                    self.trailer.extend_from_slice(bytes);
                }
            }
        }
        self.blanks(w - n);
        Ok(())
    }

    fn finish(mut self) -> Result<Vec<u8>, CellError> {
        let len = u32::try_from(self.trailer.len()).map_err(|_| CellError::Overflow)?;
        self.records.extend_from_slice(&self.trailer);
        self.records.extend_from_slice(&len.to_le_bytes());
        Ok(self.records)
    }
}

/// One screen row of exactly `cols` columns from segments sorted by `x`
/// (stable: on equal `x` the earlier segment wins). A segment starting left of
/// the current column is cut to what remains; one ending past `cols` is cut
/// there (the Elixir assembler builds it whole and cuts the row, same bytes).
pub fn assemble(cols: usize, segs: &[Seg]) -> Result<Vec<u8>, CellError> {
    let mut out = Out::new(cols);
    let mut x = 0;
    for s in segs {
        let end = s.x.saturating_add(s.w);
        if s.x >= cols || end <= x {
            continue;
        }
        let from = s.x.max(x);
        out.blanks(from - x);
        let skip = from - s.x;
        out.fit(s.row, s.off.saturating_add(skip), end.min(cols) - from)?;
        x = end.min(cols);
    }
    out.blanks(cols - x);
    out.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cell::{ascii_row, decode_row, encode_row, text, Cell};

    fn seg(x: usize, row: &[u8]) -> Seg<'_> {
        let w = crate::cell::cols(row).unwrap();
        Seg { x, w, row, off: 0 }
    }

    fn glyphs(row: &[u8]) -> String {
        decode_row(row)
            .unwrap()
            .iter()
            .map(|c| match c.glyph.as_bytes() {
                [] => " ".to_string(),
                g => String::from_utf8(g.to_vec()).unwrap(),
            })
            .collect()
    }

    fn wide(g: &str) -> [Cell; 2] {
        let mut head = text(g);
        head.width = 2;
        let tail = Cell {
            width: 0,
            ..text("")
        };
        [head, tail]
    }

    #[test]
    fn joins_pads_and_cuts() {
        let a = ascii_row("abc");
        let b = ascii_row("xyz");
        let row = assemble(8, &[seg(0, &a), seg(5, &b)]).unwrap();
        assert_eq!(glyphs(&row), "abc  xyz");
        // past cols: cut; offset and blank padding past the source end
        let row = assemble(
            4,
            &[
                Seg {
                    x: 0,
                    w: 3,
                    row: &a,
                    off: 1,
                },
                seg(3, &b),
            ],
        )
        .unwrap();
        assert_eq!(glyphs(&row), "bc x");
        // an overlapping later segment keeps only its uncovered tail; one fully covered is skipped
        let row = assemble(6, &[seg(0, &a), seg(1, &b), seg(2, &ascii_row("q"))]).unwrap();
        assert_eq!(glyphs(&row), "abcz  ");
        assert_eq!(assemble(3, &[]).unwrap(), encode_row(&vec![text(""); 3]));
        assert_eq!(assemble(0, &[seg(0, &a)]).unwrap(), vec![0, 0, 0, 0]);
    }

    #[test]
    fn split_wide_chars_become_blank_or_narrow() {
        let mut cells = vec![text("a")];
        cells.extend(wide("日"));
        cells.push(text("b"));
        let row = encode_row(&cells);
        // ends on the head of 日: it becomes an empty narrow cell
        let got = decode_row(&assemble(2, &[seg(0, &row)]).unwrap()).unwrap();
        assert_eq!(got, vec![text("a"), text("")]);
        // starts on the tail of 日: it becomes narrow
        let got = decode_row(
            &assemble(
                2,
                &[Seg {
                    x: 0,
                    w: 2,
                    row: &row,
                    off: 2,
                }],
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(got[0].width, 1);
        assert_eq!(got[1], text("b"));
    }

    #[test]
    fn overflow_refs_are_repointed_into_one_trailer() {
        let long = "x".repeat(13);
        let family = "👨‍👩‍👧‍👦";
        let a = encode_row(&[text(&long), text("a")]);
        let b = encode_row(&[text("b"), text(family)]);
        let row = assemble(5, &[seg(0, &a), seg(2, &b)]).unwrap();
        let want = encode_row(&[text(&long), text("a"), text("b"), text(family), text("")]);
        assert_eq!(row, want);
        // a dropped overflow cell leaves no trailer bytes behind
        let row = assemble(
            2,
            &[
                Seg {
                    x: 0,
                    w: 1,
                    row: &a,
                    off: 1,
                },
                seg(1, &b),
            ],
        )
        .unwrap();
        assert_eq!(row, encode_row(&[text("a"), text("b")]));
    }

    #[test]
    fn malformed_rows_are_errors() {
        assert_eq!(
            assemble(
                2,
                &[Seg {
                    x: 0,
                    w: 1,
                    row: &[0, 0],
                    off: 0
                }]
            ),
            Err(CellError::Length)
        );
        let mut bad = encode_row(&[text(&"x".repeat(13))]);
        bad[8] = 99;
        assert_eq!(assemble(2, &[seg(0, &bad)]), Err(CellError::Overflow));
    }
}
