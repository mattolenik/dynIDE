//! Packed cell codec. Spec: `docs/herdr-live/packed-cells.md`.

pub const RECORD_SIZE: usize = 32;
const GLYPH_BYTES: usize = 12;
const OVERFLOW: u8 = 0xFF;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Default,
    Palette(u8),
    Rgb(u8, u8, u8),
}

impl Color {
    pub fn to_u32(self) -> u32 {
        match self {
            Color::Default => 0,
            Color::Palette(i) => 1 << 24 | i as u32,
            Color::Rgb(r, g, b) => 2 << 24 | (r as u32) << 16 | (g as u32) << 8 | b as u32,
        }
    }

    pub fn from_u32(v: u32) -> Option<Color> {
        match v >> 24 {
            0 => Some(Color::Default),
            1 => Some(Color::Palette(v as u8)),
            2 => Some(Color::Rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)),
            _ => None,
        }
    }
}

/// `attrs` is the raw u16: flag bits 0-7, underline style in bits 8-10.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cell {
    pub glyph: String,
    pub fg: Color,
    pub bg: Color,
    pub ul: Color,
    pub attrs: u16,
    pub width: u8,
    pub link: u32,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// Row shorter than the footer, or length is not `4 + n*32 + trailer_len`.
    BadLength,
    BadColor,
    /// Overflow ref outside the trailer, or malformed ref.
    BadRef,
    BadUtf8,
}

pub struct RowEncoder {
    records: Vec<u8>,
    trailer: Vec<u8>,
}

impl RowEncoder {
    pub fn with_cols(cols: usize) -> Self {
        RowEncoder {
            records: Vec::with_capacity(cols * RECORD_SIZE + 4),
            trailer: Vec::new(),
        }
    }

    #[allow(clippy::too_many_arguments)] // mirrors the record layout field for field
    pub fn push(
        &mut self,
        glyph_utf8: &[u8],
        fg: u32,
        bg: u32,
        ul: u32,
        attrs: u16,
        width: u8,
        link: u32,
    ) {
        // A kitty unicode placeholder (U+10EEEE) is drawn by the graphics pass; the
        // cell itself shows as a space, as in herdr.
        let glyph_utf8 = if glyph_utf8.starts_with("\u{10EEEE}".as_bytes()) {
            b" "
        } else {
            glyph_utf8
        };
        let r = &mut self.records;
        if glyph_utf8.len() <= GLYPH_BYTES {
            r.extend_from_slice(glyph_utf8);
            r.resize(r.len() + GLYPH_BYTES - glyph_utf8.len(), 0);
        } else {
            r.extend_from_slice(&[OVERFLOW, 0, 0, 0]);
            r.extend_from_slice(&(self.trailer.len() as u32).to_le_bytes());
            r.extend_from_slice(&(glyph_utf8.len() as u32).to_le_bytes());
            self.trailer.extend_from_slice(glyph_utf8);
        }
        r.extend_from_slice(&fg.to_le_bytes());
        r.extend_from_slice(&bg.to_le_bytes());
        r.extend_from_slice(&ul.to_le_bytes());
        r.extend_from_slice(&attrs.to_le_bytes());
        r.extend_from_slice(&[width, 0]);
        r.extend_from_slice(&link.to_le_bytes());
    }

    pub fn finish(mut self) -> Vec<u8> {
        self.records.extend_from_slice(&self.trailer);
        self.records
            .extend_from_slice(&(self.trailer.len() as u32).to_le_bytes());
        self.records
    }
}

pub fn encode_row(cells: &[Cell]) -> Vec<u8> {
    let mut e = RowEncoder::with_cols(cells.len());
    for c in cells {
        e.push(
            c.glyph.as_bytes(),
            c.fg.to_u32(),
            c.bg.to_u32(),
            c.ul.to_u32(),
            c.attrs,
            c.width,
            c.link,
        );
    }
    e.finish()
}

fn u32_at(b: &[u8], i: usize) -> u32 {
    let mut a = [0u8; 4];
    a.copy_from_slice(&b[i..i + 4]);
    u32::from_le_bytes(a)
}

