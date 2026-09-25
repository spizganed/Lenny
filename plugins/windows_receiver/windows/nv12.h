// NV12 -> RGBA for the preview texture: rotate to upright and fit (letterboxed, nearest neighbour) into a fixed
// canvas, so the texture size never changes and portrait phones aren't stretched. CPU only.
// ponytail: CPU conversion of the preview (~1-2 ms/frame at 960x540 in release). Move to a D3D11 GPU surface texture
// when the vcam path puts frames on the GPU anyway.
#pragma once

#include <algorithm>
#include <cstdint>
#include <vector>

namespace lenny_win {

struct Nv12View {
    const uint8_t* y;   // luma plane
    const uint8_t* uv;  // interleaved UV plane, half height
    int stride;         // bytes per row, both planes
    int width, height;  // visible size
};

inline uint8_t clamp8(int v) { return static_cast<uint8_t>(std::clamp(v, 0, 255)); }

// Where an upright rw x rh picture lands inside an out_w x out_h canvas (centred, aspect kept).
struct Fit {
    int x0, y0, dw, dh;
};
inline Fit fit(int rw, int rh, int out_w, int out_h) {
    int dw = out_w, dh = int(int64_t(rh) * out_w / rw);
    if (dh > out_h) {
        dh = out_h;
        dw = int(int64_t(rw) * out_h / rh);
    }
    return {(out_w - dw) / 2, (out_h - dh) / 2, dw, dh};
}

// Canvas point (normalised 0..1) -> upright picture point (0..1). False if it's on a letterbox bar.
inline bool canvas_to_upright(double cx, double cy, int width, int height, int rotation, int out_w, int out_h,
                              double& u, double& v) {
    const bool swap = rotation & 1;
    const Fit f = fit(swap ? height : width, swap ? width : height, out_w, out_h);
    u = (cx * out_w - f.x0) / f.dw;
    v = (cy * out_h - f.y0) / f.dh;
    return u >= 0 && u <= 1 && v >= 0 && v <= 1;
}

// rotation = quarter turns clockwise to upright (protocol.md §6.8). `out` must be out_w * out_h * 4 bytes.
inline void nv12_to_rgba(const Nv12View& src, int rotation, uint8_t* out, int out_w, int out_h) {
    const int W = src.width, H = src.height;
    const bool swap = rotation & 1;
    const int rw = swap ? H : W, rh = swap ? W : H;  // upright size
    const auto [x0, y0, dw, dh] = fit(rw, rh, out_w, out_h);
    uint8_t* d = out;
    for (int oy = 0; oy < out_h; ++oy) {
        for (int ox = 0; ox < out_w; ++ox, d += 4) {
            if (ox < x0 || ox >= x0 + dw || oy < y0 || oy >= y0 + dh) {
                d[0] = d[1] = d[2] = 0;
                d[3] = 255;
                continue;
            }
            const int rx = int(int64_t(ox - x0) * rw / dw), ry = int(int64_t(oy - y0) * rh / dh);
            int x, y;  // source pixel for upright pixel (rx, ry)
            switch (rotation & 3) {
                case 0: x = rx; y = ry; break;
                case 1: x = ry; y = H - 1 - rx; break;
                case 2: x = W - 1 - rx; y = H - 1 - ry; break;
                default: x = W - 1 - ry; y = rx; break;
            }
            // BT.709 limited range (HD video; Android encoders default to it at >= 720p).
            const int c = 298 * (src.y[y * src.stride + x] - 16);
            const uint8_t* uv = src.uv + (y / 2) * src.stride + (x & ~1);
            const int u = uv[0] - 128, v = uv[1] - 128;
            d[0] = clamp8((c + 459 * v + 128) >> 8);
            d[1] = clamp8((c - 55 * u - 136 * v + 128) >> 8);
            d[2] = clamp8((c + 541 * u + 128) >> 8);
            d[3] = 255;
        }
    }
}

}  // namespace lenny_win
