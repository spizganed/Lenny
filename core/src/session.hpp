// Session: handshake, pairing/approval, capability negotiation, keepalive, reconnect (protocol.md §7).
#pragma once

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "lenny/lenny.h"
#include "pairing.hpp"
#include "timing.hpp"
#include "transport.hpp"
#include "wire.hpp"

namespace lenny {

enum class Role : uint8_t { Sender = 1, Receiver = 2 };

class Session {
public:
    Session(const lenny_sender_config& cfg, const lenny_sender_callbacks& cb);
    Session(const lenny_receiver_config& cfg, const lenny_receiver_callbacks& cb);
    ~Session();
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    Role role() const { return role_; }

    // Sender
    int32_t connect(const std::string& host, uint16_t port, const uint8_t* pair_token);
    int32_t send_video_config(const uint8_t* data, size_t size);
    int32_t send_video_frame(const uint8_t* data, size_t size, int64_t pts_us, uint8_t orientation, uint8_t flags);
    int32_t send_control_state(const lenny_control_state& s);
    int32_t send_stream_status(uint8_t state, const char* reason);

    // Receiver
    int32_t start();
    uint16_t port() const { return listener_.port(); }
    wire::PairToken new_pair_token(uint32_t ttl_ms);
    void trust(const wire::DeviceId& id);
    int32_t approve(bool accept);
    int32_t send_control(lenny_control& c);

    // Common
    void set_state_listener(void (*fn)(void*, lenny_state, int32_t), void* user);
    lenny_state state() const { return state_.load(); }
    lenny_stats stats();
    void disconnect();

private:
    enum class Phase { HelloWait, PairWait, PairOrCaps, ApprovalWait, CapsWait, StreamStartWait, Streaming };
    enum : int32_t { kContinue = -1 };

    void sender_loop(std::string host, uint16_t port);
    void receiver_loop();
    // Runs one connection until it ends. Returns a LENNY_REASON_*.
    int32_t run_link(std::shared_ptr<ITransport> t);
    int32_t dispatch(const wire::Header& h, wire::View payload, int64_t now);
    int32_t tick(int64_t now);
    int32_t on_hello(wire::View payload, int64_t now);
    int32_t dispatch_sender(const wire::Header& h, wire::View payload, int64_t now);
    int32_t dispatch_receiver(const wire::Header& h, wire::View payload, int64_t now);
    bool join_finished_thread();
    void on_caps_complete(int64_t now);
    void send_caps(int64_t now);

    bool send_raw(const uint8_t* a, size_t na, const uint8_t* b = nullptr, size_t nb = 0);
    template <class M>
    bool send(const M& m) {
        auto bytes = wire::to_message(m, minor_);
        return send_raw(bytes.data(), bytes.size());
    }
    int32_t goodbye(int32_t reason);
    void set_state(lenny_state s, int32_t reason = 0);
    void enter(Phase p, int64_t now, int64_t timeout_us);
    bool trusted(const wire::DeviceId& id);
    void sleep_interruptible(int ms);

    const Role role_;
    wire::Hello hello_;  // our HELLO
    lenny_sender_callbacks scb_{};
    lenny_receiver_callbacks rcb_{};
    wire::Caps caps_;  // sender: ours
    lenny_stream_settings preferred_{};
    uint16_t listen_port_ = 0;

    std::thread io_;
    std::atomic<bool> stop_{false};
    std::atomic<bool> io_done_{true};
    std::atomic<int32_t> last_reason_{0};
    // GOODBYE sent when stopping: USER from disconnect() (phone stops retrying), NORMAL from the destructor
    // (app quitting/restarting: the phone keeps retrying and resumes when the app is back).
    std::atomic<int32_t> bye_reason_{LENNY_REASON_USER};
    std::mutex sleep_mu_;
    std::condition_variable sleep_cv_;
    std::atomic<lenny_state> state_{LENNY_STATE_IDLE};

    std::mutex listener_mu_;
    void (*listener_fn_)(void*, lenny_state, int32_t) = nullptr;
    void* listener_user_ = nullptr;

    // Current link. Written by the I/O thread; read by senders on other threads.
    std::mutex link_mu_;
    std::shared_ptr<ITransport> link_;
    std::timed_mutex send_mu_;  // serializes whole messages on the socket
    std::atomic<bool> streaming_{false};
    std::atomic<uint8_t> minor_{wire::kVersionMinor};  // negotiated; read by sender threads

    // I/O-thread-only link state
    Phase phase_ = Phase::HelloWait;
    int64_t phase_deadline_ = 0;
    int64_t last_rx_ = 0, next_ping_ = 0;
    uint32_t ping_seq_ = 0;
    wire::Hello peer_;
    wire::Caps peer_caps_;
    std::vector<uint8_t> pair_token_;  // sender: QR token still to redeem
    bool reached_streaming_ = false;  // this link got to STREAMING (resets sender backoff)
    bool ever_streamed_ = false;      // counts reconnects

    std::mutex video_mu_;
    wire::Bytes video_config_;  // sender: resent before every keyframe
    uint32_t frame_seq_ = 0;

    // Receiver
    TcpListener listener_;
    TokenStore tokens_;
    std::mutex trust_mu_;
    std::set<wire::DeviceId> trusted_;
    std::atomic<int> approval_{-1};  // -1 pending, 0 deny, 1 accept
    std::atomic<uint32_t> next_req_id_{1};

    std::mutex stats_mu_;
    ClockSync clock_;
    lenny_stats stats_{-1, 0, 0, 0, 0, 0};
};

}  // namespace lenny
