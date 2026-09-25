#include "session.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>

namespace lenny {
namespace {

constexpr int64_t kMs = 1000;
constexpr int64_t kSec = 1000 * kMs;
constexpr int64_t kHelloTimeout = 5 * kSec;
constexpr int64_t kPairTimeout = 30 * kSec;
constexpr int64_t kCapsTimeout = 5 * kSec;
constexpr int64_t kApprovalTimeout = 30 * kSec;
// Sender waits for CAPS_SELECT while the receiver's user may be looking at the approve prompt.
constexpr int64_t kSenderCapsTimeout = kApprovalTimeout + 5 * kSec;
constexpr int64_t kPingInterval = 1 * kSec;
constexpr int64_t kSilenceLimit = 3 * kSec;
constexpr int kConnectTimeoutMs = 2000;
constexpr int kBackoffMs[] = {250, 500, 1000, 2000};
constexpr uint32_t kDefaultBitrateKbps = 8000;
constexpr size_t kMaxVideoConfig = 60000;  // must fit one TLV field

bool fatal_for_sender(int32_t reason) {
    return reason == LENNY_REASON_VERSION || reason == LENNY_REASON_ROLE || reason == LENNY_REASON_PAIR_DENIED ||
           reason == LENNY_REASON_USER;
}

wire::Hello make_hello(const lenny_identity& id, Role role) {
    wire::Hello h;
    h.role = static_cast<uint8_t>(role);
    std::copy(std::begin(id.device_id), std::end(id.device_id), h.device_id.begin());
    h.device_name = id.device_name ? id.device_name : "";
    h.app_version = id.app_version ? id.app_version : "";
    h.platform = id.platform;
    return h;
}

double fps(const lenny_mode& m) { return m.fps_den ? double(m.fps_num) / m.fps_den : 0.0; }

// Receiver's pick: the sender mode closest to the preferred one (area first, then fps).
lenny_stream_settings choose_settings(const wire::Caps& caps, lenny_stream_settings pref) {
    lenny_stream_settings s = pref;
    if (!s.codec) s.codec = LENNY_CODEC_H264;
    if (!caps.codecs.empty() &&
        std::none_of(caps.codecs.begin(), caps.codecs.end(), [&](auto& c) { return c.id == s.codec; }))
        s.codec = caps.codecs.front().id;
    if (!caps.modes.empty()) {
        const double area = double(pref.mode.width) * pref.mode.height;
        auto score = [&](const lenny_mode& m) {
            return std::pair(std::abs(double(m.width) * m.height - area), std::abs(fps(m) - fps(pref.mode)));
        };
        s.mode = *std::min_element(caps.modes.begin(), caps.modes.end(),
                                   [&](auto& a, auto& b) { return score(a) < score(b); });
    }
    if (!s.bitrate_kbps) s.bitrate_kbps = kDefaultBitrateKbps;
    if (caps.max_bitrate_kbps) s.bitrate_kbps = std::min(s.bitrate_kbps, caps.max_bitrate_kbps);
    if (s.has_lens && std::none_of(caps.lenses.begin(), caps.lenses.end(), [&](auto& l) { return l.id == s.lens_id; }))
        s.has_lens = 0;
    return s;
}

}  // namespace

// ---- construction ------------------------------------------------------
Session::Session(const lenny_sender_config& cfg, const lenny_sender_callbacks& cb)
    : role_(Role::Sender), hello_(make_hello(cfg.identity, Role::Sender)), scb_(cb) {
    caps_.codecs.push_back({LENNY_CODEC_H264, 0, 0});
    caps_.modes.assign(cfg.modes, cfg.modes + cfg.mode_count);
    caps_.max_bitrate_kbps = cfg.max_bitrate_kbps;
    caps_.controls = cfg.controls;
    for (size_t i = 0; i < cfg.lens_count; ++i)
        caps_.lenses.push_back({cfg.lenses[i].lens_id, cfg.lenses[i].facing,
                                cfg.lenses[i].label ? cfg.lenses[i].label : ""});
    if (cfg.controls & LENNY_CAP_EXPOSURE_COMP) {
        caps_.has_exposure_range = true;
        caps_.exposure_min = cfg.exposure_comp_min;
        caps_.exposure_max = cfg.exposure_comp_max;
        caps_.exposure_step_milli = cfg.exposure_comp_step_milli;
    }
}

Session::Session(const lenny_receiver_config& cfg, const lenny_receiver_callbacks& cb)
    : role_(Role::Receiver),
      hello_(make_hello(cfg.identity, Role::Receiver)),
      rcb_(cb),
      preferred_(cfg.preferred),
      listen_port_(cfg.port) {}

Session::~Session() {
    bye_reason_ = LENNY_REASON_NORMAL;
    disconnect();
    if (!io_.joinable()) return;
    // Normally the I/O thread exits within ~50 ms. If it's stuck in a blocked send, force the socket shut.
    for (int i = 0; i < 20 && !io_done_; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (!io_done_) {
        std::lock_guard lock(link_mu_);
        if (link_) link_->shutdown();
    }
    io_.join();
}

bool Session::join_finished_thread() {
    if (!io_.joinable()) return true;
    if (!io_done_) return false;
    io_.join();
    return true;
}

// ---- public: sender ----------------------------------------------------
int32_t Session::connect(const std::string& host, uint16_t port, const uint8_t* pair_token) {
    if (role_ != Role::Sender || host.empty() || port == 0) return LENNY_E_INVALID_ARG;
    if (!join_finished_thread()) return LENNY_E_STATE;
    pair_token_.clear();
    if (pair_token) pair_token_.assign(pair_token, pair_token + LENNY_PAIR_TOKEN_SIZE);
    stop_ = false;
    io_done_ = false;
    io_ = std::thread([this, host, port] { sender_loop(host, port); });
    return LENNY_OK;
}

int32_t Session::send_video_config(const uint8_t* data, size_t size) {
    if (role_ != Role::Sender) return LENNY_E_STATE;
    if (!data || size == 0 || size > kMaxVideoConfig) return LENNY_E_INVALID_ARG;
    {
        std::lock_guard lock(video_mu_);
        video_config_.assign(data, data + size);
    }
    if (!streaming_) return LENNY_OK;  // cached; goes out before the next keyframe
    wire::VideoConfig vc;
    vc.config.assign(data, data + size);
    return send(vc) ? LENNY_OK : LENNY_E_IO;
}

int32_t Session::send_video_frame(const uint8_t* data, size_t size, int64_t pts_us, uint8_t orientation,
                                  uint8_t flags) {
    if (role_ != Role::Sender) return LENNY_E_STATE;
    if (!data || size == 0 || size > wire::kMaxVideoPayload - wire::kVideoFrameMetaSize) return LENNY_E_INVALID_ARG;
    if (!streaming_) return LENNY_E_STATE;
    // ponytail: blocking send on the caller's thread. M3 adds the drop-until-keyframe backpressure (protocol.md §9).
    std::lock_guard lock(video_mu_);
    if ((flags & LENNY_FRAME_KEYFRAME) && !video_config_.empty()) {
        // SPS/PPS before every keyframe, so a receiver that just joined or lost its decoder recovers (§6.8).
        wire::VideoConfig vc;
        vc.config = video_config_;
        if (!send(vc)) return LENNY_E_IO;
    }
    uint8_t head[wire::kHeaderSize + wire::kVideoFrameMetaSize];
    wire::Header h;
    h.ver_minor = minor_;
    h.type = static_cast<uint16_t>(wire::MsgType::VideoFrame);
    h.length = static_cast<uint32_t>(wire::kVideoFrameMetaSize + size);
    wire::put_header(head, h);
    wire::encode_video_meta(head + wire::kHeaderSize, {frame_seq_++, pts_us, uint8_t(orientation & 3), flags});
    if (!send_raw(head, sizeof head, data, size)) return LENNY_E_IO;
    std::lock_guard slock(stats_mu_);
    stats_.frames++;
    stats_.bytes += size;
    return LENNY_OK;
}

int32_t Session::send_control_state(const lenny_control_state& s) {
    if (role_ != Role::Sender) return LENNY_E_STATE;
    if (!streaming_) return LENNY_E_STATE;
    return send(wire::ControlState{s}) ? LENNY_OK : LENNY_E_IO;
}

int32_t Session::send_stream_status(uint8_t state, const char* reason) {
    if (role_ != Role::Sender) return LENNY_E_STATE;
    if (!streaming_) return LENNY_E_STATE;
    return send(wire::StreamStatus{state, reason ? reason : ""}) ? LENNY_OK : LENNY_E_IO;
}

// ---- public: receiver ----------------------------------------------------
int32_t Session::start() {
    if (role_ != Role::Receiver) return LENNY_E_STATE;
    if (!join_finished_thread()) return LENNY_E_STATE;
    if (!listener_.listen(listen_port_)) return LENNY_E_IO;
    stop_ = false;
    io_done_ = false;
    io_ = std::thread([this] { receiver_loop(); });
    return LENNY_OK;
}

wire::PairToken Session::new_pair_token(uint32_t ttl_ms) {
    return tokens_.issue(now_us(), ttl_ms ? int64_t(ttl_ms) * kMs : TokenStore::kDefaultTtlUs);
}

void Session::trust(const wire::DeviceId& id) {
    std::lock_guard lock(trust_mu_);
    trusted_.insert(id);
}

bool Session::trusted(const wire::DeviceId& id) {
    std::lock_guard lock(trust_mu_);
    return trusted_.count(id) > 0;
}

int32_t Session::approve(bool accept) {
    if (role_ != Role::Receiver || state_ != LENNY_STATE_AWAITING_APPROVAL) return LENNY_E_STATE;
    approval_ = accept ? 1 : 0;
    return LENNY_OK;
}

int32_t Session::send_control(lenny_control& c) {
    if (role_ != Role::Receiver) return LENNY_E_STATE;
    if (c.cmd < LENNY_CTL_KEYFRAME_REQUEST || c.cmd > LENNY_CTL_RESET_AUTO) return LENNY_E_INVALID_ARG;
    if (!streaming_) return LENNY_E_STATE;
    c.req_id = next_req_id_++;
    return send(wire::Control{c}) ? LENNY_OK : LENNY_E_IO;
}

// ---- public: common ------------------------------------------------------
void Session::set_state_listener(void (*fn)(void*, lenny_state, int32_t), void* user) {
    std::lock_guard lock(listener_mu_);
    listener_fn_ = fn;
    listener_user_ = user;
}

lenny_stats Session::stats() {
    std::lock_guard lock(stats_mu_);
    lenny_stats s = stats_;
    s.rtt_us = clock_.rtt_us();
    s.clock_offset_us = clock_.offset_us();
    return s;
}

void Session::disconnect() {
    stop_ = true;
    std::lock_guard lock(sleep_mu_);
    sleep_cv_.notify_all();
}

// ---- I/O thread ------------------------------------------------------------
void Session::sleep_interruptible(int ms) {
    std::unique_lock lock(sleep_mu_);
    sleep_cv_.wait_for(lock, std::chrono::milliseconds(ms), [&] { return stop_.load(); });
}

void Session::set_state(lenny_state s, int32_t reason) {
    const lenny_state old = state_.exchange(s);
    const int32_t old_reason = last_reason_.exchange(reason);
    if (old == s && old_reason == reason) return;
    if (role_ == Role::Sender && scb_.on_state) scb_.on_state(scb_.user, s, reason);
    if (role_ == Role::Receiver && rcb_.on_state) rcb_.on_state(rcb_.user, s, reason);
    void (*fn)(void*, lenny_state, int32_t);
    void* user;
    {
        std::lock_guard lock(listener_mu_);
        fn = listener_fn_;
        user = listener_user_;
    }
    if (fn) fn(user, s, reason);
}

void Session::sender_loop(std::string host, uint16_t port) {
    int attempt = 0;
    int32_t reason = LENNY_REASON_NORMAL;
    set_state(LENNY_STATE_CONNECTING);
    while (!stop_) {
        if (auto t = tcp_connect(host, port, kConnectTimeoutMs, stop_)) {
            reason = run_link(std::shared_ptr<ITransport>(std::move(t)));
            if (reached_streaming_) attempt = 0;
            if (fatal_for_sender(reason)) break;
        } else {
            reason = LENNY_REASON_LINK_LOST;
        }
        if (stop_) break;
        set_state(LENNY_STATE_RECONNECTING, reason);
        sleep_interruptible(kBackoffMs[std::min(attempt++, 3)]);
    }
    set_state(LENNY_STATE_CLOSED, stop_ ? LENNY_REASON_USER : reason);
    io_done_ = true;
}

void Session::receiver_loop() {
    int32_t reason = LENNY_REASON_NORMAL;  // why the last phone left, for the UI's error state
    while (!stop_) {
        set_state(LENNY_STATE_CONNECTING, reason);
        if (auto t = listener_.accept(200)) reason = run_link(std::shared_ptr<ITransport>(std::move(t)));
    }
    listener_.close();
    set_state(LENNY_STATE_CLOSED, LENNY_REASON_USER);
    io_done_ = true;
}

void Session::enter(Phase p, int64_t now, int64_t timeout_us) {
    phase_ = p;
    phase_deadline_ = now + timeout_us;
}

int32_t Session::run_link(std::shared_ptr<ITransport> t) {
    {
        std::lock_guard lock(link_mu_);
        link_ = t;
    }
    const int64_t start = now_us();
    enter(Phase::HelloWait, start, kHelloTimeout);
    last_rx_ = start;
    peer_ = {};
    peer_caps_ = {};
    minor_ = wire::kVersionMinor;
    reached_streaming_ = false;
    approval_ = -1;
    {
        std::lock_guard lock(stats_mu_);
        clock_ = {};
    }
    set_state(LENNY_STATE_HANDSHAKE);

    int32_t result = kContinue;
    if (role_ == Role::Sender && !send(hello_)) result = LENNY_REASON_LINK_LOST;

    wire::MessageReader reader;
    std::vector<uint8_t> buf(64 * 1024);
    while (result == kContinue) {
        if (stop_) {
            result = goodbye(bye_reason_);
            break;
        }
        const int n = t->recv(buf.data(), buf.size(), 50);
        const int64_t now = now_us();
        if (n < 0) {
            result = LENNY_REASON_LINK_LOST;
            break;
        }
        if (n > 0) {
            last_rx_ = now;
            reader.feed(buf.data(), size_t(n));
            for (;;) {
                wire::Header h;
                wire::View p;
                const auto st = reader.next(h, p);
                if (st == wire::MessageReader::Status::NeedMore) break;
                // TCP has no resync point after garbage, so framing errors end the link (§3 rules 1, 3).
                if (st != wire::MessageReader::Status::Message) {
                    result = goodbye(LENNY_REASON_PROTOCOL_ERROR);
                    break;
                }
                result = dispatch(h, p, now);
                if (result != kContinue) break;
            }
        }
        if (result == kContinue) result = tick(now);
    }

    streaming_ = false;
    {
        std::lock_guard lock(link_mu_);
        link_.reset();
    }
    t->shutdown();  // also wakes any sender thread blocked in send_all
    return result;
}

int32_t Session::tick(int64_t now) {
    if (now - last_rx_ > kSilenceLimit) return LENNY_REASON_LINK_LOST;
    if (phase_ == Phase::ApprovalWait) {
        const int a = approval_.load();
        if (a == 0) return goodbye(LENNY_REASON_PAIR_DENIED);
        if (a == 1) {
            trust(peer_.device_id);
            on_caps_complete(now);
        }
    }
    if (phase_ != Phase::Streaming && now > phase_deadline_)
        return goodbye(phase_ == Phase::ApprovalWait ? LENNY_REASON_PAIR_DENIED : LENNY_REASON_TIMEOUT);
    if (phase_ != Phase::HelloWait && now >= next_ping_) {
        next_ping_ = now + kPingInterval;
        if (!send(wire::Ping{++ping_seq_, now})) return LENNY_REASON_LINK_LOST;
    }
    if (role_ == Role::Receiver) {
        // One phone at a time (§7). Tell extra callers right away instead of leaving them hanging.
        if (auto extra = listener_.accept(0)) {
            // The close may RST before the phone reads this; it then sees LINK_LOST instead. Both mean "retry".
            auto bye = wire::to_message(wire::Goodbye{LENNY_REASON_BUSY, "another phone is streaming"});
            extra->send_all(bye.data(), bye.size());
        }
    }
    return kContinue;
}

int32_t Session::goodbye(int32_t reason) {
    auto bytes = wire::to_message(wire::Goodbye{uint16_t(reason), {}}, minor_);
    std::shared_ptr<ITransport> t;
    {
        std::lock_guard lock(link_mu_);
        t = link_;
    }
    // Best effort: if another thread is stuck mid-send, don't wait on it just to say goodbye.
    // (Polling try_lock, not timed_mutex: glibc's timed lock is invisible to TSan and trips false positives.)
    for (int i = 0; t && i < 20; ++i) {
        if (send_mu_.try_lock()) {
            t->send_all(bytes.data(), bytes.size());
            send_mu_.unlock();
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return reason;
}

bool Session::send_raw(const uint8_t* a, size_t na, const uint8_t* b, size_t nb) {
    std::shared_ptr<ITransport> t;
    {
        std::lock_guard lock(link_mu_);
        t = link_;
    }
    if (!t) return false;
    std::lock_guard lock(send_mu_);
    const bool ok = t->send_all(a, na) && (!b || t->send_all(b, nb));
    if (!ok) t->shutdown();  // I/O thread sees the dead link immediately and reconnects
    return ok;
}

void Session::send_caps(int64_t now) {
    send(caps_);
    enter(Phase::CapsWait, now, kSenderCapsTimeout);
}

void Session::on_caps_complete(int64_t now) {
    send(wire::CapsSelect{choose_settings(peer_caps_, preferred_)});
    enter(Phase::StreamStartWait, now, kCapsTimeout);
    set_state(LENNY_STATE_HANDSHAKE);
}

int32_t Session::on_hello(wire::View payload, int64_t now) {
    if (phase_ != Phase::HelloWait) return kContinue;  // duplicate HELLO: ignore
    wire::Hello h;
    if (!wire::decode(payload, h)) return goodbye(LENNY_REASON_PROTOCOL_ERROR);
    if (h.proto_major != wire::kVersionMajor) return goodbye(LENNY_REASON_VERSION);
    if (h.role == hello_.role) return goodbye(LENNY_REASON_ROLE);
    peer_ = h;
    minor_ = std::min(wire::kVersionMinor, h.proto_minor);
    next_ping_ = now + kPingInterval;
    if (role_ == Role::Receiver) {
        if (!send(hello_)) return LENNY_REASON_LINK_LOST;
        enter(Phase::PairOrCaps, now, kCapsTimeout);
    } else if (!pair_token_.empty()) {
        wire::PairRequest r;
        std::copy(pair_token_.begin(), pair_token_.end(), r.token.begin());
        send(r);
        enter(Phase::PairWait, now, kPairTimeout);
    } else {
        send_caps(now);
    }
    return kContinue;
}

int32_t Session::dispatch(const wire::Header& h, wire::View p, int64_t now) {
    if (h.ver_major != wire::kVersionMajor) return goodbye(LENNY_REASON_VERSION);
    switch (static_cast<wire::MsgType>(h.type)) {
        case wire::MsgType::Hello: return on_hello(p, now);
        case wire::MsgType::Goodbye: {
            wire::Goodbye g;
            return wire::decode(p, g) ? int32_t(g.reason) : LENNY_REASON_PROTOCOL_ERROR;
        }
        default: break;
    }
    if (phase_ == Phase::HelloWait) return kContinue;  // nothing else is valid before HELLO
    switch (static_cast<wire::MsgType>(h.type)) {
        case wire::MsgType::Ping: {
            wire::Ping ping;
            if (wire::decode(p, ping) && !send(wire::Pong{ping.seq, ping.t1, now, now_us()})) return LENNY_REASON_LINK_LOST;
            return kContinue;
        }
        case wire::MsgType::Pong: {
            wire::Pong pong;
            if (wire::decode(p, pong)) {
                std::lock_guard lock(stats_mu_);
                clock_.add(pong.t1, pong.t2, pong.t3, now);
            }
            return kContinue;
        }
        default: break;
    }
    return role_ == Role::Sender ? dispatch_sender(h, p, now) : dispatch_receiver(h, p, now);
}

int32_t Session::dispatch_sender(const wire::Header& h, wire::View p, int64_t now) {
    switch (static_cast<wire::MsgType>(h.type)) {
        case wire::MsgType::PairResult: {
            wire::PairResult r;
            if (phase_ != Phase::PairWait || !wire::decode(p, r)) break;
            if (r.result != LENNY_PAIR_OK) return LENNY_REASON_PAIR_DENIED;
            pair_token_.clear();  // single-use; the receiver now trusts our device_id
            send_caps(now);
            break;
        }
        case wire::MsgType::CapsSelect: {
            wire::CapsSelect sel;
            if ((phase_ != Phase::CapsWait && phase_ != Phase::Streaming) || !wire::decode(p, sel)) break;
            lenny_stream_settings eff = sel.s;
            if (scb_.on_stream_config) scb_.on_stream_config(scb_.user, &sel.s, &eff);
            if (!send(wire::StreamStart{eff})) return LENNY_REASON_LINK_LOST;
            if (phase_ != Phase::Streaming) {
                enter(Phase::Streaming, now, 0);
                reached_streaming_ = true;
                if (ever_streamed_) {
                    std::lock_guard lock(stats_mu_);
                    stats_.reconnects++;
                }
                ever_streamed_ = true;
                streaming_ = true;
                set_state(LENNY_STATE_STREAMING);
            }
            // New stream or new settings: the receiver needs a keyframe (plus config) to start decoding.
            lenny_control key{0, LENNY_CTL_KEYFRAME_REQUEST, 0, 0, 0};
            if (scb_.on_control) scb_.on_control(scb_.user, &key);
            break;
        }
        case wire::MsgType::Control: {
            wire::Control c;
            if (phase_ != Phase::Streaming) break;
            if (!wire::decode(p, c)) {
                std::lock_guard lock(stats_mu_);
                stats_.bad_messages++;
                break;
            }
            int32_t r = scb_.on_control ? scb_.on_control(scb_.user, &c.c) : LENNY_ACK_UNSUPPORTED;
            send(wire::ControlAck{c.c.req_id, uint8_t(r)});
            break;
        }
        default: break;  // unknown or not for us: ignore (§3 rule 4)
    }
    return kContinue;
}

int32_t Session::dispatch_receiver(const wire::Header& h, wire::View p, int64_t now) {
    const auto bad = [&] {
        std::lock_guard lock(stats_mu_);
        stats_.bad_messages++;
    };
    switch (static_cast<wire::MsgType>(h.type)) {
        case wire::MsgType::PairRequest: {
            wire::PairRequest r;
            if (phase_ != Phase::PairOrCaps || !wire::decode(p, r)) break;
            const uint8_t result = tokens_.redeem(r.token, now);
            send(wire::PairResult{result});
            if (result != LENNY_PAIR_OK) return goodbye(LENNY_REASON_PAIR_DENIED);
            trust(peer_.device_id);
            enter(Phase::PairOrCaps, now, kCapsTimeout);
            break;
        }
        case wire::MsgType::Caps: {
            if (phase_ != Phase::PairOrCaps) break;
            if (!wire::decode(p, peer_caps_)) return goodbye(LENNY_REASON_PROTOCOL_ERROR);
            if (trusted(peer_.device_id)) {
                on_caps_complete(now);
            } else {
                approval_ = -1;
                enter(Phase::ApprovalWait, now, kApprovalTimeout);
                set_state(LENNY_STATE_AWAITING_APPROVAL);
                if (rcb_.on_approval_needed)
                    rcb_.on_approval_needed(rcb_.user, peer_.device_id.data(), peer_.device_name.c_str());
            }
            break;
        }
        case wire::MsgType::StreamStart: {
            wire::StreamStart s;
            if ((phase_ != Phase::StreamStartWait && phase_ != Phase::Streaming) || !wire::decode(p, s)) break;
            if (phase_ != Phase::Streaming) {
                enter(Phase::Streaming, now, 0);
                streaming_ = true;
                set_state(LENNY_STATE_STREAMING);
            }
            if (rcb_.on_stream_start) rcb_.on_stream_start(rcb_.user, &s.s);
            break;
        }
        default: break;
    }
    if (phase_ != Phase::Streaming) return kContinue;

    switch (static_cast<wire::MsgType>(h.type)) {
        case wire::MsgType::VideoConfig: {
            wire::VideoConfig vc;
            if (!wire::decode(p, vc)) { bad(); break; }
            if (rcb_.on_video_config) rcb_.on_video_config(rcb_.user, vc.config.data(), vc.config.size());
            break;
        }
        case wire::MsgType::VideoFrame: {
            wire::VideoFrameMeta m;
            wire::View data;
            if (!wire::decode_video_meta(p, m, data)) { bad(); break; }
            lenny_video_frame f{m.frame_seq, m.pts_us, 0, m.orientation, m.flags, data.data(), data.size()};
            {
                std::lock_guard lock(stats_mu_);
                if (clock_.valid()) f.local_pts_us = m.pts_us - clock_.offset_us();
                stats_.frames++;
                stats_.bytes += data.size();
            }
            if (rcb_.on_video_frame) rcb_.on_video_frame(rcb_.user, &f);
            break;
        }
        case wire::MsgType::ControlState: {
            wire::ControlState s;
            if (!wire::decode(p, s)) { bad(); break; }
            if (rcb_.on_control_state) rcb_.on_control_state(rcb_.user, &s.s);
            break;
        }
        case wire::MsgType::ControlAck: {
            wire::ControlAck a;
            if (!wire::decode(p, a)) { bad(); break; }
            if (rcb_.on_control_ack) rcb_.on_control_ack(rcb_.user, a.req_id, a.result);
            break;
        }
        case wire::MsgType::StreamStatus: {
            wire::StreamStatus s;
            if (!wire::decode(p, s)) { bad(); break; }
            if (rcb_.on_stream_status) rcb_.on_stream_status(rcb_.user, s.state, s.reason.c_str());
            break;
        }
        default: break;
    }
    return kContinue;
}

}  // namespace lenny
