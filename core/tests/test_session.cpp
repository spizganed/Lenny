// End-to-end sender -> receiver over TCP on 127.0.0.1, through the public C ABI only (the M1 loopback test).
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "check.hpp"
#include "lenny/lenny.h"

namespace {

using namespace std::chrono_literals;

bool wait_for(auto pred, std::chrono::milliseconds limit = 5000ms) {
    const auto end = std::chrono::steady_clock::now() + limit;
    while (!pred()) {
        if (std::chrono::steady_clock::now() > end) return false;
        std::this_thread::sleep_for(5ms);
    }
    return true;
}

struct Recv {
    std::atomic<int> approvals{0}, configs{0}, frames{0}, acks{0}, states{0}, starts{0};
    std::atomic<int> last_ack_result{-1};
    std::atomic<uint32_t> last_ack_id{0};
    std::atomic<int> torch{-1};
    std::atomic<int> saw_config_before_key{0};
    std::atomic<int64_t> last_local_pts{0};
    std::mutex mu;
    std::vector<uint8_t> last_frame;
    lenny_stream_settings started{};
};

struct Send {
    std::atomic<int> keyframe_requests{0}, focus_calls{0}, configs{0};
    std::atomic<int> last_reason{-1};
    std::atomic<uint16_t> focus_x{0};
};

lenny_identity ident(uint8_t id_byte, const char* name, uint8_t platform) {
    lenny_identity id{};
    std::memset(id.device_id, id_byte, sizeof id.device_id);
    id.device_name = name;
    id.app_version = "test";
    id.platform = platform;
    return id;
}

lenny_session* make_receiver(Recv& r, uint16_t port = 0) {
    lenny_receiver_config cfg{};
    cfg.identity = ident(0xDD, "Desk", LENNY_PLATFORM_WINDOWS);
    cfg.port = port;
    cfg.preferred = {LENNY_CODEC_H264, {1920, 1080, 30, 1}, 20000, 0, 0};
    lenny_receiver_callbacks cb{};
    cb.user = &r;
    cb.on_approval_needed = [](void* u, const uint8_t*, const char* name) {
        if (std::strcmp(name, "Pixel") == 0) static_cast<Recv*>(u)->approvals++;
    };
    cb.on_stream_start = [](void* u, const lenny_stream_settings* s) {
        auto* r = static_cast<Recv*>(u);
        std::lock_guard lock(r->mu);
        r->started = *s;
        r->starts++;
    };
    cb.on_video_config = [](void* u, const uint8_t*, size_t) { static_cast<Recv*>(u)->configs++; };
    cb.on_video_frame = [](void* u, const lenny_video_frame* f) {
        auto* r = static_cast<Recv*>(u);
        if ((f->flags & LENNY_FRAME_KEYFRAME) && r->configs > 0) r->saw_config_before_key = 1;
        std::lock_guard lock(r->mu);
        r->last_frame.assign(f->data, f->data + f->size);
        r->last_local_pts = f->local_pts_us;
        r->frames++;
    };
    cb.on_control_ack = [](void* u, uint32_t id, uint8_t res) {
        auto* r = static_cast<Recv*>(u);
        r->last_ack_id = id;
        r->last_ack_result = res;
        r->acks++;
    };
    cb.on_control_state = [](void* u, const lenny_control_state* s) { static_cast<Recv*>(u)->torch = s->torch; };
    auto* s = lenny_receiver_create(&cfg, &cb);
    CHECK(s != nullptr);
    CHECK(lenny_receiver_start(s) == LENNY_OK);
    CHECK(lenny_receiver_port(s) != 0);
    return s;
}

const lenny_mode kModes[] = {{1280, 720, 30, 1}, {1920, 1080, 30, 1}, {3840, 2160, 30, 1}};
const lenny_lens kLenses[] = {{0, 0, "Wide"}, {1, 1, "Front"}};

lenny_session* make_sender(Send& snd, uint8_t id_byte = 0x11) {
    lenny_sender_config cfg{};
    cfg.identity = ident(id_byte, "Pixel", LENNY_PLATFORM_ANDROID);
    cfg.modes = kModes;
    cfg.mode_count = 3;
    cfg.max_bitrate_kbps = 12000;
    cfg.controls = LENNY_CAP_FOCUS | LENNY_CAP_TORCH | LENNY_CAP_EXPOSURE_COMP;
    cfg.lenses = kLenses;
    cfg.lens_count = 2;
    cfg.exposure_comp_min = -2000;
    cfg.exposure_comp_max = 2000;
    cfg.exposure_comp_step_milli = 333;
    lenny_sender_callbacks cb{};
    cb.user = &snd;
    cb.on_state = [](void* u, int32_t st, int32_t reason) {
        if (st == LENNY_STATE_CLOSED) static_cast<Send*>(u)->last_reason = reason;
    };
    cb.on_stream_config = [](void* u, const lenny_stream_settings*, lenny_stream_settings* eff) {
        static_cast<Send*>(u)->configs++;
        eff->bitrate_kbps = 10000;  // platform clamps
    };
    cb.on_control = [](void* u, const lenny_control* c) -> int32_t {
        auto* s = static_cast<Send*>(u);
        if (c->cmd == LENNY_CTL_KEYFRAME_REQUEST) { s->keyframe_requests++; return LENNY_ACK_OK; }
        if (c->cmd == LENNY_CTL_FOCUS_AT) { s->focus_x = c->x; s->focus_calls++; return LENNY_ACK_OK; }
        return LENNY_ACK_UNSUPPORTED;
    };
    auto* s = lenny_sender_create(&cfg, &cb);
    CHECK(s != nullptr);
    return s;
}

bool streaming(lenny_session* s) { return lenny_session_state(s) == LENNY_STATE_STREAMING; }

}  // namespace

