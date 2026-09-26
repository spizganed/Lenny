//! Null backend: always works, needs no privileges. Keeps `frames.log` (one line per second: count, size, rate) and
//! overwrites `latest.i420` + `latest.txt` with a sample frame every second, so the pipeline up to the virtual
//! camera can be checked (e.g. `ffplay -f rawvideo -pixel_format yuv420p -video_size 1280x720 latest.i420`).

use std::fs::{self, File};
use std::io::Write;
use std::path::PathBuf;
use std::time::Instant;

use crate::{FrameFormat, IVirtualCamera, Result};

pub fn default_dir() -> PathBuf {
    std::env::temp_dir().join("lenny-null-vcam")
}

pub struct NullVirtualCamera {
    dir: PathBuf,
    why: String,
    format: Option<FrameFormat>,
    log: Option<File>,
    frames: u64,
    frames_at_last_sample: u64,
    last_sample: Option<Instant>,
}

impl NullVirtualCamera {
    /// `why`: the reason there's no real device, shown in the UI.
    pub fn new(dir: PathBuf, why: String) -> Self {
        Self { dir, why, format: None, log: None, frames: 0, frames_at_last_sample: 0, last_sample: None }
    }

    pub fn frames(&self) -> u64 {
        self.frames
    }
}

impl IVirtualCamera for NullVirtualCamera {
    fn open(&mut self, format: FrameFormat) -> Result<()> {
        fs::create_dir_all(&self.dir).map_err(|e| format!("{}: {e}", self.dir.display()))?;
        let mut log = File::create(self.dir.join("frames.log")).map_err(|e| e.to_string())?;
        let _ = writeln!(log, "open {}x{} I420 @ {} fps", format.width, format.height, format.fps);
        self.log = Some(log);
        self.format = Some(format);
        self.frames = 0;
        self.frames_at_last_sample = 0;
        self.last_sample = None;
        Ok(())
    }

    fn write_frame(&mut self, frame: &[u8]) -> Result<()> {
        let f = self.format.ok_or("not open")?;
        if frame.len() != f.frame_size() {
            return Err(format!("frame is {} bytes, expected {}", frame.len(), f.frame_size()));
        }
        self.frames += 1;
        let now = Instant::now();
        if self.last_sample.is_some_and(|t| now.duration_since(t).as_secs() < 1) {
            return Ok(());
        }
        let secs = self.last_sample.map_or(1.0, |t| now.duration_since(t).as_secs_f64());
        let fps = (self.frames - self.frames_at_last_sample) as f64 / secs;
        self.last_sample = Some(now);
        self.frames_at_last_sample = self.frames;
        if let Some(log) = &mut self.log {
            let _ = writeln!(log, "frame {} {}x{} {:.1} fps", self.frames, f.width, f.height, fps);
        }
        // Write-then-rename so a reader never sees half a frame.
        let tmp = self.dir.join("latest.i420.tmp");
        fs::write(&tmp, frame)
            .and_then(|_| fs::rename(&tmp, self.dir.join("latest.i420")))
            .map_err(|e| e.to_string())?;
        let meta = format!("{}x{} I420 frame {}\n", f.width, f.height, self.frames);
        fs::write(self.dir.join("latest.txt"), meta).map_err(|e| e.to_string())
    }

    fn close(&mut self) {
        if let Some(log) = &mut self.log {
            let _ = writeln!(log, "close after {} frames", self.frames);
        }
        self.log = None;
        self.format = None;
    }

    fn is_real(&self) -> bool {
        false
    }

    fn describe(&self) -> String {
        format!("null (frames to {}): {}", self.dir.display(), self.why)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_log_and_sample() {
        let dir = std::env::temp_dir().join(format!("lenny-null-test-{}", std::process::id()));
        let mut cam = NullVirtualCamera::new(dir.clone(), "test".into());
        let f = FrameFormat { width: 64, height: 32, fps: 30 };
        cam.open(f).unwrap();
        assert!(cam.write_frame(&[0; 10]).is_err());
        let frame = vec![7u8; f.frame_size()];
        cam.write_frame(&frame).unwrap();
        cam.write_frame(&frame).unwrap();
        cam.close();
        assert_eq!(fs::read(dir.join("latest.i420")).unwrap(), frame);
        let log = fs::read_to_string(dir.join("frames.log")).unwrap();
        assert!(log.starts_with("open 64x32") && log.contains("close after 2 frames"), "{log}");
        assert!(!cam.is_real() && cam.describe().contains("test"));
        let _ = fs::remove_dir_all(dir);
    }
}
