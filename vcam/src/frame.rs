//! I420 helpers shared by every backend and the desktop preview: rotate decoded frames upright and letterbox them
//! into the fixed virtual-camera canvas, convert that canvas to RGBA, and draw the "waiting for phone" placeholder.
// ponytail: CPU, nearest neighbour (~2-4 ms per 720p frame in release). Move to the GPU if 1080p60 ever matters.

/// Bytes in a tightly packed I420 frame.
pub fn i420_size(w: usize, h: usize) -> usize {
    w * h + 2 * (w.div_ceil(2) * h.div_ceil(2))
}

/// A decoded I420 picture (planes may have row padding).
pub struct I420<'a> {
    pub y: &'a [u8],
    pub u: &'a [u8],
    pub v: &'a [u8],
    pub y_stride: usize,
    pub uv_stride: usize,
    pub width: usize,
    pub height: usize,
}

/// Where an upright rw x rh picture lands inside an out_w x out_h canvas (centred, aspect kept, never stretched).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fit {
    pub x0: usize,
    pub y0: usize,
    pub w: usize,
    pub h: usize,
}

pub fn fit(rw: usize, rh: usize, out_w: usize, out_h: usize) -> Fit {
    let (mut w, mut h) = (out_w, rh * out_w / rw.max(1));
    if h > out_h {
        h = out_h;
        w = rw * out_h / rh.max(1);
    }
    Fit { x0: (out_w - w) / 2, y0: (out_h - h) / 2, w: w.max(1), h: h.max(1) }
}

/// Upright size of a w x h picture after `rotation` quarter turns.
pub fn upright(w: usize, h: usize, rotation: u8) -> (usize, usize) {
    if rotation & 1 == 1 {
        (h, w)
    } else {
        (w, h)
    }
}

/// Canvas point (0..1) -> upright picture point (0..1); None on a letterbox bar. For tap-to-focus and pan.
pub fn canvas_to_upright(
    cx: f64,
    cy: f64,
    w: usize,
    h: usize,
    rotation: u8,
    out_w: usize,
    out_h: usize,
) -> Option<(f64, f64)> {
    let (rw, rh) = upright(w, h, rotation);
    let f = fit(rw, rh, out_w, out_h);
    let u = (cx * out_w as f64 - f.x0 as f64) / f.w as f64;
    let v = (cy * out_h as f64 - f.y0 as f64) / f.h as f64;
    ((0.0..=1.0).contains(&u) && (0.0..=1.0).contains(&v)).then_some((u, v))
}

const BAR: (u8, u8, u8) = (16, 128, 128); // black, limited range

/// Rotate `src` upright (`rotation` = quarter turns clockwise, protocol.md §6.8) and letterbox it into `dst`, a
/// packed out_w x out_h I420 canvas.
pub fn compose_i420(src: &I420, rotation: u8, dst: &mut [u8], out_w: usize, out_h: usize) {
    let (w, h) = (src.width, src.height);
    let (rw, rh) = upright(w, h, rotation);
    let f = fit(rw, rh, out_w, out_h);
    // Source pixel for canvas pixel (ox, oy) inside the fitted rect, in a plane subsampled by `sub`.
    let map = |ox: usize, oy: usize, sub: usize| -> (usize, usize) {
        let rx = (ox - f.x0 / sub) * rw / (f.w / sub).max(1);
        let ry = (oy - f.y0 / sub) * rh / (f.h / sub).max(1);
        let (rx, ry) = (rx.min(rw - 1), ry.min(rh - 1));
        let (x, y) = match rotation & 3 {
            0 => (rx, ry),
            1 => (ry, h - 1 - rx),
            2 => (w - 1 - rx, h - 1 - ry),
            _ => (w - 1 - ry, rx),
        };
        (x / sub, y / sub)
    };
    let (yp, uvp) = dst.split_at_mut(out_w * out_h);
    let (cw, ch) = (out_w.div_ceil(2), out_h.div_ceil(2));
    let (up, vp) = uvp.split_at_mut(cw * ch);
    for oy in 0..out_h {
        let row = &mut yp[oy * out_w..(oy + 1) * out_w];
        let inside_y = oy >= f.y0 && oy < f.y0 + f.h;
        for (ox, d) in row.iter_mut().enumerate() {
            *d = if inside_y && ox >= f.x0 && ox < f.x0 + f.w {
                let (x, y) = map(ox, oy, 1);
                src.y[y * src.y_stride + x]
            } else {
                BAR.0
            };
        }
    }
    for oy in 0..ch {
        let inside_y = oy >= f.y0 / 2 && oy < (f.y0 + f.h) / 2;
        for ox in 0..cw {
            let i = oy * cw + ox;
            if inside_y && ox >= f.x0 / 2 && ox < (f.x0 + f.w) / 2 {
                let (x, y) = map(ox, oy, 2);
                up[i] = src.u[y * src.uv_stride + x];
                vp[i] = src.v[y * src.uv_stride + x];
            } else {
                up[i] = BAR.1;
                vp[i] = BAR.2;
            }
        }
    }
}