TEST(abi_version) { CHECK(lenny_abi_version() == ((1u << 16) | 0u)); }

TEST(full_session_with_approval_video_and_controls) {
    Recv r;
    Send snd;
    auto* rx = make_receiver(r);
    auto* tx = make_sender(snd);
    CHECK(lenny_sender_connect(tx, "127.0.0.1", lenny_receiver_port(rx), nullptr) == LENNY_OK);

    // Unknown phone: receiver asks the user.
    CHECK(wait_for([&] { return r.approvals == 1; }));
    CHECK(lenny_session_state(rx) == LENNY_STATE_AWAITING_APPROVAL);
    CHECK(lenny_sender_send_video_frame(tx, (const uint8_t*)"x", 1, 0, 0, 0) == LENNY_E_STATE);  // not yet
    CHECK(lenny_receiver_approve(rx, 1) == LENNY_OK);
    CHECK(wait_for([&] { return streaming(rx) && streaming(tx); }));

    // Negotiation: receiver preferred 1080p30 @ 20 Mbps, sender caps max 12 Mbps, platform clamped to 10.
    CHECK(wait_for([&] { return r.starts == 1; }));
    {
        std::lock_guard lock(r.mu);
        CHECK(r.started.mode.width == 1920 && r.started.mode.height == 1080 && r.started.bitrate_kbps == 10000);
    }
    CHECK(snd.configs == 1);
    CHECK(wait_for([&] { return snd.keyframe_requests == 1; }));  // fresh stream -> keyframe

    // Config is cached and resent ahead of each keyframe.
    const uint8_t sps[] = {0, 0, 0, 1, 0x67, 0x42};
    const uint8_t idr[] = {0, 0, 0, 1, 0x65, 0x88, 0x84};
    const uint8_t p[] = {0, 0, 0, 1, 0x41, 0x9A};
    CHECK(lenny_sender_send_video_config(tx, sps, sizeof sps) == LENNY_OK);
    CHECK(wait_for([&] { return r.configs == 1; }));
    CHECK(lenny_sender_send_video_frame(tx, idr, sizeof idr, lenny_now_us(), 1, LENNY_FRAME_KEYFRAME) == LENNY_OK);
    CHECK(lenny_sender_send_video_frame(tx, p, sizeof p, lenny_now_us(), 1, 0) == LENNY_OK);
    CHECK(wait_for([&] { return r.frames == 2; }));
    CHECK(r.configs == 2 && r.saw_config_before_key == 1);
    {
        std::lock_guard lock(r.mu);
        CHECK(r.last_frame == std::vector<uint8_t>(p, p + sizeof p));
    }

    // Remote tap-to-focus -> phone callback -> ACK back.
    lenny_control focus{0, LENNY_CTL_FOCUS_AT, 30000, 20000, 0};
    CHECK(lenny_receiver_send_control(rx, &focus) == LENNY_OK);
    CHECK(focus.req_id != 0);
    CHECK(wait_for([&] { return r.acks == 1; }));
    CHECK(snd.focus_calls == 1 && snd.focus_x == 30000);
    CHECK(r.last_ack_id == focus.req_id && r.last_ack_result == LENNY_ACK_OK);
    lenny_control zoom{0, LENNY_CTL_ZOOM, 0, 0, 200};
    CHECK(lenny_receiver_send_control(rx, &zoom) == LENNY_OK);
    CHECK(wait_for([&] { return r.acks == 2; }));
    CHECK(r.last_ack_result == LENNY_ACK_UNSUPPORTED);

    lenny_control_state cs{0, 0, 0, 0, 1, 0, 100};
    CHECK(lenny_sender_send_control_state(tx, &cs) == LENNY_OK);
    CHECK(wait_for([&] { return r.torch == 1; }));

    // Keepalive runs every second: after ~1.2 s both sides have an RTT and the receiver maps pts to local time.
    CHECK(wait_for([&] {
        lenny_stats st{};
        lenny_session_get_stats(rx, &st);
        return st.rtt_us >= 0;
    }));
    CHECK(lenny_sender_send_video_frame(tx, p, sizeof p, lenny_now_us(), 0, 0) == LENNY_OK);
    CHECK(wait_for([&] { return r.frames == 3; }));
    // Same machine, same clock: mapped pts is within a few ms of the original.
    CHECK(r.last_local_pts != 0 && std::abs(r.last_local_pts - lenny_now_us()) < 1'000'000);

    lenny_stats st{};
    CHECK(lenny_session_get_stats(tx, &st) == LENNY_OK && st.frames == 3);

    // Phone user disconnects: sender closes for good, receiver goes back to listening.
    CHECK(lenny_session_disconnect(tx) == LENNY_OK);
    CHECK(wait_for([&] { return lenny_session_state(tx) == LENNY_STATE_CLOSED; }));
    CHECK(snd.last_reason == LENNY_REASON_USER);
    CHECK(wait_for([&] { return lenny_session_state(rx) == LENNY_STATE_CONNECTING; }));

    lenny_session_destroy(tx);
    lenny_session_destroy(rx);
}

