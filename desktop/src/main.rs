//! Lenny Desktop: the receiver app. Rust over eframe/egui (winit), linking the core crate directly (no FFI).
//!
//! Usage: lenny-desktop [--port N] [--screenshot out.png [--after SECONDS]] [--size WxH]
//!   --screenshot renders the window, saves it after SECONDS (default 3) and quits (docs, smoke test under Xvfb).

// Release builds on Windows have no console window; the log goes to %APPDATA%\Lenny\lenny.log instead.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

use lenny_desktop::ui;

fn main() -> eframe::Result {
    let mut logger = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    #[cfg(all(windows, not(debug_assertions)))]
    if let Some(f) = lenny_desktop::receiver::config_dir().and_then(|d| {
        std::fs::create_dir_all(&d).ok()?;
        std::fs::File::create(d.join("lenny.log")).ok()
    }) {
        logger.target(env_logger::Target::Pipe(Box::new(f)));
    }
    logger.init();
    let args: Vec<String> = std::env::args().collect();
    let arg = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let port = arg("--port").and_then(|p| p.parse().ok()).unwrap_or(lenny_core::LENNY_DEFAULT_PORT);
    let after = std::time::Duration::from_secs_f32(arg("--after").and_then(|s| s.parse().ok()).unwrap_or(3.0));
    let screenshot = arg("--screenshot").map(|p| (std::path::PathBuf::from(p), after));
    let size =
        arg("--size").and_then(|s| s.split_once('x').and_then(|(w, h)| Some([w.parse().ok()?, h.parse().ok()?])));
    // Screenshot and --size runs get exactly the size asked for: no saved window, nothing saved.
    let remember = screenshot.is_none() && size.is_none();

    let options = eframe::NativeOptions {
        viewport: eframe::egui::ViewportBuilder::default()
            .with_title("Lenny Desktop")
            .with_app_id("com.spizganed.lenny")
            // Borderless: the title bar, window buttons, drag and resize are ours (ui.rs), drawn per docs/design.md.
            .with_decorations(false)
            .with_inner_size(size.unwrap_or([1360.0, 860.0]))
            .with_min_inner_size([420.0, 560.0])
            // First launch opens maximized; after that eframe restores the last size, position and maximized state.
            .with_maximized(remember),
        persist_window: remember,
        persistence_path: lenny_desktop::receiver::config_dir().filter(|_| remember).map(|d| d.join("window.ron")),
        #[cfg(windows)]
        event_loop_builder: Some(Box::new(|b| {
            use winit::platform::windows::EventLoopBuilderExtWindows;
            b.with_msg_hook(restore_before_close);
        })),
        ..Default::default()
    };
    eframe::run_native("Lenny Desktop", options, Box::new(move |cc| Ok(Box::new(ui::App::new(cc, port, screenshot)))))
}

/// Windows never paints a minimized window, and eframe only acts on a close request in its next frame, so "Close
/// window" from the taskbar did nothing while minimized. Restore first; the close then goes through as usual (and the
/// window state is saved un-minimized). Never consumes the message.
#[cfg(windows)]
fn restore_before_close(msg: *const std::ffi::c_void) -> bool {
    use windows_sys::Win32::UI::WindowsAndMessaging::*;
    // SAFETY: winit hands us the MSG it is about to dispatch.
    let m = unsafe { &*(msg as *const MSG) };
    let close = m.message == WM_CLOSE || (m.message == WM_SYSCOMMAND && m.wParam & 0xFFF0 == SC_CLOSE as usize);
    // SAFETY: plain Win32 calls on the window handle from the message.
    if close && unsafe { IsIconic(m.hwnd) } != 0 {
        unsafe { ShowWindow(m.hwnd, SW_RESTORE) };
    }
    false
}
