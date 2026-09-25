// C ABI over lenny::Session. Nothing may throw past this file (architecture.md §4.1).
#include <algorithm>
#include <new>

#include "lenny/lenny.h"
#include "session.hpp"

struct lenny_session : lenny::Session {
    using Session::Session;
};

namespace {

template <class F>
int32_t guard(F&& f) {
    try {
        return f();
    } catch (...) {
        return LENNY_E_INTERNAL;
    }
}

lenny::wire::DeviceId to_id(const uint8_t* p) {
    lenny::wire::DeviceId id;
    std::copy(p, p + id.size(), id.begin());
    return id;
}

}  // namespace

extern "C" {

LENNY_API uint32_t lenny_abi_version(void) { return (LENNY_ABI_VERSION_MAJOR << 16) | LENNY_ABI_VERSION_MINOR; }

LENNY_API int64_t lenny_now_us(void) { return lenny::now_us(); }

LENNY_API lenny_session* lenny_sender_create(const lenny_sender_config* config, const lenny_sender_callbacks* callbacks) {
    if (!config || (config->mode_count && !config->modes) || (config->lens_count && !config->lenses)) return nullptr;
    try {
        lenny_sender_callbacks cb{};
        if (callbacks) cb = *callbacks;
        return new lenny_session(*config, cb);
    } catch (...) {
        return nullptr;
    }
}

LENNY_API int32_t lenny_sender_connect(lenny_session* s, const char* host, uint16_t port, const uint8_t* pair_token) {
    if (!s || !host) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->connect(host, port, pair_token); });
}

LENNY_API int32_t lenny_sender_send_video_config(lenny_session* s, const uint8_t* data, size_t size) {
    if (!s) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->send_video_config(data, size); });
}

LENNY_API int32_t lenny_sender_send_video_frame(lenny_session* s, const uint8_t* data, size_t size, int64_t pts_us,
                                                uint8_t orientation, uint8_t flags) {
    if (!s) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->send_video_frame(data, size, pts_us, orientation, flags); });
}

LENNY_API int32_t lenny_sender_send_control_state(lenny_session* s, const lenny_control_state* state) {
    if (!s || !state) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->send_control_state(*state); });
}

LENNY_API int32_t lenny_sender_send_stream_status(lenny_session* s, uint8_t state, const char* reason) {
    if (!s) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->send_stream_status(state, reason); });
}

LENNY_API lenny_session* lenny_receiver_create(const lenny_receiver_config* config,
                                               const lenny_receiver_callbacks* callbacks) {
    if (!config) return nullptr;
    try {
        lenny_receiver_callbacks cb{};
        if (callbacks) cb = *callbacks;
        return new lenny_session(*config, cb);
    } catch (...) {
        return nullptr;
    }
}

LENNY_API int32_t lenny_receiver_start(lenny_session* s) {
    if (!s) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->start(); });
}

LENNY_API uint16_t lenny_receiver_port(lenny_session* s) { return s ? s->port() : 0; }

LENNY_API int32_t lenny_receiver_new_pair_token(lenny_session* s, uint32_t ttl_ms, uint8_t out[LENNY_PAIR_TOKEN_SIZE]) {
    if (!s || !out || s->role() != lenny::Role::Receiver) return LENNY_E_INVALID_ARG;
    return guard([&] {
        auto t = s->new_pair_token(ttl_ms);
        std::copy(t.begin(), t.end(), out);
        return LENNY_OK;
    });
}

LENNY_API int32_t lenny_receiver_trust_device(lenny_session* s, const uint8_t device_id[LENNY_DEVICE_ID_SIZE]) {
    if (!s || !device_id) return LENNY_E_INVALID_ARG;
    return guard([&] {
        s->trust(to_id(device_id));
        return LENNY_OK;
    });
}

LENNY_API int32_t lenny_receiver_approve(lenny_session* s, int32_t accept) {
    if (!s) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->approve(accept != 0); });
}

LENNY_API int32_t lenny_receiver_send_control(lenny_session* s, lenny_control* control) {
    if (!s || !control) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->send_control(*control); });
}

LENNY_API int32_t lenny_session_set_event_listener(lenny_session* s, void (*fn)(void*, int32_t, int32_t, int32_t),
                                                   void* user) {
    if (!s) return LENNY_E_INVALID_ARG;
    return guard([&] {
        s->set_event_listener(fn, user);
        return LENNY_OK;
    });
}

LENNY_API int32_t lenny_session_peer(lenny_session* s, lenny_peer_info* out) {
    if (!s || !out) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->peer(*out) ? LENNY_OK : LENNY_E_STATE; });
}

LENNY_API int32_t lenny_session_stream_settings(lenny_session* s, lenny_stream_settings* out) {
    if (!s || !out) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->stream_settings(*out) ? LENNY_OK : LENNY_E_STATE; });
}

LENNY_API int32_t lenny_session_control_state(lenny_session* s, lenny_control_state* out) {
    if (!s || !out) return LENNY_E_INVALID_ARG;
    return guard([&] { return s->control_state(*out) ? LENNY_OK : LENNY_E_STATE; });
}

LENNY_API int32_t lenny_session_state(lenny_session* s) { return s ? s->state() : LENNY_STATE_CLOSED; }

LENNY_API int32_t lenny_session_get_stats(lenny_session* s, lenny_stats* out) {
    if (!s || !out) return LENNY_E_INVALID_ARG;
    return guard([&] {
        *out = s->stats();
        return LENNY_OK;
    });
}

LENNY_API int32_t lenny_session_disconnect(lenny_session* s) {
    if (!s) return LENNY_E_INVALID_ARG;
    return guard([&] {
        s->disconnect();
        return LENNY_OK;
    });
}

LENNY_API void lenny_session_destroy(lenny_session* s) {
    try {
        delete s;
    } catch (...) {
    }
}

}  // extern "C"