TEST(ui_events_carry_ints_and_getters_have_details) {
    struct Ev {
        std::atomic<int> approval{0}, start{0}, streaming{0}, ack{0};
    } ev;
    Recv r;
    Send snd;
    auto* rx = make_receiver(r);
    auto* tx = make_sender(snd);
    lenny_peer_info peer{};
    CHECK(lenny_session_peer(rx, &peer) == LENNY_E_STATE);  // nobody yet
    lenny_session_set_event_listener(rx, [](void* u, int32_t e, int32_t a, int32_t) {
        auto* ev = static_cast<Ev*>(u);
        if (e == LENNY_EVENT_APPROVAL_NEEDED) ev->approval++;
        if (e == LENNY_EVENT_STREAM_START) ev->start++;
        if (e == LENNY_EVENT_STATE && a == LENNY_STATE_STREAMING) ev->streaming++;
        if (e == LENNY_EVENT_CONTROL_ACK) ev->ack++;
    }, &ev);
    lenny_sender_connect(tx, "127.0.0.1", lenny_receiver_port(rx), nullptr);
    CHECK(wait_for([&] { return ev.approval == 1; }));
    CHECK(lenny_session_peer(rx, &peer) == LENNY_OK);
    CHECK(std::strcmp(peer.name, "Pixel") == 0 && peer.platform == LENNY_PLATFORM_ANDROID && peer.device_id[0] == 0x11);
    lenny_receiver_approve(rx, 1);
    CHECK(wait_for([&] { return ev.start == 1 && ev.streaming == 1; }));
    lenny_stream_settings st{};
    CHECK(lenny_session_stream_settings(rx, &st) == LENNY_OK && st.mode.width == 1920);
    lenny_stream_settings tx_st{};
    CHECK(lenny_session_stream_settings(tx, &tx_st) == LENNY_OK && tx_st.bitrate_kbps == 10000);
    lenny_control key{0, LENNY_CTL_KEYFRAME_REQUEST, 0, 0, 0};
    lenny_receiver_send_control(rx, &key);
    CHECK(wait_for([&] { return ev.ack == 1; }));
    lenny_session_destroy(tx);
    lenny_session_destroy(rx);
}

