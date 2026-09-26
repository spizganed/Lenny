#include "wire.hpp"

#include <algorithm>
#include <cstring>

namespace lenny::wire {

namespace {

template <class T>
void put_le(uint8_t* p, T v) {
    using U = std::make_unsigned_t<T>;
    auto u = static_cast<U>(v);
    for (size_t i = 0; i < sizeof(T); ++i) p[i] = static_cast<uint8_t>(u >> (8 * i));
}

template <class T>
T get_le(const uint8_t* p) {
    using U = std::make_unsigned_t<T>;
    U u = 0;
    for (size_t i = 0; i < sizeof(T); ++i) u |= static_cast<U>(p[i]) << (8 * i);
    return static_cast<T>(u);
}

template <class T>
bool get_exact(View v, T& out) {
    if (v.size() != sizeof(T)) return false;
    out = get_le<T>(v.data());
    return true;
}

uint32_t max_payload(uint16_t type) {
    return type == static_cast<uint16_t>(MsgType::VideoFrame) ? kMaxVideoPayload : kMaxControlPayload;
}

}  // namespace

void put_header(uint8_t out[kHeaderSize], const Header& h) {
    out[0] = kMagic0;
    out[1] = kMagic1;
    out[2] = h.ver_major;
    out[3] = h.ver_minor;
    put_le(out + 4, h.type);
    put_le(out + 6, h.flags);
    put_le(out + 8, h.length);
}

void MessageReader::feed(const uint8_t* data, size_t size) {
    if (pos_ > 0) {
        buf_.erase(buf_.begin(), buf_.begin() + static_cast<std::ptrdiff_t>(pos_));
        pos_ = 0;
    }
    buf_.insert(buf_.end(), data, data + size);
}

MessageReader::Status MessageReader::next(Header& h, View& payload) {
    const size_t avail = buf_.size() - pos_;
    if (avail < kHeaderSize) return Status::NeedMore;
    const uint8_t* p = buf_.data() + pos_;
    if (p[0] != kMagic0 || p[1] != kMagic1) return Status::BadMagic;
    h.ver_major = p[2];
    h.ver_minor = p[3];
    h.type = get_le<uint16_t>(p + 4);
    h.flags = get_le<uint16_t>(p + 6);
    h.length = get_le<uint32_t>(p + 8);
    if (h.length > max_payload(h.type)) return Status::TooLarge;
    if (avail < kHeaderSize + h.length) return Status::NeedMore;
    payload = View(p + kHeaderSize, h.length);
    pos_ += kHeaderSize + h.length;
    return Status::Message;
}

// ---- TLV ---------------------------------------------------------------
void TlvWriter::head(uint16_t tag, size_t len) {
    uint8_t h[4];
    put_le(h, tag);
    put_le(h + 2, static_cast<uint16_t>(len));
    out_.insert(out_.end(), h, h + 4);
}

void TlvWriter::u8(uint16_t tag, uint8_t v) { head(tag, 1); out_.push_back(v); }

#define LENNY_TLV_INT(name, T)                        \
    void TlvWriter::name(uint16_t tag, T v) {         \
        head(tag, sizeof(T));                         \
        uint8_t b[sizeof(T)];                         \
        put_le(b, v);                                 \
        out_.insert(out_.end(), b, b + sizeof(T));    \
    }
LENNY_TLV_INT(u16, uint16_t)
LENNY_TLV_INT(u32, uint32_t)
LENNY_TLV_INT(u64, uint64_t)
LENNY_TLV_INT(i32, int32_t)
LENNY_TLV_INT(i64, int64_t)
#undef LENNY_TLV_INT

void TlvWriter::str(uint16_t tag, std::string_view v) {
    // ponytail: byte truncation can split a UTF-8 sequence; only matters for >64 KiB names.
    v = v.substr(0, 0xFFFF);
    head(tag, v.size());
    out_.insert(out_.end(), v.begin(), v.end());
}

void TlvWriter::bytes(uint16_t tag, View v) {
    head(tag, v.size());
    out_.insert(out_.end(), v.begin(), v.end());
}

void TlvWriter::empty(uint16_t tag) { head(tag, 0); }

size_t TlvWriter::begin_list(uint16_t tag) {
    head(tag, 0);
    return out_.size();
}

void TlvWriter::end_list(size_t mark) {
    put_le(out_.data() + mark - 2, static_cast<uint16_t>(out_.size() - mark));
}

bool TlvReader::next(TlvField& f) {
    if (pos_ == v_.size()) return false;
    if (v_.size() - pos_ < 4) { bad_ = true; return false; }
    f.tag = get_le<uint16_t>(v_.data() + pos_);
    const uint16_t len = get_le<uint16_t>(v_.data() + pos_ + 2);
    pos_ += 4;
    if (v_.size() - pos_ < len) { bad_ = true; return false; }
    f.value = v_.subspan(pos_, len);
    pos_ += len;
    return true;
}

bool get(View v, uint8_t& out) { return get_exact(v, out); }
bool get(View v, uint16_t& out) { return get_exact(v, out); }
bool get(View v, uint32_t& out) { return get_exact(v, out); }
bool get(View v, uint64_t& out) { return get_exact(v, out); }
bool get(View v, int32_t& out) { return get_exact(v, out); }
bool get(View v, int64_t& out) { return get_exact(v, out); }

namespace {
// Iterates fields; `fn(tag, value)` returns false to reject the message. Unknown tags: fn returns true.
template <class Fn>
bool each(View v, Fn&& fn) {
    TlvReader r(v);
    TlvField f;
    while (r.next(f))
        if (!fn(f.tag, f.value)) return false;
    return !r.bad();
}

void encode_settings(TlvWriter& w, const lenny_stream_settings& s) {
    w.u8(1, s.codec);
    w.u16(2, s.mode.width);
    w.u16(3, s.mode.height);
    w.u16(4, s.mode.fps_num);
    w.u16(5, s.mode.fps_den);
    w.u32(6, s.bitrate_kbps);
    if (s.has_lens) w.u8(7, s.lens_id);
}

bool decode_settings(View v, lenny_stream_settings& s) {
    s = {};
    unsigned seen = 0;
    bool ok = each(v, [&](uint16_t tag, View val) {
        switch (tag) {
            case 1: seen |= 1; return get(val, s.codec);
            case 2: seen |= 2; return get(val, s.mode.width);
            case 3: seen |= 4; return get(val, s.mode.height);
            case 4: seen |= 8; return get(val, s.mode.fps_num);
            case 5: seen |= 16; return get(val, s.mode.fps_den);
            case 6: return get(val, s.bitrate_kbps);
            case 7: s.has_lens = 1; return get(val, s.lens_id);
            default: return true;
        }
    });
    return ok && seen == 31 && s.mode.fps_den != 0;
}
}  // namespace

// ---- HELLO -------------------------------------------------------------
void encode(TlvWriter& w, const Hello& m) {
    w.u8(1, m.proto_major);
    w.u8(2, m.proto_minor);
    w.u8(3, m.role);
    w.bytes(4, m.device_id);
    w.str(5, m.device_name);
    if (!m.app_version.empty()) w.str(6, m.app_version);
    if (m.platform) w.u8(7, m.platform);
    if (m.pairing_required) w.u8(8, 1);
    if (m.features) w.u64(9, m.features);
}

bool decode(View v, Hello& m) {
    m = {};
    unsigned seen = 0;
    bool ok = each(v, [&](uint16_t tag, View val) {
        switch (tag) {
            case 1: seen |= 1; return get(val, m.proto_major);
            case 2: seen |= 2; return get(val, m.proto_minor);
            case 3: seen |= 4; return get(val, m.role);
            case 4:
                seen |= 8;
                if (val.size() != m.device_id.size()) return false;
                std::copy(val.begin(), val.end(), m.device_id.begin());
                return true;
            case 5: seen |= 16; m.device_name = get_str(val); return true;
            case 6: m.app_version = get_str(val); return true;
            case 7: return get(val, m.platform);
            case 8: {
                uint8_t b = 0;
                if (!get(val, b)) return false;
                m.pairing_required = b != 0;
                return true;
            }
            case 9: return get(val, m.features);
            default: return true;
        }
    });
    return ok && seen == 31;
}

// ---- GOODBYE / PING / PONG ---------------------------------------------
void encode(TlvWriter& w, const Goodbye& m) {
    w.u16(1, m.reason);
    if (!m.detail.empty()) w.str(2, m.detail);
}

bool decode(View v, Goodbye& m) {
    m = {};
    bool seen = false;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag == 1) { seen = true; return get(val, m.reason); }
        if (tag == 2) m.detail = get_str(val);
        return true;
    });
    return ok && seen;
}

