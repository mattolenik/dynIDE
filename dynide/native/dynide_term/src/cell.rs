//! Packed cell decoder (spec: docs/herdr-live/packed-cells.md). The only
//! Rust code in this crate that knows the row layout.

/// Bytes per record.
pub const RECORD: usize = 32;
const INLINE: usize = 12;
const OVERFLOW: u8 = 0xFF;

/// A cell's grapheme cluster as resolved UTF-8. Equality compares bytes, so
/// an overflow cluster equals itself wherever it sits in the trailer.
#[derive(Debug, Clone)]
pub enum Glyph {
    Inline { len: u8, bytes: [u8; INLINE] },
    Overflow(Box<[u8]>),
}

impl Default for Glyph {
    fn default() -> Self {
        Glyph::Inline {
            len: 0,
            bytes: [0; INLINE],
        }
    }
}

impl Glyph {
    /// The UTF-8 bytes; empty for an empty cell (drawn as a space).
    pub fn as_bytes(&self) -> &[u8] {
        match self {
            Glyph::Inline { len, bytes } => &bytes[..usize::from(*len)],
            Glyph::Overflow(bytes) => bytes,
        }
    }
}

impl PartialEq for Glyph {
    fn eq(&self, other: &Self) -> bool {
        self.as_bytes() == other.as_bytes()
    }
}

impl Eq for Glyph {}