TEST(slow_network_drops_to_keyframe_and_lowers_bitrate_without_blocking) {
    // A receiver that falls behind (it sleeps in the frame callback, so its socket stops draining) must not make the
    // phone's encoder thread block, and the phone must shed load: drop backlog, ask for a keyframe, lower bitrate.
    struct Slow {
        std::atomic<int> frames{0};
    } slow;
    lenny_receiver_config rcfg{};
    rcfg.identity = ident(0xDD, "Desk", LENNY_PLATFORM_WINDOWS);
    rcfg.preferred = {LENNY_CODEC_H264, {1280, 720, 30, 1}, 2000, 0, 0};
    lenny_receiver_callbacks rcb{};
    rcb.user = &slow;
    rcb.on_video_frame = [](void* u, const lenny_video_frame*) {
        static_cast<Slow*>(u)->frames++;
        std::this_thread::sleep_for(50ms);
    };
    auto* rx = lenny_receiver_create(&rcfg, &rcb);
    lenny_receiver_start(rx);
    uint8_t id[LENNY_DEVICE_ID_SIZE];
    std::memset(id, 0x61, sizeof id);
    lenny_receiver_trust_device(rx, id);

    struct Tx {
        std::atomic<int> keyframes{0};
        std::atomic<uint32_t> kbps{0};
    } txs;
    lenny_sender_config scfg{};
    scfg.identity = ident(0x61, "Pixel", LENNY_PLATFORM_ANDROID);
    scfg.modes = kModes;
    scfg.mode_count = 3;
    scfg.max_bitrate_kbps = 2000;
    lenny_sender_callbacks scb{};
    scb.user = &txs;
    scb.on_control = [](void* u, const lenny_control* c) -> int32_t {
        if (c->cmd == LENNY_CTL_KEYFRAME_REQUEST) static_cast<Tx*>(u)->keyframes++;
        return LENNY_ACK_OK;
    };
    scb.on_bitrate = [](void* u, uint32_t kbps) { static_cast<Tx*>(u)->kbps = kbps; };
    auto* tx = lenny_sender_create(&scfg, &scb);
    lenny_sender_connect(tx, "127.0.0.1", lenny_receiver_port(rx), nullptr);
    CHECK(wait_for([&] { return streaming(tx) && streaming(rx); }));

    // 2 Mbps target, but we push 60 KB frames (~14 Mbps at 30 fps) as fast as we can: far more than the slow
    // receiver takes. Keyframe every 10th frame.
    // Timestamps advance like a real 30 fps camera even though we push faster than real time.
    std::vector<uint8_t> frame(60 * 1024, 0xAB);
    auto worst = std::chrono::steady_clock::duration::zero();
    const int64_t base = lenny_now_us();
    for (int i = 0; i < 300; ++i) {
        const auto t0 = std::chrono::steady_clock::now();
        CHECK(lenny_sender_send_video_frame(tx, frame.data(), frame.size(), base + i * 33'333, 0,
                                            i % 10 == 0 ? LENNY_FRAME_KEYFRAME : 0) == LENNY_OK);
        worst = std::max(worst, std::chrono::steady_clock::now() - t0);
    }
    CHECK(worst < 20ms);  // the encoder thread never waited on the network
    lenny_stats st{};
    lenny_session_get_stats(tx, &st);
    CHECK(st.dropped_frames > 0);
    CHECK(txs.keyframes > 1);                          // one at stream start, more after drops
    CHECK(txs.kbps > 0 && txs.kbps < 2000);           // bitrate stepped down
    CHECK(st.bitrate_kbps == txs.kbps);
    CHECK(wait_for([&] { return slow.frames > 0; }));  // some got through...
    CHECK(slow.frames < 300);                           // ...but not the whole backlog
    lenny_session_destroy(tx);
    lenny_session_destroy(rx);
}

