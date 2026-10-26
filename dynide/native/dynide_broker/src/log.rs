//! Timestamped lines on stderr (the launcher points stderr at the log file).
//! Format: `HH:MM:SS.mmm dynide-broker: <msg>` (UTC), so a substring grep for
//! `dynide-broker: <phrase>` matches.

use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn line(msg: std::fmt::Arguments<'_>) {
    emit(format_args!("{msg}"));
}

/// Writes `dynide-event <kind> ts=<ms> k=v ...` (the shared telemetry format).
pub fn write_event(kind: &str, fields: &[(&str, String)]) {
    emit(format_args!("{}", format_event(kind, fields)));
}

const MAX_BYTES: usize = 300;

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis())
}

/// Same rules as `DynideReload.Telemetry`: values matching `^[A-Za-z0-9_.:/@+-]*$`
/// are bare; anything else is double-quoted with `\"` and `\\` escaped, newlines
/// replaced by spaces and the escaped text cut to 300 bytes on a char boundary
/// (never inside an escape pair).
pub fn format_event(kind: &str, fields: &[(&str, String)]) -> String {
    let mut out = format!("dynide-event {kind} ts={}", now_ms());
    for (k, v) in fields {
        out.push(' ');
        out.push_str(k);
        out.push('=');
        out.push_str(&value(v));
    }
    out
}

fn bare(s: &str) -> bool {
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || "_.:/@+-".contains(c))
}

fn value(s: &str) -> String {
    if bare(s) {
        return s.to_string();
    }
    let escaped = s
        .replace("\r\n", " ")
        .replace(['\n', '\r'], " ")
        .replace('\\', "\\\\")
        .replace('"', "\\\"");
    format!("\"{}\"", cut(&escaped))
}

fn cut(s: &str) -> &str {
    if s.len() <= MAX_BYTES {
        return s;
    }
    let mut end = MAX_BYTES;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    let head = &s[..end];
    let trailing = head.len() - head.trim_end_matches('\\').len();
    if trailing % 2 == 1 {
        &head[..head.len() - 1]
    } else {
        head
    }
}

fn emit(msg: std::fmt::Arguments<'_>) {
    let ms = now_ms();
    let s = (ms / 1000) % 86_400;
    let text = format!(
        "{:02}:{:02}:{:02}.{:03} dynide-broker: {msg}\n",
        s / 3600,
        s / 60 % 60,
        s % 60,
        ms % 1000
    );
    // One write(2) per line: the VMs write to the same file, and a line split
    // across writes interleaves with theirs. A full disk or closed stderr must
    // not take the broker down.
    let _ = std::io::stderr().lock().write_all(text.as_bytes());
}

macro_rules! log {
    ($($a:tt)*) => { $crate::log::line(format_args!($($a)*)) };
}
pub(crate) use log;

macro_rules! event {
    ($kind:expr $(, $k:literal => $v:expr)* $(,)?) => {
        $crate::log::write_event($kind, &[$(($k, ($v).to_string())),*])
    };
}
pub(crate) use event;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_has_prefix_ts_and_fields_in_order() {
        let l = format_event(
            "broker_handoff",
            &[("kind", "crash".into()), ("ms", "42".into())],
        );
        assert!(l.starts_with("dynide-event broker_handoff ts="), "{l}");
        assert!(l.ends_with(" kind=crash ms=42"), "{l}");
    }

    #[test]
    fn spaces_quotes_and_backslashes_are_quoted_and_escaped() {
        assert_eq!(value("a b"), "\"a b\"");
        assert_eq!(value("say \"hi\" \\ x"), "\"say \\\"hi\\\" \\\\ x\"");
        assert_eq!(value(""), "");
        assert_eq!(value("a/b:c@d+e-f_g.h"), "a/b:c@d+e-f_g.h");
    }

    #[test]
    fn newlines_become_spaces_and_line_stays_single() {
        let l = format_event("x", &[("r", "a\r\nb\nc\rd".into())]);
        assert!(l.ends_with(" r=\"a b c d\""), "{l}");
        assert!(!l.contains('\n'));
    }

    #[test]
    fn long_values_cut_on_char_boundary_inside_quotes() {
        let v = value(&"é".repeat(400));
        assert!(v.starts_with('"') && v.ends_with('"'));
        assert_eq!(v.len(), 2 + 300);
        let v = value(&format!("{}\"", "a".repeat(299)));
        // the cut would split the escape pair `\"`: the lone backslash is dropped
        assert_eq!(v, format!("\"{}\"", "a".repeat(299)));
    }
}