pub fn decode_row(row: &[u8]) -> Result<Vec<Cell>, DecodeError> {
    let n = row.len();
    if n < 4 {
        return Err(DecodeError::BadLength);
    }
    let trailer_len = u32_at(row, n - 4) as usize;
    let rec_len = (n - 4)
        .checked_sub(trailer_len)
        .ok_or(DecodeError::BadLength)?;
    if rec_len % RECORD_SIZE != 0 {
        return Err(DecodeError::BadLength);
    }
    let trailer = &row[rec_len..n - 4];
    let color = |v| Color::from_u32(v).ok_or(DecodeError::BadColor);
    let (records, _) = row[..rec_len].as_chunks::<RECORD_SIZE>();
    records
        .iter()
        .map(|r| {
            let g = &r[..GLYPH_BYTES];
            let bytes = if g[0] == OVERFLOW {
                if g[1..4] != [0, 0, 0] {
                    return Err(DecodeError::BadRef);
                }
                let off = u32_at(g, 4) as usize;
                let len = u32_at(g, 8) as usize;
                let end = off.checked_add(len).ok_or(DecodeError::BadRef)?;
                trailer.get(off..end).ok_or(DecodeError::BadRef)?
            } else {
                &g[..g.iter().position(|&b| b == 0).unwrap_or(GLYPH_BYTES)]
            };
            Ok(Cell {
                glyph: std::str::from_utf8(bytes)
                    .map_err(|_| DecodeError::BadUtf8)?
                    .to_string(),
                fg: color(u32_at(r, 12))?,
                bg: color(u32_at(r, 16))?,
                ul: color(u32_at(r, 20))?,
                attrs: u16::from_le_bytes([r[24], r[25]]),
                width: r[26],
                link: u32_at(r, 28),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const VECTORS: &str =
        include_str!("../../../apps/herdr_scene/test/support/packed_cell_vectors.json");

    fn color(v: &Value) -> Color {
        if v == "default" {
            Color::Default
        } else if let Some(i) = v.get("palette") {
            Color::Palette(i.as_u64().unwrap() as u8)
        } else {
            let a = v["rgb"].as_array().unwrap();
            let c = |i: usize| a[i].as_u64().unwrap() as u8;
            Color::Rgb(c(0), c(1), c(2))
        }
    }

    fn cell(v: &Value) -> Cell {
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
        const ULS: [&str; 6] = ["none", "single", "double", "curly", "dotted", "dashed"];
        let mut attrs = 0u16;
        for f in v["attrs"].as_array().unwrap() {
            attrs |= 1 << FLAGS.iter().position(|n| f == n).unwrap();
        }
        attrs |= (ULS.iter().position(|n| v["underline"] == *n).unwrap() as u16) << 8;
        Cell {
            glyph: v["glyph"].as_str().unwrap().to_string(),
            fg: color(&v["fg"]),
            bg: color(&v["bg"]),
            ul: color(&v["ul"]),
            attrs,
            width: v["width"].as_u64().unwrap() as u8,
            link: v["link"].as_u64().unwrap() as u32,
        }
    }

    fn hex_decode(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn golden_vectors_round_trip() {
        let doc: Value = serde_json::from_str(VECTORS).unwrap();
        assert_eq!(doc["record_size"].as_u64().unwrap() as usize, RECORD_SIZE);
        let vectors = doc["vectors"].as_array().unwrap();
        assert_eq!(vectors.len(), 15);
        for v in vectors {
            let name = v["name"].as_str().unwrap();
            let cells: Vec<Cell> = v["cells"].as_array().unwrap().iter().map(cell).collect();
            let bytes = hex_decode(v["hex"].as_str().unwrap());
            assert_eq!(encode_row(&cells), bytes, "encode {name}");
            assert_eq!(decode_row(&bytes), Ok(cells), "decode {name}");
        }
    }

    #[test]
    fn decode_rejects_malformed() {
        assert!(decode_row(&[]).is_err());
        assert!(decode_row(&[0, 0, 0]).is_err());
        assert!(decode_row(&[0; 5]).is_err()); // not 4 + n*32
        let mut bad = vec![0u8; 36];
        bad[0] = 0xFF;
        bad[4..8].copy_from_slice(&0u32.to_le_bytes());
        bad[8..12].copy_from_slice(&5u32.to_le_bytes()); // ref past empty trailer
        assert!(decode_row(&bad).is_err());
    }
}
