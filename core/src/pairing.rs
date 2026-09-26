//! Single-use, short-lived QR pairing tokens (protocol.md §6.4). Receiver memory only.

use std::sync::Mutex;

use crate::abi::*;
use crate::wire::PairToken;

pub const DEFAULT_TTL_US: i64 = 90_000_000;
pub const MAX_TOKENS: usize = 16;

struct Entry {
    token: PairToken,
    expires: i64,
    used: bool,
}

#[derive(Default)]
pub struct TokenStore {
    entries: Mutex<Vec<Entry>>,
}

fn equal_ct(a: &PairToken, b: &PairToken) -> bool {
    a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

impl TokenStore {
    pub fn issue(&self, now: i64, ttl_us: i64) -> PairToken {
        let mut t = [0u8; LENNY_PAIR_TOKEN_SIZE];
        // OS CSPRNG. A token we can't make unguessable must not exist: panic is caught at the C ABI.
        getrandom::getrandom(&mut t).expect("OS random source unavailable");
        let mut e = self.entries.lock().unwrap();
        // Keep expired tokens for 10 min so the phone gets EXPIRED instead of UNKNOWN (clearer error).
        e.retain(|x| now <= x.expires + 600_000_000);
        if e.len() >= MAX_TOKENS {
            e.remove(0);
        }
        e.push(Entry { token: t, expires: now + ttl_us, used: false });
        t
    }

    /// Returns LENNY_PAIR_*. Marks the token used on success.
    pub fn redeem(&self, token: &PairToken, now: i64) -> u8 {
        let mut e = self.entries.lock().unwrap();
        let mut found = None;
        for (i, x) in e.iter().enumerate() {
            // no early exit, constant-time compare
            if equal_ct(&x.token, token) {
                found = Some(i);
            }
        }
        let Some(i) = found else { return LENNY_PAIR_UNKNOWN_TOKEN };
        let m = &mut e[i];
        if m.used {
            return LENNY_PAIR_ALREADY_USED;
        }
        if now > m.expires {
            return LENNY_PAIR_EXPIRED;
        }
        m.used = true;
        LENNY_PAIR_OK
    }
}