void encode(TlvWriter& w, const Ping& m) {
    w.u32(1, m.seq);
    w.i64(2, m.t1);
}

bool decode(View v, Ping& m) {
    m = {};
    unsigned seen = 0;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag == 1) { seen |= 1; return get(val, m.seq); }
        if (tag == 2) { seen |= 2; return get(val, m.t1); }
        return true;
    });
    return ok && seen == 3;
}

void encode(TlvWriter& w, const Pong& m) {
    w.u32(1, m.seq);
    w.i64(2, m.t1);
    w.i64(3, m.t2);
    w.i64(4, m.t3);
}

bool decode(View v, Pong& m) {
    m = {};
    unsigned seen = 0;
    bool ok = each(v, [&](uint16_t tag, View val) {
        switch (tag) {
            case 1: seen |= 1; return get(val, m.seq);
            case 2: seen |= 2; return get(val, m.t1);
            case 3: seen |= 4; return get(val, m.t2);
            case 4: seen |= 8; return get(val, m.t3);
            default: return true;
        }
    });
    return ok && seen == 15;
}

// ---- PAIR ----------------------------------------------------------------
void encode(TlvWriter& w, const PairRequest& m) { w.bytes(1, m.token); }

bool decode(View v, PairRequest& m) {
    m = {};
    bool seen = false;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag != 1) return true;
        if (val.size() != m.token.size()) return false;
        std::copy(val.begin(), val.end(), m.token.begin());
        seen = true;
        return true;
    });
    return ok && seen;
}

