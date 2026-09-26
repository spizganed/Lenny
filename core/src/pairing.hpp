// Single-use, short-lived QR pairing tokens (protocol.md §6.4). Receiver memory only.
#pragma once

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <random>
#include <vector>

#include "wire.hpp"

namespace lenny {

class TokenStore {
public:
    static constexpr int64_t kDefaultTtlUs = 90'000'000;
    static constexpr size_t kMaxTokens = 16;

    wire::PairToken issue(int64_t now, int64_t ttl_us = kDefaultTtlUs) {
        wire::PairToken t;
        // std::random_device is backed by the OS CSPRNG on our targets (MSVC: rand_s, libc++: arc4random or
        // /dev/urandom). Revisit if a new toolchain maps it to a PRNG.
        std::random_device rd;
        for (size_t i = 0; i < t.size(); i += 4) {
            uint32_t r = rd();
            for (size_t j = 0; j < 4; ++j) t[i + j] = static_cast<uint8_t>(r >> (8 * j));
        }
        std::lock_guard lock(mu_);
        prune(now);
        if (entries_.size() >= kMaxTokens) entries_.erase(entries_.begin());
        entries_.push_back({t, now + ttl_us, false});
        return t;
    }

    // Returns LENNY_PAIR_*. Marks the token used on success.
    uint8_t redeem(const wire::PairToken& token, int64_t now) {
        std::lock_guard lock(mu_);
        Entry* match = nullptr;
        for (auto& e : entries_)  // no early exit, constant-time compare
            if (equal_ct(e.token, token)) match = &e;
        if (!match) return LENNY_PAIR_UNKNOWN_TOKEN;
        if (match->used) return LENNY_PAIR_ALREADY_USED;
        if (now > match->expires) return LENNY_PAIR_EXPIRED;
        match->used = true;
        return LENNY_PAIR_OK;
    }

private:
    struct Entry {
        wire::PairToken token;
        int64_t expires;
        bool used;
    };

    static bool equal_ct(const wire::PairToken& a, const wire::PairToken& b) {
        uint8_t d = 0;
        for (size_t i = 0; i < a.size(); ++i) d |= a[i] ^ b[i];
        return d == 0;
    }

    // Keep expired tokens for 10 min so the phone gets EXPIRED instead of UNKNOWN (clearer error).
    void prune(int64_t now) {
        std::erase_if(entries_, [&](const Entry& e) { return now > e.expires + 600'000'000; });
    }

    std::mutex mu_;
    std::vector<Entry> entries_;
};

}  // namespace lenny
