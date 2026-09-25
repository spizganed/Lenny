#include <cctype>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#include "check.hpp"
#include "pairing.hpp"
#include "timing.hpp"
#include "wire.hpp"

using namespace lenny;
using namespace lenny::wire;

namespace {

Bytes load_vector(const char* name) {
    std::ifstream f(std::string(LENNY_VECTORS_DIR) + "/" + name);
    Bytes out;
    std::string line;
    while (std::getline(f, line)) {
        line = line.substr(0, line.find('#'));
        std::istringstream in(line);
        std::string byte;
        while (in >> byte) out.push_back(static_cast<uint8_t>(std::stoul(byte, nullptr, 16)));
    }
    return out;
}

// Feeds `msg` through a reader and returns the single payload inside.
bool read_one(const Bytes& msg, Header& h, Bytes& payload) {
    MessageReader r;
    r.feed(msg.data(), msg.size());
    View p;
    if (r.next(h, p) != MessageReader::Status::Message) return false;
    payload.assign(p.begin(), p.end());
    return r.next(h, p) == MessageReader::Status::NeedMore;
}

template <class M>
M roundtrip(const M& in) {
    Header h;
    Bytes payload;
    M out;
    const bool ok = read_one(to_message(in), h, payload) && h.type == uint16_t(M::kType) && decode(payload, out);
    CHECK(ok);
    return out;
}

}  // namespace

TEST(vector_hello_decodes_and_reencodes) {
    Bytes v = load_vector("hello_sender_min.hex");
    CHECK(v.size() == 54);
    Header h;
    Bytes p;
    Hello m;
    CHECK(read_one(v, h, p));
    CHECK(h.type == uint16_t(MsgType::Hello) && h.length == 42);
    CHECK(decode(p, m));
    CHECK(m.role == 1 && m.proto_major == 1 && m.proto_minor == 0 && m.device_name == "Pix");
    CHECK(m.device_id[0] == 0x00 && m.device_id[15] == 0x0F);
    CHECK(to_message(m) == v);
}

TEST(vector_control_focus_at) {
    Bytes v = load_vector("control_focus_at.hex");
    Header h;
    Bytes p;
    Control c;
    CHECK(read_one(v, h, p) && decode(p, c));
    CHECK(c.c.req_id == 7 && c.c.cmd == LENNY_CTL_FOCUS_AT && c.c.x == 0x8000 && c.c.y == 0x4000);
    CHECK(to_message(c) == v);
}

TEST(vector_video_frame) {
    Bytes v = load_vector("video_frame_key.hex");
    Header h;
    Bytes p;
    CHECK(read_one(v, h, p) && h.type == uint16_t(MsgType::VideoFrame));
    VideoFrameMeta m;
    View data;
    CHECK(decode_video_meta(p, m, data));
    CHECK(m.frame_seq == 1 && m.pts_us == 1000000 && m.orientation == 1 && m.flags == LENNY_FRAME_KEYFRAME);
    CHECK(data.size() == 6 && data[4] == 0x65);
    uint8_t meta[kVideoFrameMetaSize];
    encode_video_meta(meta, m);
    CHECK(std::memcmp(meta, v.data() + kHeaderSize, sizeof meta) == 0);
}

TEST(reader_handles_byte_by_byte_and_back_to_back) {
    Bytes stream = to_message(Ping{1, 10});
    Bytes second = to_message(Ping{2, 20});
    stream.insert(stream.end(), second.begin(), second.end());
    MessageReader r;
    int got = 0;
    for (uint8_t b : stream) {
        r.feed(&b, 1);
        Header h;
        View p;
        while (r.next(h, p) == MessageReader::Status::Message) {
            Ping ping;
            CHECK(decode(p, ping) && ping.seq == uint32_t(got + 1));
            ++got;
        }
    }
    CHECK(got == 2);
}

