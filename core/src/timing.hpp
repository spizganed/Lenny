// Monotonic clock and NTP-style clock sync over PING/PONG (protocol.md §6.3, §8).
#pragma once

#include <array>
#include <chrono>
#include <cstdint>

namespace lenny {

// Core's clock. Platforms must convert capture timestamps into this clock (see lenny_now_us).
inline int64_t now_us() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// Keeps the last 16 samples and trusts the one with the lowest RTT: queueing only ever adds delay,
// so the fastest round trip has the least asymmetric error.
class ClockSync {
public:
    // t1 = our send, t2 = their receive, t3 = their send (their clock), t4 = our receive.
    void add(int64_t t1, int64_t t2, int64_t t3, int64_t t4) {
        const int64_t rtt = (t4 - t1) - (t3 - t2);
        if (rtt < 0) return;  // clock went backwards or a garbage PONG
        samples_[next_++ % samples_.size()] = {rtt, ((t2 - t1) + (t3 - t4)) / 2, true};
    }

    bool valid() const { return best() != nullptr; }
    int64_t rtt_us() const { auto* b = best(); return b ? b->rtt : -1; }
    // remote_clock - local_clock
    int64_t offset_us() const { auto* b = best(); return b ? b->offset : 0; }

private:
    struct Sample {
        int64_t rtt = 0, offset = 0;
        bool used = false;
    };
    const Sample* best() const {
        const Sample* b = nullptr;
        for (const auto& s : samples_)
            if (s.used && (!b || s.rtt < b->rtt)) b = &s;
        return b;
    }
    std::array<Sample, 16> samples_{};
    size_t next_ = 0;
};

}  // namespace lenny