TEST(update_stream_reaches_receiver_and_latency_is_measured) {
    Recv r;
    Send snd;
    auto* rx = make_receiver(r);
    uint8_t id[LENNY_DEVICE_ID_SIZE];
    std::memset(id, 0x71, sizeof id);
    lenny_receiver_trust_device(rx, id);
    auto* tx = make_sender(snd, 0x71);
    lenny_sender_connect(tx, "127.0.0.1", lenny_receiver_port(rx), nullptr);
    CHECK(wait_for([&] { return r.starts == 1 && streaming(tx); }));

    // Camera picked 1280x720 instead of the requested 1080p.
    lenny_stream_settings actual{LENNY_CODEC_H264, {1280, 720, 30, 1}, 10000, 0, 0};
    CHECK(lenny_sender_update_stream(tx, &actual) == LENNY_OK);
    CHECK(wait_for([&] { return r.starts == 2; }));
    {
        std::lock_guard lock(r.mu);
        CHECK(r.started.mode.width == 1280 && r.started.mode.height == 720);
    }

    // Latency appears once clock sync has a sample (first PING after ~1 s).
    const uint8_t idr[] = {0, 0, 0, 1, 0x65};
    CHECK(wait_for([&] {
        lenny_sender_send_video_frame(tx, idr, sizeof idr, lenny_now_us(), 0, LENNY_FRAME_KEYFRAME);
        std::this_thread::sleep_for(30ms);
        lenny_stats st{};
        lenny_session_get_stats(rx, &st);
        return st.latency_us >= 0;
    }));
    lenny_stats st{};
    lenny_session_get_stats(rx, &st);
    CHECK(st.latency_us < 200'000);  // same machine: well under 200 ms
    lenny_session_destroy(tx);
    lenny_session_destroy(rx);
}

TEST(qr_token_skips_approval_and_is_single_use) {
    Recv r;
    Send a, b;
    auto* rx = make_receiver(r);
    uint8_t token[LENNY_PAIR_TOKEN_SIZE];
    CHECK(lenny_receiver_new_pair_token(rx, 0, token) == LENNY_OK);
    const uint16_t port = lenny_receiver_port(rx);

    auto* tx = make_sender(a, 0x21);
    CHECK(lenny_sender_connect(tx, "127.0.0.1", port, token) == LENNY_OK);
    CHECK(wait_for([&] { return streaming(rx) && streaming(tx); }));
    CHECK(r.approvals == 0);
    lenny_session_destroy(tx);

    // A photo of the same QR code, different phone: rejected, no retry.
    auto* tx2 = make_sender(b, 0x22);
    CHECK(wait_for([&] { return lenny_session_state(rx) == LENNY_STATE_CONNECTING; }));
    CHECK(lenny_sender_connect(tx2, "127.0.0.1", port, token) == LENNY_OK);
    CHECK(wait_for([&] { return lenny_session_state(tx2) == LENNY_STATE_CLOSED; }));
    CHECK(b.last_reason == LENNY_REASON_PAIR_DENIED);
    lenny_session_destroy(tx2);
    lenny_session_destroy(rx);
}

TEST(trusted_device_skips_prompt_denied_device_is_closed) {
    Recv r;
    Send ok, denied;
    auto* rx = make_receiver(r);
    const uint16_t port = lenny_receiver_port(rx);
    uint8_t id[LENNY_DEVICE_ID_SIZE];
    std::memset(id, 0x31, sizeof id);
    CHECK(lenny_receiver_trust_device(rx, id) == LENNY_OK);

    auto* tx = make_sender(ok, 0x31);
    CHECK(lenny_sender_connect(tx, "127.0.0.1", port, nullptr) == LENNY_OK);
    CHECK(wait_for([&] { return streaming(rx) && streaming(tx); }));
    CHECK(r.approvals == 0);
    lenny_session_destroy(tx);

    auto* tx2 = make_sender(denied, 0x32);
    CHECK(wait_for([&] { return lenny_session_state(rx) == LENNY_STATE_CONNECTING; }));
    CHECK(lenny_sender_connect(tx2, "127.0.0.1", port, nullptr) == LENNY_OK);
    CHECK(wait_for([&] { return r.approvals == 1; }));
    CHECK(lenny_receiver_approve(rx, 0) == LENNY_OK);
    CHECK(wait_for([&] { return lenny_session_state(tx2) == LENNY_STATE_CLOSED; }));
    CHECK(denied.last_reason == LENNY_REASON_PAIR_DENIED);
    lenny_session_destroy(tx2);
    lenny_session_destroy(rx);
}

TEST(second_phone_gets_busy_first_keeps_streaming) {
    Recv r;
    Send a, b;
    auto* rx = make_receiver(r);
    const uint16_t port = lenny_receiver_port(rx);
    uint8_t id[LENNY_DEVICE_ID_SIZE];
    std::memset(id, 0x41, sizeof id);
    lenny_receiver_trust_device(rx, id);
    std::memset(id, 0x42, sizeof id);
    lenny_receiver_trust_device(rx, id);

    auto* tx = make_sender(a, 0x41);
    lenny_sender_connect(tx, "127.0.0.1", port, nullptr);
    CHECK(wait_for([&] { return streaming(tx); }));
    auto* tx2 = make_sender(b, 0x42);
    lenny_sender_connect(tx2, "127.0.0.1", port, nullptr);
    std::this_thread::sleep_for(1500ms);
    CHECK(!streaming(tx2));
    CHECK(lenny_session_state(tx2) == LENNY_STATE_RECONNECTING);  // BUSY is not fatal: it keeps trying
    CHECK(streaming(tx) && streaming(rx));

    // First phone leaves -> the waiting one gets in on its next retry.
    lenny_session_destroy(tx);
    CHECK(wait_for([&] { return streaming(tx2); }));
    lenny_session_destroy(tx2);
    lenny_session_destroy(rx);
}

TEST(sender_reconnects_after_receiver_restart) {
    Recv r1, r2;
    Send snd;
    auto* rx = make_receiver(r1);
    const uint16_t port = lenny_receiver_port(rx);
    uint8_t id[LENNY_DEVICE_ID_SIZE];
    std::memset(id, 0x51, sizeof id);
    lenny_receiver_trust_device(rx, id);
    auto* tx = make_sender(snd, 0x51);
    lenny_sender_connect(tx, "127.0.0.1", port, nullptr);
    CHECK(wait_for([&] { return streaming(tx); }));

    // Desktop app crashes / restarts on the same port.
    lenny_session_destroy(rx);
    CHECK(wait_for([&] { return lenny_session_state(tx) == LENNY_STATE_RECONNECTING; }));
    rx = make_receiver(r2, port);
    lenny_receiver_trust_device(rx, id);
    CHECK(wait_for([&] { return streaming(tx) && streaming(rx); }));
    CHECK(snd.keyframe_requests == 2);  // one per stream
    lenny_stats st{};
    lenny_session_get_stats(tx, &st);
    CHECK(st.reconnects == 1);
    lenny_session_destroy(tx);
    lenny_session_destroy(rx);
}

TEST(nothing_listening_keeps_retrying_and_disconnect_is_fast) {
    Send snd;
    auto* tx = make_sender(snd);
    // Port 1 on localhost: refused immediately, so this exercises the backoff loop.
    CHECK(lenny_sender_connect(tx, "127.0.0.1", 1, nullptr) == LENNY_OK);
    CHECK(wait_for([&] { return lenny_session_state(tx) == LENNY_STATE_RECONNECTING; }));
    CHECK(lenny_sender_connect(tx, "127.0.0.1", 1, nullptr) == LENNY_E_STATE);  // already running
    const auto t0 = std::chrono::steady_clock::now();
    lenny_session_destroy(tx);
    CHECK(std::chrono::steady_clock::now() - t0 < 1s);
}

TEST(null_and_bad_args_do_not_crash) {
    CHECK(lenny_sender_create(nullptr, nullptr) == nullptr);
    CHECK(lenny_receiver_create(nullptr, nullptr) == nullptr);
    CHECK(lenny_sender_connect(nullptr, "x", 1, nullptr) == LENNY_E_INVALID_ARG);
    CHECK(lenny_session_state(nullptr) == LENNY_STATE_CLOSED);
    lenny_session_destroy(nullptr);
    Send snd;
    auto* tx = make_sender(snd);
    CHECK(lenny_sender_connect(tx, "", 1, nullptr) == LENNY_E_INVALID_ARG);
    CHECK(lenny_sender_send_video_config(tx, nullptr, 0) == LENNY_E_INVALID_ARG);
    CHECK(lenny_receiver_new_pair_token(tx, 0, nullptr) == LENNY_E_INVALID_ARG);
    lenny_control c{0, 999, 0, 0, 0};
    CHECK(lenny_receiver_send_control(tx, &c) == LENNY_E_STATE);  // sender can't send controls
    lenny_session_destroy(tx);
}
