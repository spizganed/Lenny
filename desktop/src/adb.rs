//! USB through adb (architecture §7.5): `adb reverse tcp:PORT tcp:PORT` for every authorized phone, so the phone's
//! 127.0.0.1:PORT reaches this PC. Polled only while the USB (ADB) panel is open: no adb server for people who never
//! use it. Uses the user's own adb (PATH or the Android SDK), nothing bundled (licence note in CLAUDE.md).

use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub struct Adb {
    status: Arc<Mutex<Option<String>>>,
    busy: Arc<Mutex<bool>>,
    last: Option<Instant>,
}

impl Default for Adb {
    fn default() -> Self {
        Adb { status: Arc::new(Mutex::new(None)), busy: Arc::new(Mutex::new(false)), last: None }
    }
}

impl Adb {
    /// Checks again at most every 2 s (on a thread: adb can take a while to start its server). None = first check running.
    pub fn poll(&mut self, port: u16) -> Option<String> {
        let mut busy = self.busy.lock().unwrap();
        if !*busy && self.last.is_none_or(|t| t.elapsed() > Duration::from_secs(2)) {
            *busy = true;
            self.last = Some(Instant::now());
            let (status, busy) = (self.status.clone(), self.busy.clone());
            std::thread::spawn(move || {
                let s = check(port);
                *status.lock().unwrap() = Some(s);
                *busy.lock().unwrap() = false;
            });
        }
        drop(busy);
        self.status.lock().unwrap().clone()
    }
}

fn check(port: u16) -> String {
    let Some(adb) = find() else {
        return "adb isn't installed. Install Android SDK Platform-Tools, or connect over Wi-Fi.".into();
    };
    let Ok(out) = run(&adb, &["devices"]) else { return "adb didn't start.".into() };
    let text = String::from_utf8_lossy(&out.stdout);
    let devices: Vec<(&str, &str)> = text.lines().skip(1).filter_map(|l| l.split_once('\t')).collect();
    let fwd = format!("tcp:{port}");
    let ready = devices
        .iter()
        .filter(|(_, state)| *state == "device")
        .filter(|(serial, _)| run(&adb, &["-s", serial, "reverse", &fwd, &fwd]).is_ok_and(|o| o.status.success()))
        .count();
    if ready > 0 {
        "Ready. On the phone tap USB ADB, then Connect over USB.".into()
    } else if devices.iter().any(|(_, s)| *s == "unauthorized") {
        "Allow USB debugging on the phone (a prompt is on its screen).".into()
    } else {
        "No phone found. Plug it in with USB debugging on (Developer options).".into()
    }
}

fn run(adb: &PathBuf, args: &[&str]) -> std::io::Result<Output> {
    let mut c = Command::new(adb);
    c.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console flashing up from a GUI app
    }
    c.output()
}

/// adb on PATH, else the Android SDK's platform-tools.
fn find() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "adb.exe" } else { "adb" };
    let sdk = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].into_iter().filter_map(std::env::var_os).map(PathBuf::from);
    let default_sdk = if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Android/Sdk"))
    } else {
        std::env::var_os("HOME").map(|d| PathBuf::from(d).join("Android/Sdk"))
    };
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .chain(sdk.chain(default_sdk).map(|d| d.join("platform-tools")))
        .map(|d| d.join(exe))
        .find(|p| p.is_file())
}
