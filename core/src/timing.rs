//! Monotonic clock and NTP-style clock sync over PING/PONG (protocol.md §6.3, §8).

use std::sync::OnceLock;
use std::time::Instant;

/// Core's clock in µs. Platforms convert capture timestamps into it (see lenny_now_us).
/// Epoch is arbitrary (first call, shifted so values are never near 0: 0 means "unknown" in the ABI).
pub fn now_us() -> i64 {
    static BASE: OnceLock<Instant> = OnceLock::new();
    const SHIFT_US: i64 = 1_000_000_000_000; // ~11.6 days
    BASE.get_or_init(Instant::now).elapsed().as_micros() as i64 + SHIFT_US
}

#[derive(Clone, Copy, Default)]
struct Sample {
    rtt: i64,
    offset: i64,
    used: bool,
}

/// Keeps the last 16 samples and trusts the one with the lowest RTT: queueing only ever adds delay,
/// so the fastest round trip has the least asymmetric error.
#[derive(Clone, Default)]
pub struct ClockSync {
    samples: [Sample; 16],
    next: usize,
}

impl ClockSync {
    /// t1 = our send, t2 = their receive, t3 = their send (their clock), t4 = our receive.
    pub fn add(&mut self, t1: i64, t2: i64, t3: i64, t4: i64) {
        let rtt = (t4 - t1) - (t3 - t2);
        if rtt < 0 {
            return; // clock went backwards or a garbage PONG
        }
        let n = self.samples.len();
        self.samples[self.next % n] = Sample { rtt, offset: ((t2 - t1) + (t3 - t4)) / 2, used: true };
        self.next += 1;
    }

    fn best(&self) -> Option<&Sample> {
        // First minimum wins on ties, like the C++ strict `<` scan.
        self.samples.iter().filter(|s| s.used).fold(None, |b: Option<&Sample>, s| match b {
            Some(b) if b.rtt <= s.rtt => Some(b),
            _ => Some(s),
        })
    }

    pub fn valid(&self) -> bool {
        self.best().is_some()
    }
    pub fn rtt_us(&self) -> i64 {
        self.best().map_or(-1, |b| b.rtt)
    }
    /// remote_clock - local_clock
    pub fn offset_us(&self) -> i64 {
        self.best().map_or(0, |b| b.offset)
    }
}