/// Packed I420 canvas -> RGBA (BT.709 limited range, what phone encoders use at HD sizes).
pub fn i420_to_rgba(src: &[u8], w: usize, h: usize, out: &mut [u8]) {
    let cw = w.div_ceil(2);
    let (yp, uvp) = src.split_at(w * h);
    let (up, vp) = uvp.split_at(cw * h.div_ceil(2));
    for y in 0..h {
        for x in 0..w {
            let c = 298 * (yp[y * w + x] as i32 - 16);
            let i = (y / 2) * cw + x / 2;
            let (u, v) = (up[i] as i32 - 128, vp[i] as i32 - 128);
            let d = &mut out[(y * w + x) * 4..][..4];
            d[0] = ((c + 459 * v + 128) >> 8).clamp(0, 255) as u8;
            d[1] = ((c - 55 * u - 136 * v + 128) >> 8).clamp(0, 255) as u8;
            d[2] = ((c + 541 * u + 128) >> 8).clamp(0, 255) as u8;
            d[3] = 255;
        }
    }
}

/// sRGB -> BT.709 limited-range YUV.
pub fn rgb_to_yuv(r: u8, g: u8, b: u8) -> (u8, u8, u8) {
    let (r, g, b) = (r as f64, g as f64, b as f64);
    let y = 16.0 + (0.2126 * r + 0.7152 * g + 0.0722 * b) * 219.0 / 255.0;
    let u = 128.0 + (-0.1146 * r - 0.3854 * g + 0.5 * b) * 224.0 / 255.0;
    let v = 128.0 + (0.5 * r - 0.4542 * g - 0.0458 * b) * 224.0 / 255.0;
    (y.round() as u8, u.round() as u8, v.round() as u8)
}

// 5x7 bitmap font, one byte per row (bit 4 = leftmost column). Enough for status lines.
const GLYPHS: &[(char, [u8; 7])] = &[
    ('A', [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]),
    ('B', [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E]),
    ('C', [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E]),
    ('D', [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E]),
    ('E', [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F]),
    ('F', [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10]),
    ('G', [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F]),
    ('H', [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11]),
    ('I', [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E]),
    ('J', [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C]),
    ('K', [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11]),
    ('L', [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F]),
    ('M', [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11]),
    ('N', [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11]),
    ('O', [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]),
    ('P', [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10]),
    ('Q', [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D]),
    ('R', [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11]),
    ('S', [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E]),
    ('T', [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04]),
    ('U', [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E]),
    ('V', [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04]),
    ('W', [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A]),
    ('X', [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11]),
    ('Y', [0x11, 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04]),
    ('Z', [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F]),
    ('.', [0, 0, 0, 0, 0, 0x0C, 0x0C]),
    ('-', [0, 0, 0, 0x1F, 0, 0, 0]),
];

