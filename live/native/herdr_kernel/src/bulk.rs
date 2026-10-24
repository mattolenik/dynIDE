//! Bulk output demotion for PTY reader threads.
//!
//! A reader that parses a flood (`cat` of a large file) keeps the PTY path busy: the
//! reader's read() and parse plus the child's write() into the tty. Fifteen of those at
//! the BEAM's own thread priority preempt scheduler threads for tens of milliseconds
//! (M6 task 4c: probe overshoot 80 ms with only `script`-driven ptys, no BEAM work).
//! A reader whose output rate stays above `DEMOTE_BYTES` per `WINDOW` is moved to a
//! lower OS priority until a window drops under `PROMOTE_BYTES`; interactive panes
//! (echo, prompts, TUI redraws) never get there and keep the default.

use std::time::{Duration, Instant};

pub const WINDOW: Duration = Duration::from_millis(100);
/// Bytes per window that mark a reader as bulk (2.5 MiB/s); a full 200x50 redraw with
/// colours is about 50 KiB.
pub const DEMOTE_BYTES: usize = 256 * 1024;
/// Bytes per window (as a rate over the closed window, idle included) under which a bulk
/// reader is interactive again (hysteresis: a demoted flood still reads far more).
pub const PROMOTE_BYTES: usize = 32 * 1024;

/// Per-reader rate tracker; `observe` says when to change the thread's priority.
#[derive(Debug)]
pub struct Pacer {
    start: Instant,
    bytes: usize,
    bulk: bool,
}

impl Pacer {
    pub fn new(now: Instant) -> Pacer {
        Pacer {
            start: now,
            bytes: 0,
            bulk: false,
        }
    }

    pub fn bulk(&self) -> bool {
        self.bulk
    }

    /// Records `n` bytes read at `now`; returns `Some(bulk)` when the priority changes.
    /// Call before parsing, so the first read after a quiet spell runs at the default.
    pub fn observe(&mut self, n: usize, now: Instant) -> Option<bool> {
        let was = self.bulk;
        let elapsed = now.duration_since(self.start);
        if elapsed >= WINDOW {
            // The closed window's rate (idle time included) decides promotion.
            let rate_low = (self.bytes as u128) * WINDOW.as_nanos()
                < (PROMOTE_BYTES as u128) * elapsed.as_nanos();
            if self.bulk && rate_low {
                self.bulk = false;
            }
            self.start = now;
            self.bytes = 0;
        }
        self.bytes += n;
        if self.bytes >= DEMOTE_BYTES {
            self.bulk = true;
        }
        (self.bulk != was).then_some(self.bulk)
    }
}

/// Moves the calling thread to the bulk (utility QoS) or interactive (default QoS) class.
#[cfg(target_os = "macos")]
pub fn set_thread_bulk(bulk: bool) {
    use libc::qos_class_t::{QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY};
    let class = if bulk {
        QOS_CLASS_UTILITY
    } else {
        QOS_CLASS_DEFAULT
    };
    // SAFETY: plain syscall wrapper on the calling thread. It fails only for a thread in a
    // workqueue or an invalid class, neither of which applies; the thread then keeps its class.
    let _ = unsafe { libc::pthread_set_qos_class_self_np(class, 0) };
}

// ponytail: no demotion off macOS. Linux would need setpriority(+N) on the thread, and an
// unprivileged thread cannot lower its nice again; measure there before adding it.
#[cfg(not(target_os = "macos"))]
pub fn set_thread_bulk(_bulk: bool) {}

/// The calling thread's QoS class (for tests).
#[cfg(all(test, target_os = "macos"))]
fn qos_self() -> u32 {
    let mut class = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
    let mut prio = 0;
    // SAFETY: valid out pointers for the calling thread.
    unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut class, &mut prio) };
    class as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    const MS: Duration = Duration::from_millis(1);

    #[test]
    fn interactive_output_never_demotes() {
        let t0 = Instant::now();
        let mut p = Pacer::new(t0);
        // a 50 KiB redraw every 10 ms is 500 KiB/s, under the demote rate
        for i in 0..100 {
            let now = t0 + MS * (i * 10);
            let n = if i % 10 == 0 { 50 * 1024 } else { 100 };
            assert_eq!(p.observe(n, now), None, "read {i}");
        }
        assert!(!p.bulk());
    }

    #[test]
    fn flood_demotes_within_a_window_and_stays_demoted() {
        let t0 = Instant::now();
        let mut p = Pacer::new(t0);
        let mut changes = Vec::new();
        // 16 KiB every 2 ms (8 MiB/s), then slowed to 16 KiB every 4 ms while demoted
        for i in 0..200u32 {
            let step = if p.bulk() { 4 } else { 2 };
            let now = t0 + MS * (i * step);
            if let Some(b) = p.observe(16 * 1024, now) {
                changes.push((i, b));
            }
        }
        assert_eq!(changes, vec![(15, true)]);
    }

    #[test]
    fn quiet_window_or_idle_promotes_before_the_next_parse() {
        let t0 = Instant::now();
        let mut p = Pacer::new(t0);
        assert_eq!(p.observe(DEMOTE_BYTES, t0), Some(true));
        // idle 2 s, then a keystroke echo: promoted on that read
        assert_eq!(p.observe(3, t0 + MS * 2000), Some(false));
        assert!(!p.bulk());
        // a trickle under PROMOTE_BYTES per window also promotes
        assert_eq!(p.observe(DEMOTE_BYTES, t0 + MS * 2010), Some(true));
        assert_eq!(p.observe(1024, t0 + MS * 2150), None);
        assert_eq!(p.observe(1024, t0 + MS * 2260), Some(false));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn set_thread_bulk_switches_qos() {
        use libc::qos_class_t::{QOS_CLASS_DEFAULT, QOS_CLASS_UTILITY};
        std::thread::spawn(|| {
            set_thread_bulk(true);
            assert_eq!(qos_self(), QOS_CLASS_UTILITY as u32);
            set_thread_bulk(false);
            assert_eq!(qos_self(), QOS_CLASS_DEFAULT as u32);
        })
        .join()
        .expect("thread");
    }
}
