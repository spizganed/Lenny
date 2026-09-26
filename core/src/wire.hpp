// Wire format: framing, TLV, message codecs (docs/protocol.md §3–§6). Pure code, no I/O.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "lenny/lenny.h"

namespace lenny::wire {

using Bytes = std::vector<uint8_t>;
using View = std::span<const uint8_t>;

constexpr uint8_t kMagic0 = 0x4C;  // 'L'
constexpr uint8_t kMagic1 = 0x59;  // 'Y'
constexpr uint8_t kVersionMajor = 1;
constexpr uint8_t kVersionMinor = 0;
constexpr size_t kHeaderSize = 12;
constexpr uint32_t kMaxVideoPayload = 4u << 20;
constexpr uint32_t kMaxControlPayload = 64u << 10;
constexpr size_t kVideoFrameMetaSize = 16;

enum class MsgType : uint16_t {
    Hello = 0x0001,
    Goodbye = 0x0002,
    Ping = 0x0003,
    Pong = 0x0004,
    PairRequest = 0x0010,
    PairResult = 0x0011,
    Caps = 0x0020,
    CapsSelect = 0x0021,
    StreamStart = 0x0022,
    StreamStatus = 0x0023,
    VideoConfig = 0x0030,
    VideoFrame = 0x0031,
    Control = 0x0040,
    ControlState = 0x0041,
    ControlAck = 0x0042,
};

struct Header {
    uint8_t ver_major = kVersionMajor;
    uint8_t ver_minor = kVersionMinor;
    uint16_t type = 0;
    uint16_t flags = 0;
    uint32_t length = 0;
};

void put_header(uint8_t out[kHeaderSize], const Header& h);

// Incremental reassembly of messages from a byte stream. Unknown types come out like any other
// message; the caller ignores them (protocol.md §3 rule 4).
class MessageReader {
public:
    enum class Status { Message, NeedMore, BadMagic, TooLarge };

