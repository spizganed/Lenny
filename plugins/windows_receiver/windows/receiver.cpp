#include "receiver.h"

#include <windows.h>

#include <objbase.h>

#include <random>
#include <string>

#include "h264_decoder.h"

namespace lenny_win {
namespace {

constexpr size_t kMaxQueuedFrames = 6;  // ~200 ms at 30 fps; beyond that we're behind, so skip to the next keyframe
constexpr int kPreviewW = 960, kPreviewH = 540;  // fixed 16:9 preview canvas; frames are letterboxed into it

std::string computer_name() {
    wchar_t w[256];
    DWORD n = 256;
    if (!GetComputerNameExW(ComputerNamePhysicalDnsHostname, w, &n)) return "Windows PC";
    char out[512];
    int len = WideCharToMultiByte(CP_UTF8, 0, w, int(n), out, sizeof out, nullptr, nullptr);
    return len > 0 ? std::string(out, size_t(len)) : "Windows PC";
}

}  // namespace

Receiver::Receiver(flutter::TextureRegistrar* textures) : textures_(textures) {}

Receiver::~Receiver() = default;

bool Receiver::Start(uint16_t port) {
    texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [this](size_t w, size_t h) { return CopyPixels(w, h); }));
    texture_id_ = textures_->RegisterTexture(texture_.get());

    const std::string name = computer_name();
    lenny_receiver_config cfg{};
    // ponytail: new receiver id per start. Phones don't remember receivers yet; persist it once they do (QR/M5).
    std::random_device rd;
    for (auto& b : cfg.identity.device_id) b = static_cast<uint8_t>(rd());
    cfg.identity.device_name = name.c_str();
    cfg.identity.platform = LENNY_PLATFORM_WINDOWS;
    cfg.port = port;
    cfg.preferred = {LENNY_CODEC_H264, {1920, 1080, 30, 1}, 8000, 0, 0};

    lenny_receiver_callbacks cb{};
    cb.user = this;
    cb.on_video_config = [](void* u, const uint8_t* d, size_t n) {
        Item it;
        it.config = true;
        it.data.assign(d, d + n);
        static_cast<Receiver*>(u)->Push(std::move(it));
    };
    cb.on_video_frame = [](void* u, const lenny_video_frame* f) {
        Item it;
        it.keyframe = f->flags & LENNY_FRAME_KEYFRAME;
        it.orientation = f->orientation;
        it.pts_us = f->pts_us;
        it.local_pts_us = f->local_pts_us;
        it.data.assign(f->data, f->data + f->size);
        static_cast<Receiver*>(u)->Push(std::move(it));
    };
    cb.on_stream_start = [](void* u, const lenny_stream_settings*) {
        auto* self = static_cast<Receiver*>(u);
        {
            std::lock_guard lock(self->queue_mu_);
            self->queue_.clear();
            self->waiting_for_key_ = true;
        }
        std::lock_guard lock(self->geo_mu_);
        self->display_latency_ms_ = -1;
    };
    session_ = lenny_receiver_create(&cfg, &cb);
    decoder_thread_ = std::thread([this] { DecodeLoop(); });
    return session_ && lenny_receiver_start(session_) == LENNY_OK;
}

void Receiver::Push(Item item) {
    {
        std::lock_guard lock(queue_mu_);
        if (!item.config && queue_.size() >= kMaxQueuedFrames) {
            queue_.clear();  // decoder can't keep up: drop the backlog, resume at the next keyframe
            waiting_for_key_ = true;
            lenny_control key{0, LENNY_CTL_KEYFRAME_REQUEST, 0, 0, 0};
            lenny_receiver_send_control(session_, &key);
        }
        queue_.push_back(std::move(item));
    }
    queue_cv_.notify_one();
}