TEST(reader_rejects_bad_magic_and_oversize) {
    MessageReader r;
    Bytes bad = to_message(Ping{1, 1});
    bad[0] = 'X';
    r.feed(bad.data(), bad.size());
    Header h;
    View p;
    CHECK(r.next(h, p) == MessageReader::Status::BadMagic);

    uint8_t big[kHeaderSize];
    put_header(big, {1, 0, uint16_t(MsgType::Hello), 0, kMaxControlPayload + 1});
    MessageReader r2;
    r2.feed(big, sizeof big);
    CHECK(r2.next(h, p) == MessageReader::Status::TooLarge);

    // Video frames get the bigger limit.
    put_header(big, {1, 0, uint16_t(MsgType::VideoFrame), 0, kMaxControlPayload + 1});
    MessageReader r3;
    r3.feed(big, sizeof big);
    CHECK(r3.next(h, p) == MessageReader::Status::NeedMore);
}

TEST(unknown_type_passes_through_reader) {
    Bytes msg(kHeaderSize + 3, 0xAB);
    put_header(msg.data(), {1, 0, 0x7777, 0, 3});
    Bytes after = to_message(Ping{9, 9});
    msg.insert(msg.end(), after.begin(), after.end());
    MessageReader r;
    r.feed(msg.data(), msg.size());
    Header h;
    View p;
    CHECK(r.next(h, p) == MessageReader::Status::Message && h.type == 0x7777 && p.size() == 3);
    CHECK(r.next(h, p) == MessageReader::Status::Message && h.type == uint16_t(MsgType::Ping));
}

TEST(unknown_tlv_tags_are_skipped) {
    Bytes payload;
    TlvWriter w(payload);
    w.u32(1, 5);
    w.str(999, "from the future");  // unknown tag
    w.i64(2, 77);
    Ping p;
    CHECK(decode(payload, p) && p.seq == 5 && p.t1 == 77);
}

TEST(truncated_or_missing_fields_rejected) {
    Bytes payload;
    TlvWriter w(payload);
    w.u32(1, 5);
    Ping p;
    CHECK(!decode(payload, p));  // t1 missing
    w.i64(2, 7);
    payload.pop_back();  // truncated field
    CHECK(!decode(payload, p));
    Bytes wrong_size;
    TlvWriter w2(wrong_size);
    w2.u16(1, 5);  // seq must be u32
    w2.i64(2, 7);
    CHECK(!decode(wrong_size, p));
}