/// The frame the camera shows when there's no live video: the dotted page from docs/design.md plus a status line
/// (e.g. "WAITING FOR PHONE"), so a consumer never sees a black or frozen picture without an explanation.
pub fn placeholder_i420(w: usize, h: usize, text: &str) -> Vec<u8> {
    let page = rgb_to_yuv(0x1A, 0x1D, 0x38);
    let dot = rgb_to_yuv(0x2C, 0x30, 0x60);
    let ink = rgb_to_yuv(0xF4, 0xF1, 0xE8);
    let mut f = vec![0u8; i420_size(w, h)];
    let (yp, uvp) = f.split_at_mut(w * h);
    let cw = w.div_ceil(2);
    let (up, vp) = uvp.split_at_mut(cw * h.div_ceil(2));
    yp.fill(page.0);
    up.fill(page.1);
    vp.fill(page.2);
    let mut put = |x: usize, y: usize, c: (u8, u8, u8)| {
        if x < w && y < h {
            yp[y * w + x] = c.0;
            up[(y / 2) * cw + x / 2] = c.1;
            vp[(y / 2) * cw + x / 2] = c.2;
        }
    };
    let grid = (h / 30).max(8);
    for gy in (grid / 2..h).step_by(grid) {
        for gx in (grid / 2..w).step_by(grid) {
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                put(gx + dx, gy + dy, dot);
            }
        }
    }
    let px = (h / 90).max(1); // font pixel size
    let text: Vec<char> = text.to_uppercase().chars().collect();
    let tw = text.len() * 6 * px;
    let (x0, y0) = (w.saturating_sub(tw) / 2, h.saturating_sub(7 * px) / 2);
    for (i, ch) in text.iter().enumerate() {
        let Some((_, rows)) = GLYPHS.iter().find(|(c, _)| c == ch) else { continue };
        for (ry, bits) in rows.iter().enumerate() {
            for rx in 0..5 {
                if bits & (0x10 >> rx) != 0 {
                    for sy in 0..px {
                        for sx in 0..px {
                            put(x0 + (i * 6 + rx) * px + sx, y0 + ry * px + sy, ink);
                        }
                    }
                }
            }
        }
    }
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 4x2 picture with distinct luma per pixel, chroma per 2x2 block.
    fn pic() -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        ((0..8).map(|i| 100 + i as u8).collect(), vec![1, 2], vec![3, 4])
    }

    #[test]
    fn fit_letterboxes_without_stretching() {
        assert_eq!(fit(1920, 1080, 1280, 720), Fit { x0: 0, y0: 0, w: 1280, h: 720 });
        assert_eq!(fit(1080, 1920, 1280, 720), Fit { x0: 437, y0: 0, w: 405, h: 720 }); // portrait: pillarbox
        assert_eq!(fit(1440, 1080, 1280, 720), Fit { x0: 160, y0: 0, w: 960, h: 720 });
        // 4:3
    }

    #[test]
    fn compose_rotates_upright() {
        let (y, u, v) = pic();
        let src = I420 { y: &y, u: &u, v: &v, y_stride: 4, uv_stride: 2, width: 4, height: 2 };
        // No rotation, same size: identity.
        let mut out = vec![0; i420_size(4, 2)];
        compose_i420(&src, 0, &mut out, 4, 2);
        assert_eq!(&out[..8], &y[..]);
        assert_eq!(&out[8..], &[1, 2, 3, 4]);
        // 90 deg clockwise into a 2x4 canvas: upright row 0 = source column 0 read bottom-up.
        let mut out = vec![0; i420_size(2, 4)];
        compose_i420(&src, 1, &mut out, 2, 4);
        assert_eq!(&out[..8], &[104, 100, 105, 101, 106, 102, 107, 103]);
        // 180: reversed.
        let mut out = vec![0; i420_size(4, 2)];
        compose_i420(&src, 2, &mut out, 4, 2);
        assert_eq!(&out[..8], &[107, 106, 105, 104, 103, 102, 101, 100]);
    }

    #[test]
    fn compose_fills_bars() {
        let (y, u, v) = pic();
        let src = I420 { y: &y, u: &u, v: &v, y_stride: 4, uv_stride: 2, width: 4, height: 2 };
        let mut out = vec![0; i420_size(8, 2)]; // 4:1 canvas, 2:1 picture -> bars left and right
        compose_i420(&src, 0, &mut out, 8, 2);
        assert_eq!(&out[..2], &[16, 16]);
        assert_eq!(&out[2..6], &[100, 101, 102, 103]);
        assert_eq!(&out[6..8], &[16, 16]);
    }

    #[test]
    fn canvas_to_upright_skips_bars() {
        let (u, v) = canvas_to_upright(0.5, 0.5, 1080, 1920, 0, 1280, 720).unwrap();
        assert!((u - 0.5).abs() < 0.01 && (v - 0.5).abs() < 0.01);
        assert_eq!(canvas_to_upright(0.05, 0.5, 1080, 1920, 0, 1280, 720), None);
    }

    #[test]
    fn placeholder_has_text_and_rgba_roundtrips_page_color() {
        let f = placeholder_i420(1280, 720, "waiting for phone");
        let mut rgba = vec![0; 1280 * 720 * 4];
        i420_to_rgba(&f, 1280, 720, &mut rgba);
        let (r, g, b) = (rgba[0] as i32, rgba[1] as i32, rgba[2] as i32);
        assert!((r - 0x1A).abs() <= 3 && (g - 0x1D).abs() <= 3 && (b - 0x38).abs() <= 3, "{r} {g} {b}");
        let ink = rgb_to_yuv(0xF4, 0xF1, 0xE8).0;
        assert!(f[..1280 * 720].iter().filter(|&&y| y == ink).count() > 1000);
    }
}