void encode(TlvWriter& w, const PairResult& m) { w.u8(1, m.result); }

bool decode(View v, PairResult& m) {
    m = {};
    bool seen = false;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag == 1) { seen = true; return get(val, m.result); }
        return true;
    });
    return ok && seen;
}

// ---- CAPS ------------------------------------------------------------------
void encode(TlvWriter& w, const Caps& m) {
    for (const auto& c : m.codecs) {
        size_t l = w.begin_list(1);
        w.u8(1, c.id);
        w.u8(2, c.profile);
        w.u8(3, c.level);
        w.end_list(l);
    }
    for (const auto& md : m.modes) {
        size_t l = w.begin_list(2);
        w.u16(1, md.width);
        w.u16(2, md.height);
        w.u16(3, md.fps_num);
        w.u16(4, md.fps_den);
        w.end_list(l);
    }
    w.u32(3, m.max_bitrate_kbps);
    w.u64(4, m.controls);
    for (const auto& lens : m.lenses) {
        size_t l = w.begin_list(5);
        w.u8(1, lens.id);
        w.u8(2, lens.facing);
        w.str(3, lens.label);
        w.end_list(l);
    }
    if (m.has_exposure_range) {
        size_t l = w.begin_list(6);
        w.i32(1, m.exposure_min);
        w.i32(2, m.exposure_max);
        w.u32(3, m.exposure_step_milli);
        w.end_list(l);
    }
}