void Receiver::DecodeLoop() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    {
        H264Decoder decoder;
        const bool decoder_ok = decoder.Init();
        std::vector<uint8_t> config, access_unit, rgba;
        for (;;) {
            Item it;
            {
                std::unique_lock lock(queue_mu_);
                queue_cv_.wait(lock, [&] { return stop_ || !queue_.empty(); });
                if (stop_) break;
                it = std::move(queue_.front());
                queue_.pop_front();
                if (!it.config && !it.keyframe && waiting_for_key_) continue;
                if (it.keyframe) waiting_for_key_ = false;
            }
            if (it.config) {
                config = std::move(it.data);
                continue;
            }
            if (!decoder_ok) continue;  // ponytail: no MF decoder (Windows N). Surface this in the UI in M6.
            // SPS/PPS go in front of every keyframe so the decoder can (re)start from any keyframe.
            const uint8_t* data = it.data.data();
            size_t size = it.data.size();
            if (it.keyframe && !config.empty()) {
                access_unit.assign(config.begin(), config.end());
                access_unit.insert(access_unit.end(), it.data.begin(), it.data.end());
                data = access_unit.data();
                size = access_unit.size();
            }
            const bool ok = decoder.Decode(data, size, it.pts_us, [&](const Nv12View& frame) {
                rgba.resize(size_t(kPreviewW) * kPreviewH * 4);
                nv12_to_rgba(frame, it.orientation, rgba.data(), kPreviewW, kPreviewH);
                {
                    std::lock_guard lock(pixels_mu_);
                    pixels_.swap(rgba);
                    pixel_buffer_.width = kPreviewW;
                    pixel_buffer_.height = kPreviewH;
                }
                textures_->MarkTextureFrameAvailable(texture_id_);
                std::lock_guard lock(geo_mu_);
                frame_w_ = frame.width;
                frame_h_ = frame.height;
                frame_rot_ = it.orientation;
                if (it.local_pts_us) {
                    // Excludes the last hop (Flutter compositing + monitor scan-out, ~1-2 frames).
                    const double ms = double(lenny_now_us() - it.local_pts_us) / 1000.0;
                    display_latency_ms_ = display_latency_ms_ < 0 ? ms : display_latency_ms_ * 0.9 + ms * 0.1;
                }
            });
            if (!ok) {  // corrupt data or decoder fault: start clean from the next keyframe
                decoder.Reset();
                {
                    std::lock_guard lock(queue_mu_);
                    waiting_for_key_ = true;
                }
                lenny_control key{0, LENNY_CTL_KEYFRAME_REQUEST, 0, 0, 0};
                lenny_receiver_send_control(session_, &key);
            }
        }
    }
    CoUninitialize();
}

bool Receiver::FocusAt(double x, double y) {
    int w, h, rot;
    {
        std::lock_guard lock(geo_mu_);
        w = frame_w_;
        h = frame_h_;
        rot = frame_rot_;
    }
    double u, v;
    if (!session_ || w <= 0 || !canvas_to_upright(x, y, w, h, rot, kPreviewW, kPreviewH, u, v)) return false;
    lenny_control c{0, LENNY_CTL_FOCUS_AT, uint16_t(u * 65535), uint16_t(v * 65535), 0};
    return lenny_receiver_send_control(session_, &c) == LENNY_OK;
}

double Receiver::DisplayLatencyMs() {
    std::lock_guard lock(geo_mu_);
    return display_latency_ms_;
}

const FlutterDesktopPixelBuffer* Receiver::CopyPixels(size_t, size_t) {
    pixels_mu_.lock();  // held while Flutter copies; released in release_callback
    if (pixels_.empty()) {
        pixels_mu_.unlock();
        return nullptr;
    }
    pixel_buffer_.buffer = pixels_.data();
    pixel_buffer_.release_context = this;
    pixel_buffer_.release_callback = [](void* self) { static_cast<Receiver*>(self)->pixels_mu_.unlock(); };
    return &pixel_buffer_;
}

void Receiver::Shutdown() {
    lenny_session_destroy(session_);  // joins the core's thread: no more Push() after this
    session_ = nullptr;
    {
        std::lock_guard lock(queue_mu_);
        stop_ = true;
    }
    queue_cv_.notify_one();
    if (decoder_thread_.joinable()) decoder_thread_.join();
    if (texture_id_ < 0) {
        delete this;
        return;
    }
    // The raster thread may still be reading the texture; free only after Flutter confirms it's gone.
    textures_->UnregisterTexture(texture_id_, [this] { delete this; });
}

}  // namespace lenny_win
