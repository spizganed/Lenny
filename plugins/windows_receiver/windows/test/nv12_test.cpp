// Build + run: cl /std:c++20 /EHsc /I.. nv12_test.cpp && nv12_test.exe
#include <cassert>
#include <cstdio>
#include <vector>

#include "nv12.h"

using namespace lenny_win;

// 4x2 source: left half white (Y=235), right half black (Y=16), neutral chroma.
int main() {
    const int W = 4, H = 2;
    std::vector<uint8_t> y = {235, 235, 16, 16, 235, 235, 16, 16};
    std::vector<uint8_t> uv = {128, 128, 128, 128};
    Nv12View v{y.data(), uv.data(), W, W, H};
    std::vector<uint8_t> out(4 * 2 * 4);

    nv12_to_rgba(v, 0, out.data(), 4, 2);  // same aspect: 1:1 copy
    assert(out[0] == 255 && out[1] == 255 && out[2] == 255);  // top-left white
    assert(out[3 * 4] == 0);                                  // top-right black

    // Rotated 90 cw -> upright is 2 wide x 4 tall; in a 4x2 canvas it's letterboxed to 1x2 in the middle columns.
    nv12_to_rgba(v, 1, out.data(), 4, 2);
    assert(out[0] == 0 && out[3 * 4] == 0);  // bars
    // Upright top row came from the source's left column (white) after a clockwise turn.
    assert(out[(0 * 4 + 1) * 4] == 255 || out[(0 * 4 + 2) * 4] == 255);
    // Upright bottom row came from the source's right column (black).
    assert(out[(1 * 4 + 1) * 4] == 0 && out[(1 * 4 + 2) * 4] == 0);

    nv12_to_rgba(v, 2, out.data(), 4, 2);  // 180: left/right swapped
    assert(out[0] == 0 && out[3 * 4] == 255);
    // Tap mapping: 1920x1080 portrait phone (rotation 1) in a 960x540 canvas -> picture is 304 px wide, centred.
    double tu = 0, tv = 0;
    assert(canvas_to_upright(0.5, 0.5, 1920, 1080, 1, 960, 540, tu, tv) && tu > 0.49 && tu < 0.51 && tv > 0.49 && tv < 0.51);
    assert(!canvas_to_upright(0.05, 0.5, 1920, 1080, 1, 960, 540, tu, tv));  // left letterbox bar
    assert(canvas_to_upright(0.25, 0.75, 1920, 1080, 0, 960, 540, tu, tv) && tu > 0.24 && tu < 0.26 && tv > 0.74 && tv < 0.76);
    std::puts("nv12_test ok");
    return 0;
}
