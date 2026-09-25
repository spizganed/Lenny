// Desktop receiver pipeline: core session -> decode thread -> preview texture.
#pragma once

#include <flutter/texture_registrar.h>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include "lenny/lenny.h"

namespace lenny_win {

class Receiver {
public:
    explicit Receiver(flutter::TextureRegistrar* textures);
    Receiver(const Receiver&) = delete;
    Receiver& operator=(const Receiver&) = delete;

    bool Start(uint16_t port);
    lenny_session* session() const { return session_; }
    uint16_t port() const { return session_ ? lenny_receiver_port(session_) : 0; }
    int64_t texture_id() const { return texture_id_; }

    // Stops everything and deletes `this` once Flutter has let go of the texture.
    void Shutdown();

private:
    ~Receiver();
    struct Item {
        bool config = false;
        bool keyframe = false;
        uint8_t orientation = 0;
        int64_t pts_us = 0;
        std::vector<uint8_t> data;
    };

    void Push(Item item);
    void DecodeLoop();
    const FlutterDesktopPixelBuffer* CopyPixels(size_t width, size_t height);

    flutter::TextureRegistrar* textures_;
    lenny_session* session_ = nullptr;

    std::mutex queue_mu_;
    std::condition_variable queue_cv_;
    std::deque<Item> queue_;
    bool stop_ = false;
    bool waiting_for_key_ = true;
    std::thread decoder_thread_;

    std::unique_ptr<flutter::TextureVariant> texture_;
    int64_t texture_id_ = -1;
    std::mutex pixels_mu_;
    std::vector<uint8_t> pixels_;  // RGBA, what the texture shows
    FlutterDesktopPixelBuffer pixel_buffer_{};
};

}  // namespace lenny_win