bool decode(View v, Caps& m) {
    m = {};
    return each(v, [&](uint16_t tag, View val) {
        switch (tag) {
            case 1: {
                auto& cc = m.codecs.emplace_back();
                return each(val, [&](uint16_t t, View x) {
                    if (t == 1) return get(x, cc.id);
                    if (t == 2) return get(x, cc.profile);
                    if (t == 3) return get(x, cc.level);
                    return true;
                });
            }
            case 2: {
                lenny_mode md{};
                unsigned seen = 0;
                bool ok = each(val, [&](uint16_t t, View x) {
                    if (t == 1) { seen |= 1; return get(x, md.width); }
                    if (t == 2) { seen |= 2; return get(x, md.height); }
                    if (t == 3) { seen |= 4; return get(x, md.fps_num); }
                    if (t == 4) { seen |= 8; return get(x, md.fps_den); }
                    return true;
                });
                if (!ok || seen != 15 || md.fps_den == 0) return false;
                m.modes.push_back(md);
                return true;
            }
            case 3: return get(val, m.max_bitrate_kbps);
            case 4: return get(val, m.controls);
            case 5: {
                auto& l = m.lenses.emplace_back();
                return each(val, [&](uint16_t t, View x) {
                    if (t == 1) return get(x, l.id);
                    if (t == 2) return get(x, l.facing);
                    if (t == 3) l.label = get_str(x);
                    return true;
                });
            }
            case 6:
                m.has_exposure_range = true;
                return each(val, [&](uint16_t t, View x) {
                    if (t == 1) return get(x, m.exposure_min);
                    if (t == 2) return get(x, m.exposure_max);
                    if (t == 3) return get(x, m.exposure_step_milli);
                    return true;
                });
            default: return true;
        }
    });
}

void encode(TlvWriter& w, const CapsSelect& m) { encode_settings(w, m.s); }
bool decode(View v, CapsSelect& m) { return decode_settings(v, m.s); }
void encode(TlvWriter& w, const StreamStart& m) { encode_settings(w, m.s); }
bool decode(View v, StreamStart& m) { return decode_settings(v, m.s); }

void encode(TlvWriter& w, const StreamStatus& m) {
    w.u8(1, m.state);
    if (!m.reason.empty()) w.str(2, m.reason);
}

bool decode(View v, StreamStatus& m) {
    m = {};
    bool seen = false;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag == 1) { seen = true; return get(val, m.state); }
        if (tag == 2) m.reason = get_str(val);
        return true;
    });
    return ok && seen;
}

// ---- VIDEO -----------------------------------------------------------------
void encode(TlvWriter& w, const VideoConfig& m) {
    w.u8(1, m.codec);
    w.bytes(2, m.config);
}

bool decode(View v, VideoConfig& m) {
    m = {};
    bool seen = false;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag == 1) return get(val, m.codec);
        if (tag == 2) { seen = true; m.config.assign(val.begin(), val.end()); }
        return true;
    });
    return ok && seen;
}

void encode_video_meta(uint8_t out[kVideoFrameMetaSize], const VideoFrameMeta& m) {
    put_le(out, m.frame_seq);
    put_le(out + 4, m.pts_us);
    out[12] = m.orientation;
    out[13] = m.flags;
    out[14] = 0;
    out[15] = 0;
}

bool decode_video_meta(View payload, VideoFrameMeta& m, View& data) {
    if (payload.size() < kVideoFrameMetaSize) return false;
    const uint8_t* p = payload.data();
    m.frame_seq = get_le<uint32_t>(p);
    m.pts_us = get_le<int64_t>(p + 4);
    m.orientation = p[12] & 3;
    m.flags = p[13];
    data = payload.subspan(kVideoFrameMetaSize);
    return true;
}

