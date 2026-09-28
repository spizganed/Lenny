//! lenny_probe: headless receiver for testing senders without the desktop app (and for soak tests).
//! Auto-accepts any phone and prints one line of stats per second.  Usage: lenny_probe [port] [seconds] [--sweep]
//! --sweep: once streaming, select every lens and every mode it lists, one after another, and print what each really
//! delivers (a phone compatibility check: modes that fall back, stall or crash the phone app).

use std::os::raw::{c_char, c_void};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicI32, AtomicPtr, Ordering::Relaxed};
use std::time::Duration;

use lenny_core::session::Session;
use lenny_core::*;

static KEYFRAMES: AtomicI32 = AtomicI32::new(0);
static CONFIGS: AtomicI32 = AtomicI32::new(0);
static ORIENTATION: AtomicI32 = AtomicI32::new(0);
static RX: AtomicPtr<lenny_session> = AtomicPtr::new(null_mut());

unsafe extern "C" fn on_state(_: *mut c_void, st: i32, reason: i32) {
    println!("state {st} reason {reason}");
}
unsafe extern "C" fn on_approval(_: *mut c_void, _: *const u8, name: *const c_char) {
    println!("approving \"{}\"", std::ffi::CStr::from_ptr(name).to_string_lossy());
    lenny_receiver_approve(RX.load(Relaxed), 1); // same thread as the core, but approve() only sets a flag
}
unsafe extern "C" fn on_stream_start(_: *mut c_void, s: *const lenny_stream_settings) {
    let s = &*s;
    println!(
        "stream {}x{} @ {}/{} fps, {} kbps",
        s.mode.width, s.mode.height, s.mode.fps_num, s.mode.fps_den, s.bitrate_kbps
    );
}
unsafe extern "C" fn on_config(_: *mut c_void, _: *const u8, _: usize) {
    CONFIGS.fetch_add(1, Relaxed);
}
unsafe extern "C" fn on_frame(_: *mut c_void, f: *const lenny_video_frame) {
    if (*f).flags & LENNY_FRAME_KEYFRAME != 0 {
        KEYFRAMES.fetch_add(1, Relaxed);
    }
    ORIENTATION.store((*f).orientation as i32, Relaxed);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let port: u16 = args.get(1).and_then(|a| a.parse().ok()).unwrap_or(LENNY_DEFAULT_PORT);
    let seconds: u64 = args.get(2).and_then(|a| a.parse().ok()).unwrap_or(0); // 0 = forever
    let cfg = lenny_receiver_config {
        identity: lenny_identity {
            device_id: [0; 16],
            device_name: c"lenny_probe".as_ptr(),
            app_version: std::ptr::null(),
            platform: LENNY_PLATFORM_LINUX,
        },
        port,
        preferred: lenny_stream_settings {
            codec: LENNY_CODEC_H264,
            mode: lenny_mode { width: 1920, height: 1080, fps_num: 30, fps_den: 1 },
            bitrate_kbps: 8000,
            has_lens: 0,
            lens_id: 0,
        },
    };
    let mut cb: lenny_receiver_callbacks = unsafe { std::mem::zeroed() };
    cb.on_state = Some(on_state);
    cb.on_approval_needed = Some(on_approval);
    cb.on_stream_start = Some(on_stream_start);
    cb.on_video_config = Some(on_config);
    cb.on_video_frame = Some(on_frame);
    unsafe {
        let rx = lenny_receiver_create(&cfg, &cb);
        RX.store(rx, Relaxed);
        if rx.is_null() || lenny_receiver_start(rx) != LENNY_OK {
            eprintln!("cannot listen on {port}");
            std::process::exit(1);
        }
        println!("listening on {}", lenny_receiver_port(rx));
        if args.iter().any(|a| a == "--sweep") {
            sweep(&*(rx as *const Session)); // lenny_session* is a Box<Session> (abi.rs)
            lenny_session_destroy(rx);
            return;
        }
        let mut last = lenny_stats::default();
        let mut t = 0;
        while seconds == 0 || t < seconds {
            std::thread::sleep(Duration::from_secs(1));
            let mut s = lenny_stats::default();
            lenny_session_get_stats(rx, &mut s);
            if s.frames != last.frames {
                println!(
                    "fps {}  kbps {}  keyframes {}  configs {}  rtt {:.1} ms  latency {:.1} ms  orientation {}",
                    s.frames - last.frames,
                    (s.bytes - last.bytes) * 8 / 1000,
                    KEYFRAMES.load(Relaxed),
                    CONFIGS.load(Relaxed),
                    s.rtt_us as f64 / 1000.0,
                    s.latency_us as f64 / 1000.0,
                    ORIENTATION.load(Relaxed) * 90
                );
            }
            last = s;
            t += 1;
        }
        lenny_session_destroy(rx);
    }
}

/// Waits up to `secs` for the phone to be streaming. False = it didn't come (back).
fn wait_streaming(s: &Session, secs: u64) -> bool {
    for _ in 0..secs * 10 {
        if s.state() == LENNY_STATE_STREAMING as i32 && s.peer_caps().is_some() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// Frames per second over `secs`, and whether the phone stayed connected the whole time.
fn measure(s: &Session, secs: u64) -> (f64, bool) {
    let start = s.stats().frames;
    let mut ok = true;
    for _ in 0..secs * 10 {
        std::thread::sleep(Duration::from_millis(100));
        ok &= s.state() == LENNY_STATE_STREAMING as i32;
    }
    ((s.stats().frames - start) as f64 / secs as f64, ok)
}

fn sweep(s: &Session) {
    println!("waiting for a phone...");
    if !wait_streaming(s, 600) {
        return println!("no phone");
    }
    let caps = s.peer_caps().unwrap();
    let fmt = |m: &lenny_mode| format!("{}x{}@{}", m.width, m.height, m.fps_num / m.fps_den.max(1));
    for lens in &caps.lenses {
        let label = String::from_utf8_lossy(&lens.label).to_string();
        let modes = if lens.modes.is_empty() { &caps.modes } else { &lens.modes };
        println!("\n== lens {} \"{label}\": {}", lens.id, modes.iter().map(fmt).collect::<Vec<_>>().join(" "));
        for m in modes {
            if !wait_streaming(s, 20) {
                return println!("phone gone (crashed or disconnected), sweep stopped");
            }
            let mut c =
                lenny_control { cmd: LENNY_CTL_SELECT_LENS as u16, value: lens.id as i32, ..Default::default() };
            s.send_control(&mut c);
            std::thread::sleep(Duration::from_millis(1500));
            let (_, cur) = s.stream_settings();
            s.select_stream(&lenny_stream_settings { mode: *m, ..cur });
            std::thread::sleep(Duration::from_secs(2)); // switch + first keyframe
            let (fps, stayed) = measure(s, 3);
            let (_, got) = s.stream_settings();
            let note = match (stayed, got.mode == *m) {
                (false, _) => "DISCONNECTED",
                (true, true) => "ok",
                (true, false) => "fell back",
            };
            println!("  asked {:<14} got {:<14} {fps:>5.1} fps  {note}", fmt(m), fmt(&got.mode));
        }
    }
}
