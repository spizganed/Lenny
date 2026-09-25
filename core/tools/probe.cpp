// lenny_probe: headless receiver for testing senders without the desktop app (and for soak tests).
// Auto-accepts any phone and prints one line of stats per second.  Usage: lenny_probe [port] [seconds]
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>

#include "lenny/lenny.h"

namespace {
std::atomic<int> g_keyframes{0}, g_configs{0};
std::atomic<int> g_width{0}, g_height{0}, g_orientation{0};
lenny_session* g_rx = nullptr;
}  // namespace

int main(int argc, char** argv) {
    const int port = argc > 1 ? std::atoi(argv[1]) : LENNY_DEFAULT_PORT;
    const int seconds = argc > 2 ? std::atoi(argv[2]) : 0;  // 0 = forever
    lenny_receiver_config cfg{};
    cfg.identity.device_name = "lenny_probe";
    cfg.identity.platform = LENNY_PLATFORM_WINDOWS;
    cfg.port = static_cast<uint16_t>(port);
    cfg.preferred = {LENNY_CODEC_H264, {1920, 1080, 30, 1}, 8000, 0, 0};
    lenny_receiver_callbacks cb{};
    cb.on_state = [](void*, int32_t st, int32_t reason) { std::printf("state %d reason %d\n", st, reason); };
    cb.on_approval_needed = [](void*, const uint8_t*, const char* name) {
        std::printf("approving \"%s\"\n", name);
        lenny_receiver_approve(g_rx, 1);  // same thread as the core, but approve() only sets a flag
    };
    cb.on_stream_start = [](void*, const lenny_stream_settings* s) {
        g_width = s->mode.width;
        g_height = s->mode.height;
        std::printf("stream %ux%u @ %u/%u fps, %u kbps\n", s->mode.width, s->mode.height, s->mode.fps_num,
                    s->mode.fps_den, s->bitrate_kbps);
    };
    cb.on_video_config = [](void*, const uint8_t*, size_t) { g_configs++; };
    cb.on_video_frame = [](void*, const lenny_video_frame* f) {
        if (f->flags & LENNY_FRAME_KEYFRAME) g_keyframes++;
        g_orientation = f->orientation;
    };
    g_rx = lenny_receiver_create(&cfg, &cb);
    if (!g_rx || lenny_receiver_start(g_rx) != LENNY_OK) {
        std::fprintf(stderr, "cannot listen on %d\n", port);
        return 1;
    }
    std::printf("listening on %u\n", lenny_receiver_port(g_rx));
    lenny_stats last{};
    for (int t = 0; seconds == 0 || t < seconds; ++t) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        lenny_stats s{};
        lenny_session_get_stats(g_rx, &s);
        if (s.frames != last.frames)
            std::printf("fps %llu  kbps %llu  keyframes %d  configs %d  rtt %.1f ms  latency %.1f ms  orientation %d\n",
                        static_cast<unsigned long long>(s.frames - last.frames),
                        static_cast<unsigned long long>((s.bytes - last.bytes) * 8 / 1000), g_keyframes.load(),
                        g_configs.load(), s.rtt_us / 1000.0, s.latency_us / 1000.0, g_orientation.load() * 90);
        std::fflush(stdout);
        last = s;
    }
    lenny_session_destroy(g_rx);
    return 0;
}