// ---- CONTROL -----------------------------------------------------------------
void encode(TlvWriter& w, const Control& m) {
    const auto& c = m.c;
    w.u32(1, c.req_id);
    switch (c.cmd) {
        case LENNY_CTL_FOCUS_AT: {
            size_t l = w.begin_list(c.cmd);
            w.u16(1, c.x);
            w.u16(2, c.y);
            w.end_list(l);
            break;
        }
        case LENNY_CTL_FOCUS_LOCK:
        case LENNY_CTL_EXPOSURE_LOCK:
        case LENNY_CTL_WB_LOCK:
        case LENNY_CTL_TORCH: w.u8(c.cmd, c.value ? 1 : 0); break;
        case LENNY_CTL_SELECT_LENS: w.u8(c.cmd, static_cast<uint8_t>(c.value)); break;
        case LENNY_CTL_ZOOM: w.u16(c.cmd, static_cast<uint16_t>(c.value)); break;
        case LENNY_CTL_EXPOSURE_COMP: w.i32(c.cmd, c.value); break;
        default: w.empty(c.cmd); break;  // KEYFRAME_REQUEST, FOCUS_AUTO, RESET_AUTO
    }
}

bool decode(View v, Control& m) {
    m = {};
    auto& c = m.c;
    bool has_id = false;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag == 1) { has_id = true; return get(val, c.req_id); }
        if (tag < LENNY_CTL_KEYFRAME_REQUEST || tag > LENNY_CTL_RESET_AUTO || c.cmd) return true;
        c.cmd = tag;
        uint8_t b = 0;
        uint16_t z = 0;
        switch (tag) {
            case LENNY_CTL_FOCUS_AT:
                return each(val, [&](uint16_t t, View x) {
                    if (t == 1) return get(x, c.x);
                    if (t == 2) return get(x, c.y);
                    return true;
                });
            case LENNY_CTL_FOCUS_LOCK:
            case LENNY_CTL_EXPOSURE_LOCK:
            case LENNY_CTL_WB_LOCK:
            case LENNY_CTL_TORCH:
            case LENNY_CTL_SELECT_LENS:
                if (!get(val, b)) return false;
                c.value = b;
                return true;
            case LENNY_CTL_ZOOM:
                if (!get(val, z)) return false;
                c.value = z;
                return true;
            case LENNY_CTL_EXPOSURE_COMP: return get(val, c.value);
            default: return true;
        }
    });
    return ok && has_id && c.cmd != 0;
}

void encode(TlvWriter& w, const ControlAck& m) {
    w.u32(1, m.req_id);
    w.u8(2, m.result);
}

bool decode(View v, ControlAck& m) {
    m = {};
    unsigned seen = 0;
    bool ok = each(v, [&](uint16_t tag, View val) {
        if (tag == 1) { seen |= 1; return get(val, m.req_id); }
        if (tag == 2) { seen |= 2; return get(val, m.result); }
        return true;
    });
    return ok && seen == 3;
}

void encode(TlvWriter& w, const ControlState& m) {
    const auto& s = m.s;
    w.u8(1, s.af_mode);
    w.i32(2, s.exposure_comp);
    w.u8(3, s.exposure_lock);
    w.u8(4, s.wb_lock);
    w.u8(5, s.torch);
    w.u8(6, s.lens_id);
    w.u16(7, s.zoom);
    w.u8(8, s.battery);
    w.u8(9, s.charging);
}

bool decode(View v, ControlState& m) {
    m = {};
    auto& s = m.s;
    s.battery = 255;  // older phones don't send it
    return each(v, [&](uint16_t tag, View val) {
        switch (tag) {
            case 1: return get(val, s.af_mode);
            case 2: return get(val, s.exposure_comp);
            case 3: return get(val, s.exposure_lock);
            case 4: return get(val, s.wb_lock);
            case 5: return get(val, s.torch);
            case 6: return get(val, s.lens_id);
            case 7: return get(val, s.zoom);
            case 8: return get(val, s.battery);
            case 9: return get(val, s.charging);
            default: return true;
        }
    });
}

}  // namespace lenny::wire
