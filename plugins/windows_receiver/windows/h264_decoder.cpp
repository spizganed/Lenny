#include "h264_decoder.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <wmcodecdsp.h>

using Microsoft::WRL::ComPtr;

namespace lenny_win {

H264Decoder::~H264Decoder() {
    mft_.Reset();
    if (mf_started_) MFShutdown();
}

bool H264Decoder::Init() {
    if (!mf_started_) {
        if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET))) return false;
        mf_started_ = true;
    }
    mft_.Reset();
    // ponytail: software MFT without a D3D device manager. Hardware decode (DXVA via MF_SA_D3D11_AWARE) comes with
    // the GPU texture path in M3.
    if (FAILED(CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&mft_))))
        return false;

    ComPtr<ICodecAPI> codec;
    if (SUCCEEDED(mft_.As(&codec))) {
        VARIANT v{};
        v.vt = VT_UI4;
        v.ulVal = TRUE;
        codec->SetValue(&CODECAPI_AVLowLatencyMode, &v);  // output each frame immediately, no reorder delay
    }

    ComPtr<IMFMediaType> in;
    MFCreateMediaType(&in);
    in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (FAILED(mft_->SetInputType(0, in.Get(), 0))) return false;
    SetOutputNv12();  // may fail until the first SPS is seen; STREAM_CHANGE sets it then
    width_ = height_ = 0;
    mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    mft_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    return true;
}

void H264Decoder::Reset() { Init(); }

bool H264Decoder::SetOutputNv12() {
    ComPtr<IMFMediaType> t;
    for (DWORD i = 0; SUCCEEDED(mft_->GetOutputAvailableType(0, i, &t)); ++i) {
        GUID sub{};
        t->GetGUID(MF_MT_SUBTYPE, &sub);
        if (sub != MFVideoFormat_NV12) continue;
        if (FAILED(mft_->SetOutputType(0, t.Get(), 0))) return false;
        UINT32 w = 0, h = 0;
        MFGetAttributeSize(t.Get(), MF_MT_FRAME_SIZE, &w, &h);
        // The decoder's buffers are padded to 16 rows (1080 -> 1088); the visible area is the display aperture.
        MFVideoArea area{};
        if (SUCCEEDED(t->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof area, nullptr))) {
            width_ = area.Area.cx;
            height_ = area.Area.cy;
        } else {
            width_ = int(w);
            height_ = int(h);
        }
        alloc_height_ = int(h);
        stride_ = int(MFGetAttributeUINT32(t.Get(), MF_MT_DEFAULT_STRIDE, w));
        return true;
    }
    return false;
}

bool H264Decoder::Decode(const uint8_t* data, size_t size, int64_t pts_us, const FrameFn& on_frame) {
    if (!mft_ || !data || size == 0) return false;
    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(MFCreateMemoryBuffer(DWORD(size), &buf))) return false;
    BYTE* p = nullptr;
    buf->Lock(&p, nullptr, nullptr);
    memcpy(p, data, size);
    buf->Unlock();
    buf->SetCurrentLength(DWORD(size));
    ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buf.Get());
    sample->SetSampleTime(pts_us * 10);  // 100 ns units

    HRESULT hr = mft_->ProcessInput(0, sample.Get(), 0);
    if (hr == MF_E_NOTACCEPTING) {  // output pending: drain, then retry once
        if (!Drain(on_frame)) return false;
        hr = mft_->ProcessInput(0, sample.Get(), 0);
    }
    if (FAILED(hr)) return false;
    return Drain(on_frame);
}

bool H264Decoder::Drain(const FrameFn& on_frame) {
    for (;;) {
        MFT_OUTPUT_STREAM_INFO info{};
        if (FAILED(mft_->GetOutputStreamInfo(0, &info))) return false;
        ComPtr<IMFSample> out_sample;
        if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
            ComPtr<IMFMediaBuffer> out_buf;
            if (FAILED(MFCreateMemoryBuffer(info.cbSize, &out_buf))) return false;
            MFCreateSample(&out_sample);
            out_sample->AddBuffer(out_buf.Get());
        }
        MFT_OUTPUT_DATA_BUFFER out{0, out_sample.Get(), 0, nullptr};
        DWORD status = 0;
        const HRESULT hr = mft_->ProcessOutput(0, 1, &out, &status);
        if (out.pEvents) out.pEvents->Release();
        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {  // first SPS or resolution change
            if (!SetOutputNv12()) return false;
            continue;
        }
        if (FAILED(hr)) return false;

        IMFSample* s = out.pSample;
        ComPtr<IMFMediaBuffer> contiguous;
        if (!s || FAILED(s->ConvertToContiguousBuffer(&contiguous)) || width_ <= 0) continue;
        BYTE* p = nullptr;
        DWORD len = 0;
        if (FAILED(contiguous->Lock(&p, nullptr, &len))) continue;
        // Bounds check before touching the planes: a short buffer must never become an out-of-bounds read.
        const size_t need = size_t(stride_) * alloc_height_ * 3 / 2;
        if (stride_ >= width_ && len >= need)
            on_frame({p, p + size_t(stride_) * alloc_height_, stride_, width_, height_});
        contiguous->Unlock();
    }
}

}  // namespace lenny_win
