//! Timestamped lines on stderr (the launcher points stderr at the log file).
//! Format: `HH:MM:SS.mmm herdr-broker: <msg>` (UTC), so a substring grep for
//! `herdr-broker: <phrase>` matches.

use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn line(msg: std::fmt::Arguments<'_>) {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    let s = (ms / 1000) % 86_400;
    let text = format!(
        "{:02}:{:02}:{:02}.{:03} herdr-broker: {msg}\n",
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
