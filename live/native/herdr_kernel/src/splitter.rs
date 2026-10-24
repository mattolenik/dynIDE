//! Observe-only OSC/DCS splitter. Bytes are never consumed; the caller still
//! hands the same chunk to the terminal. State carries across `observe` calls.

const CAN: u8 = 0x18;
const SUB: u8 = 0x1a;
const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;

const OSC52_CAP: usize = 1024 * 1024;
const OTHER_CAP: usize = 4096;
const MAX_CODE_DIGITS: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Seq {
    Osc {
        code: u32,
        payload: Vec<u8>,
        truncated: bool,
    },
    Dcs {
        payload: Vec<u8>,
        truncated: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Ground,
    Esc,
    Body,
    BodyEsc,
}

#[derive(Debug)]
pub struct Splitter {
    state: State,
    is_dcs: bool,
    /// Non-numeric or overflowing OSC code: skip to the terminator, emit nothing.
    dropped: bool,
    /// OSC only: `;` seen, remaining bytes are payload.
    in_payload: bool,
    digits: usize,
    code: u64,
    cap: usize,
    truncated: bool,
    payload: Vec<u8>,
}

impl Default for Splitter {
    fn default() -> Self {
        Self::new()
    }
}

impl Splitter {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            is_dcs: false,
            dropped: false,
            in_payload: false,
            digits: 0,
            code: 0,
            cap: OTHER_CAP,
            truncated: false,
            payload: Vec::new(),
        }
    }

    pub fn observe(&mut self, bytes: &[u8], out: &mut Vec<Seq>) {
        for &b in bytes {
            self.step(b, out);
        }
    }

    fn step(&mut self, b: u8, out: &mut Vec<Seq>) {
        match self.state {
            State::Ground => {
                if b == ESC {
                    self.state = State::Esc;
                }
            }
            State::Esc => match b {
                b']' => self.begin(false),
                b'P' => self.begin(true),
                ESC => {}
                _ => self.state = State::Ground,
            },
            State::Body => match b {
                BEL if !self.is_dcs => self.finish(out),
                ESC => self.state = State::BodyEsc,
                CAN | SUB => self.state = State::Ground,
                _ => self.push(b),
            },
            State::BodyEsc => {
                if b == b'\\' {
                    self.finish(out);
                } else {
                    // New ESC that is not ST aborts; reprocess this byte after it.
                    self.state = State::Esc;
                    self.step(b, out);
                }
            }
        }
    }

    fn begin(&mut self, is_dcs: bool) {
        self.state = State::Body;
        self.is_dcs = is_dcs;
        self.dropped = false;
        self.in_payload = is_dcs;
        self.digits = 0;
        self.code = 0;
        self.cap = OTHER_CAP;
        self.truncated = false;
        self.payload.clear();
    }

    fn push(&mut self, b: u8) {
        if self.dropped {
            return;
        }
        if !self.in_payload {
            match b {
                b'0'..=b'9' => {
                    self.digits += 1;
                    self.code = self.code * 10 + u64::from(b - b'0');
                    if self.digits > MAX_CODE_DIGITS || self.code > u64::from(u32::MAX) {
                        self.dropped = true;
                    }
                }
                b';' if self.digits > 0 => {
                    self.in_payload = true;
                    if self.code == 52 {
                        self.cap = OSC52_CAP;
                    }
                }
                _ => self.dropped = true,
            }
            return;
        }
        if self.payload.len() < self.cap {
            self.payload.push(b);
        } else {
            self.truncated = true;
        }
    }

    fn finish(&mut self, out: &mut Vec<Seq>) {
        self.state = State::Ground;
        let payload = std::mem::take(&mut self.payload);
        let truncated = self.truncated;
        if self.is_dcs {
            out.push(Seq::Dcs { payload, truncated });
        } else if !self.dropped && self.digits > 0 {
            // `try_from` cannot fail: overflow set `dropped` in `push`.
            if let Ok(code) = u32::try_from(self.code) {
                out.push(Seq::Osc {
                    code,
                    payload,
                    truncated,
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(bytes: &[u8]) -> Vec<Seq> {
        let mut s = Splitter::new();
        let mut out = Vec::new();
        s.observe(bytes, &mut out);
        out
    }

    fn osc(code: u32, p: &[u8]) -> Seq {
        Seq::Osc {
            code,
            payload: p.to_vec(),
            truncated: false,
        }
    }

    #[test]
    fn osc_bel_and_st() {
        assert_eq!(run(b"a\x1b]7;file://h/t\x07b"), vec![osc(7, b"file://h/t")]);
        assert_eq!(run(b"\x1b]8;;http://x\x1b\\"), vec![osc(8, b";http://x")]);
        assert_eq!(run(b"\x1b]9\x07"), vec![osc(9, b"")]);
    }

    #[test]
    fn split_across_chunks() {
        let input = b"x\x1b]52;c;aGk=\x1b\\y\x1b]2;t\x07\x1bP+q544e\x1b\\";
        let mut s = Splitter::new();
        let mut out = Vec::new();
        for b in input {
            s.observe(std::slice::from_ref(b), &mut out);
        }
        assert_eq!(out, run(input));
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], osc(52, b"c;aGk="));
    }

    #[test]
    fn title_code_zero() {
        assert_eq!(run(b"\x1b]0;hello\x07"), vec![osc(0, b"hello")]);
    }

    #[test]
    fn osc52_cap_truncates() {
        let mut input = b"\x1b]52;".to_vec();
        input.extend(std::iter::repeat_n(b'A', OSC52_CAP + 10));
        input.push(BEL);
        let out = run(&input);
        let [Seq::Osc {
            code,
            payload,
            truncated,
        }] = out.as_slice()
        else {
            panic!("expected one osc");
        };
        assert_eq!(*code, 52);
        assert!(*truncated);
        assert_eq!(payload.len(), OSC52_CAP);
    }

    #[test]
    fn generic_cap_4096() {
        let mut input = b"\x1b]99;".to_vec();
        input.extend(std::iter::repeat_n(b'B', 5000));
        input.push(BEL);
        match run(&input).as_slice() {
            [Seq::Osc {
                payload, truncated, ..
            }] => {
                assert!(*truncated);
                assert_eq!(payload.len(), 4096);
            }
            other => panic!("{other:?}"),
        }
        let mut exact = b"\x1b]99;".to_vec();
        exact.extend(std::iter::repeat_n(b'B', 4096));
        exact.push(BEL);
        assert!(matches!(
            run(&exact).as_slice(),
            [Seq::Osc {
                truncated: false,
                ..
            }]
        ));
    }

    #[test]
    fn dcs_payload() {
        assert_eq!(
            run(b"\x1bP+q544e\x1b\\"),
            vec![Seq::Dcs {
                payload: b"+q544e".to_vec(),
                truncated: false
            }]
        );
    }

    #[test]
    fn can_aborts() {
        assert!(run(b"\x1b]0;abc\x18def\x07").is_empty());
        assert!(run(b"\x1b]0;abc\x1adef\x07").is_empty());
        // New ESC that is not ST aborts, and may start a fresh sequence.
        assert_eq!(run(b"\x1b]0;abc\x1b]2;ok\x07"), vec![osc(2, b"ok")]);
        assert!(run(b"\x1bP1\x18x\x1b\\").is_empty());
    }

    #[test]
    fn utf8_0x9d_not_introducer() {
        assert!(run("ŝ text \u{15d}\u{90}".as_bytes()).is_empty());
        assert!(run(b"\xc5\x9d0;x\x07\xc2\x90q\x1b\\").is_empty());
    }

    #[test]
    fn non_numeric_dropped() {
        assert!(run(b"\x1b]abc;x\x07").is_empty());
        assert!(run(b"\x1b];x\x07").is_empty());
        assert!(run(b"\x1b]12abc;x\x07").is_empty());
        assert!(run(b"\x1b]12345678901;x\x07").is_empty());
        assert!(run(b"\x1b]99999999999\x07").is_empty());
        // Dropped sequence does not poison the next one.
        assert_eq!(run(b"\x1b]a;x\x07\x1b]1;y\x07"), vec![osc(1, b"y")]);
    }
}
