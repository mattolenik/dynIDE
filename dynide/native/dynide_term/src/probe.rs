//! Parser for the host replies to the startup probe (`CSI ? u`, `CSI c`).
//! Port of herdr's `consume_host_keyboard_probe_responses` without DECRPM 1016.

/// What the probe learned so far.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ProbeState {
    /// Kitty keyboard flags from `CSI ? flags u`, recorded only before DA1.
    pub flags: Option<u16>,
    /// A primary device attributes reply (`CSI ? ... c`) arrived.
    pub da1_seen: bool,
}

const PASTE_START: &[u8] = b"\x1b[200~";
const PASTE_END: &[u8] = b"\x1b[201~";

/// Removes recognized probe replies from `buf`, leaving user input (including
/// bracketed paste payloads and control strings) untouched. An incomplete
/// sequence at the end is kept so the next read can complete it.
pub fn parse(buf: &mut Vec<u8>, state: &mut ProbeState) {
    let mut offset = 0;
    while offset < buf.len() {
        if buf[offset..].starts_with(PASTE_START) {
            let payload_start = offset + PASTE_START.len();
            let Some(rel_end) = buf[payload_start..]
                .windows(PASTE_END.len())
                .position(|bytes| bytes == PASTE_END)
            else {
                break;
            };
            offset = payload_start + rel_end + PASTE_END.len();
            continue;
        }
        if let Some(end) = control_string_end(&buf[offset..]) {
            let Some(end) = end else {
                break;
            };
            offset += end;
            continue;
        }
        if !buf[offset..].starts_with(b"\x1b[?") {
            offset += 1;
            continue;
        }

        let start = offset;
        let mut end = start + 3;
        while end < buf.len() && (buf[end].is_ascii_digit() || buf[end] == b';') {
            end += 1;
        }
        if end == buf.len() {
            break;
        }
        let body = &buf[start + 3..end];
        let recognized = match buf[end] {
            b'u' if !body.is_empty() && body.iter().all(u8::is_ascii_digit) => {
                std::str::from_utf8(body)
                    .ok()
                    .and_then(|flags| flags.parse().ok())
                    .map(|flags| {
                        if !state.da1_seen {
                            state.flags = Some(flags);
                        }
                    })
                    .is_some()
            }
            b'c' if !body.is_empty() => {
                state.da1_seen = true;
                true
            }
            _ => false,
        };
        if recognized {
            buf.drain(start..=end);
        } else {
            offset += 1;
        }
    }
}

/// `Some(Some(len))` for a complete OSC/DCS/APC/PM/SOS string at the start of
/// `bytes`, `Some(None)` when one is started but unterminated, `None` otherwise.
fn control_string_end(bytes: &[u8]) -> Option<Option<usize>> {
    if bytes.first() != Some(&0x1b) {
        return None;
    }
    let allow_bel = if bytes.starts_with(b"\x1b]") {
        true
    } else if bytes
        .get(1)
        .is_some_and(|byte| matches!(*byte, b'P' | b'_' | b'^' | b'X'))
    {
        false
    } else {
        return None;
    };
    for offset in 2..bytes.len() {
        if allow_bel && bytes[offset] == 0x07 {
            return Some(Some(offset + 1));
        }
        if bytes[offset..].starts_with(b"\x1b\\") {
            return Some(Some(offset + 2));
        }
    }
    Some(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_flags_and_da1_and_removes_them() {
        let mut buf = b"a\x1b[?15u\x1b[?62;22cb".to_vec();
        let mut st = ProbeState::default();
        parse(&mut buf, &mut st);
        assert_eq!(st.flags, Some(15));
        assert!(st.da1_seen);
        assert_eq!(buf, b"ab");
    }

    #[test]
    fn bracketed_paste_is_untouched() {
        let mut buf = b"\x1b[200~\x1b[?1u\x1b[c\x1b[201~\x1b[?3u".to_vec();
        let mut st = ProbeState::default();
        parse(&mut buf, &mut st);
        assert_eq!(buf, b"\x1b[200~\x1b[?1u\x1b[c\x1b[201~");
        assert_eq!(st.flags, Some(3));
        assert!(!st.da1_seen);
    }

    #[test]
    fn flags_only_recorded_before_da1() {
        let mut buf = b"\x1b[?62c\x1b[?1u".to_vec();
        let mut st = ProbeState::default();
        parse(&mut buf, &mut st);
        assert!(st.da1_seen);
        assert_eq!(st.flags, None);
        assert!(buf.is_empty());
    }

    #[test]
    fn incomplete_reply_is_kept_for_next_read() {
        let mut buf = b"x\x1b[?1".to_vec();
        let mut st = ProbeState::default();
        parse(&mut buf, &mut st);
        assert_eq!(buf, b"x\x1b[?1");
        buf.extend_from_slice(b"u");
        parse(&mut buf, &mut st);
        assert_eq!(buf, b"x");
        assert_eq!(st.flags, Some(1));
    }

    #[test]
    fn decrpm_is_not_consumed() {
        let mut buf = b"\x1b[?1016;2$y".to_vec();
        let mut st = ProbeState::default();
        parse(&mut buf, &mut st);
        assert_eq!(buf, b"\x1b[?1016;2$y");
    }
}