/// One decoded record. Colours are the raw `tag << 24 | payload` u32s.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub glyph: Glyph,
    pub fg: u32,
    pub bg: u32,
    pub ul: u32,
    pub attrs: u16,
    pub width: u8,
    pub link: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellError {
    /// Shorter than the footer, trailer longer than the row, or records not
    /// a multiple of `RECORD`.
    Length,
    /// Overflow ref outside the trailer.
    Overflow,
    Utf8,
    Width,
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

/// Splits a row into `(records, trailer)`, checking the framing.
fn split(row: &[u8]) -> Result<(&[u8], &[u8]), CellError> {
    let body = row.len().checked_sub(4).ok_or(CellError::Length)?;
    let trailer_len = usize::try_from(u32_at(row, body)).map_err(|_| CellError::Length)?;
    let records = body.checked_sub(trailer_len).ok_or(CellError::Length)?;
    if records % RECORD != 0 {
        return Err(CellError::Length);
    }
    Ok((&row[..records], &row[records..body]))
}

/// Column count from the footer, without decoding records.
pub fn cols(row: &[u8]) -> Result<usize, CellError> {
    split(row).map(|(records, _)| records.len() / RECORD)
}

/// Decodes a packed row, resolving overflow clusters.
pub fn decode_row(row: &[u8]) -> Result<Vec<Cell>, CellError> {
    let (records, trailer) = split(row)?;
    records
        .as_chunks::<RECORD>()
        .0
        .iter()
        .map(|rec| decode_record(rec, trailer))
        .collect()
}

fn decode_record(rec: &[u8], trailer: &[u8]) -> Result<Cell, CellError> {
    let glyph = if rec[0] == OVERFLOW {
        let off = usize::try_from(u32_at(rec, 4)).map_err(|_| CellError::Overflow)?;
        let len = usize::try_from(u32_at(rec, 8)).map_err(|_| CellError::Overflow)?;
        let end = off.checked_add(len).ok_or(CellError::Overflow)?;
        let bytes = trailer.get(off..end).ok_or(CellError::Overflow)?;
        std::str::from_utf8(bytes).map_err(|_| CellError::Utf8)?;
        Glyph::Overflow(bytes.into())
    } else {
        let len = rec[..INLINE].iter().position(|&b| b == 0).unwrap_or(INLINE);
        std::str::from_utf8(&rec[..len]).map_err(|_| CellError::Utf8)?;
        let mut bytes = [0; INLINE];
        bytes[..len].copy_from_slice(&rec[..len]);
        Glyph::Inline {
            // len <= 12
            len: len as u8,
            bytes,
        }
    };
    let width = rec[26];
    if width > 2 {
        return Err(CellError::Width);
    }
    Ok(Cell {
        glyph,
        fg: u32_at(rec, 12),
        bg: u32_at(rec, 16),
        ul: u32_at(rec, 20),
        attrs: u16::from_le_bytes([rec[24], rec[25]]),
        width,
        link: u32_at(rec, 28),
    })
}

/// Canonical encoder for tests (production rows come from the kernel).
#[cfg(test)]
pub fn encode_row(cells: &[Cell]) -> Vec<u8> {
    let mut records = Vec::with_capacity(cells.len() * RECORD + 4);
    let mut trailer = Vec::new();
    for c in cells {
        let g = c.glyph.as_bytes();
        if g.len() <= INLINE {
            records.extend_from_slice(g);
            records.resize(records.len() + INLINE - g.len(), 0);
        } else {
            records.extend_from_slice(&[OVERFLOW, 0, 0, 0]);
            records.extend_from_slice(&(trailer.len() as u32).to_le_bytes());
            records.extend_from_slice(&(g.len() as u32).to_le_bytes());
            trailer.extend_from_slice(g);
        }
        for v in [c.fg, c.bg, c.ul] {
            records.extend_from_slice(&v.to_le_bytes());
        }
        records.extend_from_slice(&c.attrs.to_le_bytes());
        records.extend_from_slice(&[c.width, 0]);
        records.extend_from_slice(&c.link.to_le_bytes());
    }
    let len = trailer.len() as u32;
    records.extend_from_slice(&trailer);
    records.extend_from_slice(&len.to_le_bytes());
    records
}

/// A narrow default-styled cell with `glyph` (test helper).
#[cfg(test)]
pub fn text(glyph: &str) -> Cell {
    Cell {
        glyph: glyph_of(glyph.as_bytes()),
        width: 1,
        ..Cell::default()
    }
}

#[cfg(test)]
pub fn glyph_of(g: &[u8]) -> Glyph {
    if g.len() <= INLINE {
        let mut bytes = [0; INLINE];
        bytes[..g.len()].copy_from_slice(g);
        Glyph::Inline {
            len: g.len() as u8,
            bytes,
        }
    } else {
        Glyph::Overflow(g.into())
    }
}

/// A row of narrow default cells, one per char of `s` (test helper).
#[cfg(test)]
pub fn ascii_row(s: &str) -> Vec<u8> {
    let cells: Vec<Cell> = s.chars().map(|c| text(&c.to_string())).collect();
    encode_row(&cells)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const FLAGS: [&str; 8] = [
        "bold",
        "italic",
        "faint",
        "blink",
        "inverse",
        "invisible",
        "strikethrough",
        "overline",
    ];
    const UNDERLINES: [&str; 6] = ["none", "single", "double", "curly", "dotted", "dashed"];

    fn color(v: &Value) -> u32 {
        if v == "default" {
            return 0;
        }
        if let Some(n) = v.get("palette") {
            return 1 << 24 | n.as_u64().unwrap() as u32;
        }
        let rgb: Vec<u32> = v["rgb"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.as_u64().unwrap() as u32)
            .collect();
        2 << 24 | rgb[0] << 16 | rgb[1] << 8 | rgb[2]
    }

    fn cell(v: &Value) -> Cell {
        let mut attrs = 0u16;
        for a in v["attrs"].as_array().unwrap() {
            let bit = FLAGS.iter().position(|f| a == f).unwrap();
            attrs |= 1 << bit;
        }
        let ul = UNDERLINES
            .iter()
            .position(|u| v["underline"] == *u)
            .unwrap();
        Cell {
            glyph: glyph_of(v["glyph"].as_str().unwrap().as_bytes()),
            fg: color(&v["fg"]),
            bg: color(&v["bg"]),
            ul: color(&v["ul"]),
            attrs: attrs | (ul as u16) << 8,
            width: v["width"].as_u64().unwrap() as u8,
            link: v["link"].as_u64().unwrap() as u32,
        }
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn golden_vectors_decode() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../apps/dynide_scene/test/support/packed_cell_vectors.json"
        );
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let vectors = doc["vectors"].as_array().unwrap();
        assert_eq!(vectors.len(), 15);
        for v in vectors {
            let name = v["name"].as_str().unwrap();
            let row = unhex(v["hex"].as_str().unwrap());
            let want: Vec<Cell> = v["cells"].as_array().unwrap().iter().map(cell).collect();
            assert_eq!(decode_row(&row), Ok(want.clone()), "{name}");
            assert_eq!(cols(&row), Ok(want.len()), "{name}");
            assert_eq!(encode_row(&want), row, "{name} encode");
        }
    }

    #[test]
    fn malformed_rows_are_errors() {
        assert_eq!(decode_row(&[0, 0, 0]), Err(CellError::Length));
        // trailer_len > len
        assert_eq!(
            decode_row(&[0, 0, 0, 0, 9, 0, 0, 0]),
            Err(CellError::Length)
        );
        // 5 bytes of records
        assert_eq!(decode_row(&[0; 9]), Err(CellError::Length));
        // overflow ref past the trailer
        let mut row = encode_row(&[text("x".repeat(13).as_str())]);
        row[8] = 14;
        assert_eq!(decode_row(&row), Err(CellError::Overflow));
        // overflow offset near u32::MAX does not wrap
        let mut row = encode_row(&[text("x".repeat(13).as_str())]);
        row[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(decode_row(&row), Err(CellError::Overflow));
        // invalid UTF-8 inline and in overflow
        let mut row = encode_row(&[text("a")]);
        row[0] = 0xC3;
        assert_eq!(decode_row(&row), Err(CellError::Utf8));
        let mut row = encode_row(&[text("x".repeat(13).as_str())]);
        let t = RECORD;
        row[t] = 0xFF;
        assert_eq!(decode_row(&row), Err(CellError::Utf8));
        let mut row = encode_row(&[text("a")]);
        row[26] = 3;
        assert_eq!(decode_row(&row), Err(CellError::Width));
    }

    #[test]
    fn overflow_cells_compare_by_resolved_glyph() {
        let long = "👨‍👩‍👧‍👦";
        let a = decode_row(&encode_row(&[text(long), text("z")])).unwrap();
        let b = decode_row(&encode_row(&[text("y".repeat(13).as_str()), text(long)])).unwrap();
        assert!(matches!(a[0].glyph, Glyph::Overflow(_)));
        assert_eq!(a[0], b[1]);
        assert_ne!(a[0], b[0]);
    }
}
