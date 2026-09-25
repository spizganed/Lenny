// H.264 (Annex-B) -> NV12 with the Media Foundation H.264 decoder MFT. Call everything from one thread.
#pragma once

#include <mftransform.h>
#include <wrl/client.h>

#include <cstdint>
#include <functional>

#include "nv12.h"

namespace lenny_win {

class H264Decoder {
public:
    using FrameFn = std::function<void(const Nv12View&)>;

    ~H264Decoder();
    // False if MF or the decoder isn't available (e.g. Windows N without the Media Feature Pack).
    bool Init();
    // Feeds one access unit and delivers any decoded frames. False = decoder error; call Reset() and wait for a
    // keyframe.
    bool Decode(const uint8_t* data, size_t size, int64_t pts_us, const FrameFn& on_frame);
    void Reset();

private:
    bool SetOutputNv12();
    bool Drain(const FrameFn& on_frame);

    Microsoft::WRL::ComPtr<IMFTransform> mft_;
    bool mf_started_ = false;
    int width_ = 0, height_ = 0, alloc_height_ = 0, stride_ = 0;
};

}  // namespace lenny_win