TEST(roundtrip_all_messages) {
    Hello hello;
    hello.role = 2;
    hello.device_id[3] = 9;
    hello.device_name = "Desk";
    hello.app_version = "0.1";
    hello.platform = LENNY_PLATFORM_WINDOWS;
    hello.pairing_required = true;
    hello.features = 1;
    auto h2 = roundtrip(hello);
    CHECK(h2.device_name == "Desk" && h2.app_version == "0.1" && h2.platform == 3 && h2.pairing_required &&
          h2.features == 1 && h2.device_id[3] == 9);

    CHECK(roundtrip(Goodbye{LENNY_REASON_BUSY, "busy"}).detail == "busy");
    auto pong = roundtrip(Pong{3, 1, 2, 3});
    CHECK(pong.seq == 3 && pong.t3 == 3);

    PairRequest pr;
    pr.token[15] = 0xEE;
    CHECK(roundtrip(pr).token[15] == 0xEE);
    CHECK(roundtrip(PairResult{LENNY_PAIR_EXPIRED}).result == LENNY_PAIR_EXPIRED);

    Caps caps;
    caps.codecs.push_back({LENNY_CODEC_H264, 66, 31});
    caps.modes.push_back({1280, 720, 30, 1});
    caps.modes.push_back({1920, 1080, 30000, 1001});
    caps.max_bitrate_kbps = 12000;
    caps.controls = LENNY_CAP_FOCUS | LENNY_CAP_TORCH;
    caps.lenses.push_back({0, 0, "Wide"});
    caps.lenses.push_back({1, 1, "Front"});
    caps.has_exposure_range = true;
    caps.exposure_min = -2000;
    caps.exposure_max = 2000;
    caps.exposure_step_milli = 333;
    auto c2 = roundtrip(caps);
    CHECK(c2.codecs.size() == 1 && c2.codecs[0].profile == 66);
    CHECK(c2.modes.size() == 2 && c2.modes[1].fps_num == 30000 && c2.modes[1].fps_den == 1001);
    CHECK(c2.lenses.size() == 2 && c2.lenses[1].label == "Front");
    CHECK(c2.has_exposure_range && c2.exposure_min == -2000 && c2.exposure_step_milli == 333);

    lenny_stream_settings s{LENNY_CODEC_H264, {1920, 1080, 30, 1}, 8000, 1, 2};
    auto sel = roundtrip(CapsSelect{s});
    CHECK(sel.s.mode.width == 1920 && sel.s.bitrate_kbps == 8000 && sel.s.has_lens && sel.s.lens_id == 2);
    s.has_lens = 0;
    CHECK(!roundtrip(StreamStart{s}).s.has_lens);

    CHECK(roundtrip(StreamStatus{LENNY_STREAM_CAMERA_LOST, "call"}).reason == "call");
    VideoConfig vc;
    vc.config = {0, 0, 0, 1, 0x67};
    CHECK(roundtrip(vc).config == vc.config);

    for (uint16_t cmd = LENNY_CTL_KEYFRAME_REQUEST; cmd <= LENNY_CTL_RESET_AUTO; ++cmd) {
        lenny_control c{42, cmd, 0, 0, 0};
        if (cmd == LENNY_CTL_EXPOSURE_COMP) c.value = -1333;
        if (cmd == LENNY_CTL_ZOOM) c.value = 250;
        if (cmd == LENNY_CTL_TORCH || cmd == LENNY_CTL_SELECT_LENS) c.value = 1;
        auto out = roundtrip(Control{c});
        CHECK(out.c.cmd == cmd && out.c.req_id == 42 && out.c.value == c.value);
    }
    CHECK(roundtrip(ControlAck{42, LENNY_ACK_FAILED}).result == LENNY_ACK_FAILED);
    lenny_control_state cs{1, -500, 1, 0, 1, 2, 150};
    auto cs2 = roundtrip(ControlState{cs});
    CHECK(cs2.s.af_mode == 1 && cs2.s.exposure_comp == -500 && cs2.s.torch == 1 && cs2.s.zoom == 150);
}

TEST(clock_sync_prefers_lowest_rtt) {
    ClockSync c;
    CHECK(!c.valid() && c.rtt_us() == -1);
    // Remote clock is +1000 ahead. Symmetric 100 us each way.
    c.add(0, 1100, 1100, 200);
    CHECK(c.rtt_us() == 200 && c.offset_us() == 1000);
    // Slow, asymmetric sample (queued on the way back) must not win.
    c.add(10000, 11100, 11100, 15000);
    CHECK(c.rtt_us() == 200 && c.offset_us() == 1000);
    c.add(5, 5, 4, 0);  // negative rtt: ignored
    CHECK(c.rtt_us() == 200);
}

TEST(pair_tokens_single_use_and_expiry) {
    TokenStore ts;
    auto a = ts.issue(0, 1000);
    auto b = ts.issue(0, 1000);
    CHECK(a != b);
    CHECK(ts.redeem(a, 500) == LENNY_PAIR_OK);
    CHECK(ts.redeem(a, 600) == LENNY_PAIR_ALREADY_USED);
    CHECK(ts.redeem(b, 2000) == LENNY_PAIR_EXPIRED);
    PairToken unknown{};
    CHECK(ts.redeem(unknown, 0) == LENNY_PAIR_UNKNOWN_TOKEN);
}
