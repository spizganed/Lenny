//! Real Linux virtual camera: a v4l2loopback device (kernel module, `modprobe v4l2loopback exclusive_caps=1`).
//! We are its producer: set an OUTPUT format once, then write() whole I420 frames. Any app that reads /dev/videoN
//! (Chrome, Zoom, OBS, ffplay) sees it as a camera.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::process::Command;

use crate::{FrameFormat, IVirtualCamera, Result};

// <linux/videodev2.h>, just the bits we need.
#[repr(C)]
struct Capability {
    driver: [u8; 16],
    card: [u8; 32],
    bus_info: [u8; 32],
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [u32; 3],
}

#[repr(C)]
#[derive(Default)]
struct PixFormat {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv_: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
}

/// struct v4l2_format: the union holds pointers (v4l2_window), so it's pointer-aligned: 204 bytes on 32-bit, 208 on
/// 64-bit, which matters because the size is encoded in the ioctl number.
#[repr(C)]
struct Format {
    typ: u32,
    fmt: FormatUnion,
}

#[repr(C)]
union FormatUnion {
    pix: std::mem::ManuallyDrop<PixFormat>,
    raw: [u8; 200],
    _align: [*const u8; 0],
}

const fn ior(nr: u64, size: usize) -> u64 {
    (2 << 30) | ((size as u64) << 16) | ((b'V' as u64) << 8) | nr
}
const fn iowr(nr: u64, size: usize) -> u64 {
    (3 << 30) | ((size as u64) << 16) | ((b'V' as u64) << 8) | nr
}
const VIDIOC_QUERYCAP: u64 = ior(0, std::mem::size_of::<Capability>());
const VIDIOC_S_FMT: u64 = iowr(5, std::mem::size_of::<Format>());
const BUF_TYPE_VIDEO_OUTPUT: u32 = 2;
const FIELD_NONE: u32 = 1;
const COLORSPACE_REC709: u32 = 3;
const PIX_FMT_YUV420: u32 = u32::from_le_bytes(*b"YU12");

pub struct V4l2LoopbackCamera {
    path: String,
    dev: File,
    format: Option<FrameFormat>,
}

fn is_loopback(dev: &File) -> bool {
    // SAFETY: plain-data out struct of the size the ioctl expects.
    let mut cap: Capability = unsafe { std::mem::zeroed() };
    let r = unsafe { libc::ioctl(dev.as_raw_fd(), VIDIOC_QUERYCAP as _, &mut cap) };
    r == 0 && cap.driver.starts_with(b"v4l2 loopback")
}

fn find() -> Option<V4l2LoopbackCamera> {
    (0..64).find_map(|n| {
        let path = format!("/dev/video{n}");
        let dev = OpenOptions::new().read(true).write(true).open(&path).ok()?;
        is_loopback(&dev).then_some(V4l2LoopbackCamera { path, dev, format: None })
    })
}

impl V4l2LoopbackCamera {
    /// First v4l2loopback device; if there's none, tries to load the module once (needs root / CAP_SYS_MODULE).
    pub fn find_or_load() -> Result<Self> {
        if let Some(c) = find() {
            return Ok(c);
        }
        let out = Command::new("modprobe")
            .args(["v4l2loopback", "devices=1", "exclusive_caps=1", "card_label=Lenny"])
            .output()
            .map_err(|e| format!("no v4l2loopback device, and modprobe couldn't run: {e}"))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            return Err(format!("no v4l2loopback device, and loading the module failed: {}", err.trim()));
        }
        find().ok_or_else(|| "v4l2loopback loaded but no device appeared".into())
    }
}

impl IVirtualCamera for V4l2LoopbackCamera {
    fn open(&mut self, f: FrameFormat) -> Result<()> {
        let pix = PixFormat {
            width: f.width,
            height: f.height,
            pixelformat: PIX_FMT_YUV420,
            field: FIELD_NONE,
            bytesperline: f.width,
            sizeimage: f.frame_size() as u32,
            colorspace: COLORSPACE_REC709,
            ..Default::default()
        };
        let mut fmt = Format { typ: BUF_TYPE_VIDEO_OUTPUT, fmt: FormatUnion { raw: [0; 200] } };
        fmt.fmt.pix = std::mem::ManuallyDrop::new(pix);
        // SAFETY: fmt is a correctly sized, initialized v4l2_format.
        if unsafe { libc::ioctl(self.dev.as_raw_fd(), VIDIOC_S_FMT as _, &mut fmt) } != 0 {
            return Err(format!("{}: VIDIOC_S_FMT: {}", self.path, std::io::Error::last_os_error()));
        }
        self.format = Some(f);
        Ok(())
    }

    fn write_frame(&mut self, frame: &[u8]) -> Result<()> {
        let f = self.format.ok_or("not open")?;
        if frame.len() != f.frame_size() {
            return Err(format!("frame is {} bytes, expected {}", frame.len(), f.frame_size()));
        }
        self.dev.write_all(frame).map_err(|e| format!("{}: {e}", self.path))
    }

    fn close(&mut self) {
        self.format = None;
    }

    fn is_real(&self) -> bool {
        true
    }

    fn describe(&self) -> String {
        format!("v4l2loopback {}", self.path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ioctl_numbers_match_the_kernel_headers() {
        assert_eq!(VIDIOC_QUERYCAP, 0x8068_5600);
        #[cfg(target_pointer_width = "64")]
        assert_eq!(VIDIOC_S_FMT, 0xC0D0_5605);
        #[cfg(target_pointer_width = "32")]
        assert_eq!(VIDIOC_S_FMT, 0xC0CC_5605);
    }
}