    // Invalidates any payload view returned earlier.
    void feed(const uint8_t* data, size_t size);
    // On Message, `payload` stays valid until the next feed().
    Status next(Header& header, View& payload);

private:
    Bytes buf_;
    size_t pos_ = 0;
};

// ---- TLV ---------------------------------------------------------------
class TlvWriter {
public:
    explicit TlvWriter(Bytes& out) : out_(out) {}
    void u8(uint16_t tag, uint8_t v);
    void u16(uint16_t tag, uint16_t v);
    void u32(uint16_t tag, uint32_t v);
    void u64(uint16_t tag, uint64_t v);
    void i32(uint16_t tag, int32_t v);
    void i64(uint16_t tag, int64_t v);
    void str(uint16_t tag, std::string_view v);  // truncated to 65535 bytes
    void bytes(uint16_t tag, View v);            // caller keeps it <= 65535
    void empty(uint16_t tag);
    size_t begin_list(uint16_t tag);
    void end_list(size_t mark);

private:
    void head(uint16_t tag, size_t len);
    Bytes& out_;
};

struct TlvField {
    uint16_t tag;
    View value;
};

class TlvReader {
public:
    explicit TlvReader(View v) : v_(v) {}
    // False at the end, or on a truncated field (then bad() is true).
    bool next(TlvField& f);
    bool bad() const { return bad_; }

private:
    View v_;
    size_t pos_ = 0;
    bool bad_ = false;
};

// Exact-size little-endian reads of a TLV value; false if the size is wrong.
bool get(View v, uint8_t& out);
bool get(View v, uint16_t& out);
bool get(View v, uint32_t& out);
bool get(View v, uint64_t& out);
bool get(View v, int32_t& out);
bool get(View v, int64_t& out);
inline std::string get_str(View v) { return {reinterpret_cast<const char*>(v.data()), v.size()}; }

// ---- Messages ----------------------------------------------------------
using DeviceId = std::array<uint8_t, LENNY_DEVICE_ID_SIZE>;
using PairToken = std::array<uint8_t, LENNY_PAIR_TOKEN_SIZE>;

struct Hello {
    static constexpr MsgType kType = MsgType::Hello;
    uint8_t proto_major = kVersionMajor;
    uint8_t proto_minor = kVersionMinor;
    uint8_t role = 0;  // 1 sender, 2 receiver
    DeviceId device_id{};
    std::string device_name;
    std::string app_version;  // optional (empty = absent)
    uint8_t platform = 0;     // optional (0 = absent)
    bool pairing_required = false;
    uint64_t features = 0;
};

struct Goodbye {
    static constexpr MsgType kType = MsgType::Goodbye;
    uint16_t reason = 0;
    std::string detail;
};

struct Ping {
    static constexpr MsgType kType = MsgType::Ping;
    uint32_t seq = 0;
    int64_t t1 = 0;
};

struct Pong {
    static constexpr MsgType kType = MsgType::Pong;
    uint32_t seq = 0;
    int64_t t1 = 0, t2 = 0, t3 = 0;
};

struct PairRequest {
    static constexpr MsgType kType = MsgType::PairRequest;
    PairToken token{};
};

struct PairResult {
    static constexpr MsgType kType = MsgType::PairResult;
    uint8_t result = 0;
};

struct Codec {
    uint8_t id = LENNY_CODEC_H264, profile = 0, level = 0;
};

struct Lens {
    uint8_t id = 0, facing = 0;
    std::string label;
};

struct Caps {
    static constexpr MsgType kType = MsgType::Caps;
    std::vector<Codec> codecs;
    std::vector<lenny_mode> modes;
    uint32_t max_bitrate_kbps = 0;
    uint64_t controls = 0;
    std::vector<Lens> lenses;
    bool has_exposure_range = false;
    int32_t exposure_min = 0, exposure_max = 0;
    uint32_t exposure_step_milli = 0;
};

struct CapsSelect {
    static constexpr MsgType kType = MsgType::CapsSelect;
    lenny_stream_settings s{};
};

struct StreamStart {
    static constexpr MsgType kType = MsgType::StreamStart;
    lenny_stream_settings s{};
};

struct StreamStatus {
    static constexpr MsgType kType = MsgType::StreamStatus;
    uint8_t state = 0;
    std::string reason;
};

struct VideoConfig {
    static constexpr MsgType kType = MsgType::VideoConfig;
    uint8_t codec = LENNY_CODEC_H264;
    Bytes config;
};

struct Control {
    static constexpr MsgType kType = MsgType::Control;
    lenny_control c{};
};

struct ControlAck {
    static constexpr MsgType kType = MsgType::ControlAck;
    uint32_t req_id = 0;
    uint8_t result = 0;
};

struct ControlState {
    static constexpr MsgType kType = MsgType::ControlState;
    lenny_control_state s{};
};

// VIDEO_FRAME is binary, not TLV (protocol.md §6.8).
struct VideoFrameMeta {
    uint32_t frame_seq = 0;
    int64_t pts_us = 0;
    uint8_t orientation = 0;
    uint8_t flags = 0;
};

void encode(TlvWriter& w, const Hello& m);
void encode(TlvWriter& w, const Goodbye& m);
void encode(TlvWriter& w, const Ping& m);
void encode(TlvWriter& w, const Pong& m);
void encode(TlvWriter& w, const PairRequest& m);
void encode(TlvWriter& w, const PairResult& m);
void encode(TlvWriter& w, const Caps& m);
void encode(TlvWriter& w, const CapsSelect& m);
void encode(TlvWriter& w, const StreamStart& m);
void encode(TlvWriter& w, const StreamStatus& m);
void encode(TlvWriter& w, const VideoConfig& m);
void encode(TlvWriter& w, const Control& m);
void encode(TlvWriter& w, const ControlAck& m);
void encode(TlvWriter& w, const ControlState& m);

// False = malformed or missing a required field; the message must be ignored (§6).
bool decode(View v, Hello& m);
bool decode(View v, Goodbye& m);
bool decode(View v, Ping& m);
bool decode(View v, Pong& m);
bool decode(View v, PairRequest& m);
bool decode(View v, PairResult& m);
bool decode(View v, Caps& m);
bool decode(View v, CapsSelect& m);
bool decode(View v, StreamStart& m);
bool decode(View v, StreamStatus& m);
bool decode(View v, VideoConfig& m);
bool decode(View v, Control& m);
bool decode(View v, ControlAck& m);
bool decode(View v, ControlState& m);

void encode_video_meta(uint8_t out[kVideoFrameMetaSize], const VideoFrameMeta& m);
bool decode_video_meta(View payload, VideoFrameMeta& m, View& data);

// Full message (header + TLV payload) for any TLV message type.
template <class M>
Bytes to_message(const M& m, uint8_t minor = kVersionMinor) {
    Bytes out(kHeaderSize);
    TlvWriter w(out);
    encode(w, m);
    Header h;
    h.ver_minor = minor;
    h.type = static_cast<uint16_t>(M::kType);
    h.length = static_cast<uint32_t>(out.size() - kHeaderSize);
    put_header(out.data(), h);
    return out;
}

}  // namespace lenny::wire
