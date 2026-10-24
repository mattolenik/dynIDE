//! Host tty output queue: raw writes (bounded FIFO) and frames (latest wins).
//! `tty::Inner` runs the single output thread that drains it, so the
//! encoder's retained frame always matches what reached the host.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::Duration;

/// Cap on raw `write/2` bytes waiting for the output thread.
pub const WRITE_QUEUE_BYTES: usize = 1 << 20;

/// One frame for the encoder. `rows` are `(row index, packed row)`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FrameJob {
    pub rows: Vec<(u16, Vec<u8>)>,
    pub cursor: Option<(u16, u16)>,
    pub shape: u8,
    pub repaint: bool,
}

/// Turns a frame into host bytes; owns the retained frame.
pub trait Encoder {
    /// `None` drops the frame (counted as dropped).
    fn encode(&mut self, job: &FrameJob) -> Option<Vec<u8>>;
    /// Forgets the retained frame so the next one is a full repaint.
    fn reset(&mut self);
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, rustler::NifMap)]
pub struct OutputStats {
    pub frames_written: u64,
    pub frames_dropped: u64,
    pub queued_bytes: usize,
}

/// The write queue is full; nothing was enqueued.
#[derive(Debug, PartialEq, Eq)]
pub struct Backpressure;

enum Item {
    Bytes(Vec<u8>),
    Frame(FrameJob),
}

#[derive(Default)]
struct Queue {
    items: VecDeque<Item>,
    queued_bytes: usize,
    /// Index in `items` of the frame not yet taken by the output thread.
    pending_frame: Option<usize>,
    reset: bool,
    closed: bool,
    frames_written: u64,
    frames_dropped: u64,
}

/// Outcome of flushing one item to the host.
pub enum Flushed {
    Done,
    /// Hard write error: the item is discarded (the reader reports hangups).
    Failed,
}

#[derive(Default)]
pub struct Output {
    queue: Mutex<Queue>,
    ready: Condvar,
}

fn lock(m: &Mutex<Queue>) -> MutexGuard<'_, Queue> {
    // A panicking thread already reported itself; keep using the data.
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Output {
    pub fn new() -> Self {
        Self::default()
    }

    /// Enqueues raw bytes. After `close` they are discarded and this is `Ok`.
    pub fn write(&self, bytes: Vec<u8>) -> Result<(), Backpressure> {
        let mut q = lock(&self.queue);
        if q.closed || bytes.is_empty() {
            return Ok(());
        }
        if q.queued_bytes + bytes.len() > WRITE_QUEUE_BYTES {
            return Err(Backpressure);
        }
        q.queued_bytes += bytes.len();
        q.items.push_back(Item::Bytes(bytes));
        drop(q);
        self.ready.notify_one();
        Ok(())
    }

    /// Queues a frame behind everything already queued. A frame still
    /// pending is replaced (counted dropped) and its `repaint` carried over.
    pub fn submit_frame(&self, mut job: FrameJob) {
        let mut q = lock(&self.queue);
        if q.closed {
            q.frames_dropped += 1;
            return;
        }
        if let Some(index) = q.pending_frame.take() {
            if let Some(Item::Frame(old)) = q.items.remove(index) {
                job.repaint |= old.repaint;
            }
            q.frames_dropped += 1;
        }
        q.pending_frame = Some(q.items.len());
        q.items.push_back(Item::Frame(job));
        drop(q);
        self.ready.notify_one();
    }

    /// Clears the retained frame before the next frame is encoded.
    // Task 4 (suspend/resume) is the first production caller.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn reset_frame(&self) {
        lock(&self.queue).reset = true;
    }

    pub fn stats(&self) -> OutputStats {
        let q = lock(&self.queue);
        OutputStats {
            frames_written: q.frames_written,
            frames_dropped: q.frames_dropped,
            queued_bytes: q.queued_bytes,
        }
    }

    /// Discards everything queued and makes `run` return. Never waits.
    pub fn close(&self) {
        let mut q = lock(&self.queue);
        q.closed = true;
        q.items.clear();
        q.pending_frame = None;
        q.queued_bytes = 0;
        drop(q);
        self.ready.notify_all();
    }

    /// The output thread body: takes one item at a time (the lock is held
    /// only to pop), encodes frames and hands bytes to `flush`. Returns after
    /// `close`, waking at least every `poll` to recheck.
    pub fn run(
        &self,
        encoder: &mut dyn Encoder,
        poll: Duration,
        mut flush: impl FnMut(&[u8]) -> Flushed,
    ) {
        while let Some((item, reset)) = self.next(poll) {
            if reset {
                encoder.reset();
            }
            let written = match item {
                Item::Bytes(bytes) => {
                    flush(&bytes);
                    continue;
                }
                Item::Frame(job) => match encoder.encode(&job) {
                    Some(bytes) => {
                        let done = matches!(flush(&bytes), Flushed::Done);
                        if !done {
                            // The host may hold part of the frame: repaint next time.
                            encoder.reset();
                        }
                        done
                    }
                    None => false,
                },
            };
            let mut q = lock(&self.queue);
            if written {
                q.frames_written += 1;
            } else {
                q.frames_dropped += 1;
            }
        }
    }

    fn next(&self, poll: Duration) -> Option<(Item, bool)> {
        let mut q = lock(&self.queue);
        loop {
            if q.closed {
                return None;
            }
            if let Some(item) = q.items.pop_front() {
                q.pending_frame = q.pending_frame.and_then(|i| i.checked_sub(1));
                if let Item::Bytes(bytes) = &item {
                    q.queued_bytes -= bytes.len();
                }
                let reset = std::mem::take(&mut q.reset);
                return Some((item, reset));
            }
            q = self
                .ready
                .wait_timeout(q, poll)
                .map(|(guard, _)| guard)
                .unwrap_or_else(|poisoned| poisoned.into_inner().0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// Records encode/reset calls; `None` for an empty frame.
    struct Recorder(Vec<&'static str>);

    impl Encoder for Recorder {
        fn encode(&mut self, job: &FrameJob) -> Option<Vec<u8>> {
            self.0.push("encode");
            (!job.rows.is_empty()).then(Vec::new)
        }
        fn reset(&mut self) {
            self.0.push("reset");
        }
    }

    #[test]
    fn reset_frame_resets_encoder_and_none_counts_dropped() {
        let out = Arc::new(Output::new());
        out.reset_frame();
        out.submit_frame(FrameJob::default());
        let runner = Arc::clone(&out);
        let thread = std::thread::spawn(move || {
            let mut rec = Recorder(Vec::new());
            runner.run(&mut rec, Duration::from_millis(10), |_| Flushed::Done);
            rec.0
        });
        while out.stats().frames_dropped == 0 {
            std::thread::yield_now();
        }
        out.close();
        assert_eq!(thread.join().unwrap(), ["reset", "encode"]);
        assert_eq!(out.stats().frames_written, 0);
    }

    #[test]
    fn failed_flush_resets_encoder() {
        let out = Arc::new(Output::new());
        out.submit_frame(FrameJob {
            rows: vec![(0, vec![0])],
            ..FrameJob::default()
        });
        let runner = Arc::clone(&out);
        let thread = std::thread::spawn(move || {
            let mut rec = Recorder(Vec::new());
            runner.run(&mut rec, Duration::from_millis(10), |_| Flushed::Failed);
            rec.0
        });
        while out.stats().frames_dropped == 0 {
            std::thread::yield_now();
        }
        out.close();
        assert_eq!(thread.join().unwrap(), ["encode", "reset"]);
    }
}
