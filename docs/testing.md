# Testing

Automated:
- `core/`: `cargo test -p lenny_core` (wire format, test vectors, full sessions over localhost TCP, struct layouts).
  `core/tools/abi_check.sh` (cbindgen header vs lenny.h). `core/tests/c_abi/`: the C++ session test against the Rust
  library, under ASan/UBSan in CI.
- `vcam/`: `cargo test -p lenny_vcam` (compose/rotate/letterbox, placeholder, null backend, v4l2 ioctl numbers).
- `desktop/`: `cargo test -p lenny_desktop`: QR link format, known phones, and `tests/loopback.rs`: fake phone ->
  core -> decode -> preview/virtual camera, zoom/pan/focus/Auto round trips, mid-stream mode switch. Headless.
- `vcam/com/` (Windows only, CI `windows` job): `cargo test -p lenny_vcam_com` (also `--target i686-pc-windows-msvc`):
  DirectShow filter in a real filter graph, MF source through IMFActivate like Frame Server (placeholder frames).
  CI also runs regsvr32 register/unregister on both builds.
- `framebuf/`: `cargo test -p lenny_framebuf` (ring layout, seqlock under a racing writer, corrupt header).
- `plugins/android_camera`: `./gradlew :android_camera:testDebugUnitTest` (from `app/android`): zoom/pan crop math,
  mode matching (JVM, no device).
- `app/test/mode_controls_test.dart`: Auto/Manual widget behaviour.
- `app/`: `flutter test`.

Tools:
- `cargo run --release --bin lenny_probe -- [port] [seconds]`: headless receiver that auto-accepts phones and prints fps, bitrate,
  keyframes, RTT and latency once a second. Use it to test a sender without the desktop app, and for soak tests (M6).
- `lenny_probe [port] 0 --sweep`: selects every lens and every mode the phone lists and prints what each delivers
  (ok / fell back / DISCONNECTED). A phone compatibility check. A phone that can't reach the PC (e.g. the PC is on
  another phone's tethering) connects over wireless adb: `adb reverse tcp:47474 tcp:47474`, PC address `127.0.0.1`.
  2026-09-27, Honor X5c Plus (NLA-LX1, Helio G85, Android 15): all 56 modes ok on Back and Front (2560x1440 down to
  640x480, 15/20/24/30 fps); no high-speed video, so no 60 fps offered. 2026-09-28 same result over USB adb. Known:
  at a fixed AE range [30,30] its HAL caps ISO at ~231 (indoors ~5x darker than 24 fps, which gets ISO 850 at 40 ms);
  [5,30] is bright but drops to 20 fps. Kept [30,30]. 2026-09-28: [15,30] was tried for a dark room on the Nothing, but moving the phone got choppy at
  15 fps; back to [30,30]. A hidden low-light +2 EV in Auto was
  tried the same day and removed: Auto is the phone's own 3A, nothing on top; Manual EV brightens a dark room.
  2026-09-28, Honor Magic7 Lite (BRP-NX1M), Lenny 1.0.0 over Wi-Fi: every camera
  tried, no crashes, no bugs (user's run, by hand).
- Emulator: the phone reaches the PC at `10.0.2.2`. The AVD's back camera should be `virtualscene`. Needs hardware
  acceleration (KVM / HAXM / Hyper-V); the cloud sandbox has none, so it isn't used there.
- Fake phone: `cargo run -p lenny_desktop --example fake_phone -- <host> <port> [--portrait]`: a synthetic sender
  (openh264) for trying the desktop app without a phone. Not a camera test.
- `lenny-desktop --screenshot out.png [--after s] [--size WxH]`: renders, saves a PNG, quits (Xvfb-friendly).
- `tools/linux-test-vm.ps1` (Windows, elevated PowerShell): Hyper-V + Ubuntu 24.04 Xfce VM with v4l2loopback,
  OBS, Discord, Chromium and Lenny Desktop built from a branch, on an external switch so a phone can connect. First
  boot ~20-40 min; progress in `serial.log` next to the VM.

Debug output (logs, dumps, captured streams) stays local and is gitignored. Never commit it.

## Manual smoke test, M2 (Android -> Windows preview over Wi-Fi)

Last run: 2026-09-25, emulator (Android 16, x86_64) -> Windows 11, Lenny Desktop debug build.

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Start Lenny Desktop | "Waiting for a phone", shows this PC's IPs and port | ✅ |
| 2 | Phone: enter PC address, Connect | Desktop: "Allow this phone?" with the phone's name | ✅ |
| 3 | Allow | Both sides "Streaming"; live upright preview; stats line (1080p, ~30 fps) | ✅ 1080p30, ~7.5 Mbps, RTT 1 ms |
| 4 | Decline (or wait 30 s) | Phone: "The PC declined the connection", stops retrying | covered by core tests |
| 5 | Phone: Disconnect | Phone "Disconnected"; desktop back to waiting | ✅ |
| 6 | Quit desktop app while streaming | Phone: "Connection lost. Reconnecting…" | ✅ |
| 7 | Hard-kill desktop app, start it again | Phone reconnects by itself (asks for approval again: trust isn't persisted yet) | ✅ |
| 8 | Phone held in portrait | Desktop preview upright, letterboxed | ✅ |
| 9 | Screen off / app in background while streaming | Stream continues (camera foreground service) | not yet run |
| 10 | Real phone over Wi-Fi (not emulator) | Same as 2–8 | not yet run (phone busy) |

## Manual smoke test, M3 (camera controls, latency)

Last run: 2026-09-25, emulator (Android 16, x86_64) -> Windows 11. Latency is capture -> received, from
`lenny_probe` or the desktop stats line.

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Streaming, back camera | Latency shown, steady (not climbing) | ✅ 25–55 ms, levels off |
| 2 | Switch to Front | Stream continues, preview flips, latency still shown | ✅ ~3 ms (emulator front clock is off, so it counts from encoder output) |
| 3 | Switch back to Back | Same as 1 | ✅ |
| 4 | Torch, Lock focus, Auto, exposure ± | Phone applies it, desktop controls mirror phone state | ✅ |
| 5 | Tap the desktop preview | Phone focuses there | ✅ |
| 6 | Real phone over Wi-Fi | Same as 1–5, glass-to-glass < 150 ms | ✅ Nothing Phone (3a): 30 fps 1080p, 110–140 ms capture -> shown (release desktop; a debug desktop adds 100+ ms converting the preview) |
| 7 | Lens buttons (0.6×, 1×, 2×, Front on a phone with those) | Each switches, stream stays at the negotiated size | ✅ 1920×1080 on every lens |
| 8 | Phone standing in landscape | Desktop preview upright | ✅ |

Known: white specks along dark edges in low light (seen on 0.6× and front). Converter math checked; source not
yet isolated (phone ISP sharpening vs decoder concealment).

## Desktop (Rust, Linux), cloud sandbox run

Last run: 2026-09-26, Ubuntu 24.04 container, Xvfb + openbox, fake phone (no real phone, no emulator, no
v4l2loopback). Screenshots in `docs/screenshots/desktop-linux-*.png`.

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Start `lenny-desktop` | Waiting state, QR, IP/port chips, virtual camera status | ✅ "Virtual camera: unavailable in this environment" (null backend: no v4l2loopback device, modprobe unavailable) |
| 2 | Unknown phone connects | "Allow this phone?" dialog, Allow/Decline | ✅ |
| 3 | Known phone connects | Streams without prompt; preview + stats | ✅ 1920x1080, null camera writing 30.0 fps |
| 4 | Portrait phone (orientation 90°) | Preview box becomes 9:16, upright, not stretched | ✅ |
| 5 | Mouse wheel on preview, then drag | Zoom to the lens max (4.0x), drag pans the phone's crop | ✅ (fake sensor crop moves) |
| 6 | Title bar: maximize, restore, double-click, drag, minimize, close; edge resize | Real window changes | ✅ via xdotool: 1200x800 -> 1600x1000 -> back; moved; hidden; exit 0; 1200 -> 840 px wide |
| 7 | Narrow window (560 px) | One column: preview, then cards | ✅ |
| 8 | Real phone over Wi-Fi, real v4l2loopback consumers (Chrome, OBS, Zoom) | Camera visible and live in each | not run: needs a local machine |
| 9 | Windows 10/11 | — | Windows 11 run below |

## Desktop (Rust) on Windows 11, real phone

Last run: 2026-09-26, Windows 11 Pro PC, Nothing Phone (3a) release APK from this branch, over Wi-Fi.

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | `cargo test --workspace`, fmt, clippy, `flutter analyze`/`test` on Windows | All pass | ✅ |
| 2 | `cargo build --release -p lenny_desktop` on Windows | Builds as-is | ✅ |
| 3 | `flutter build apk --release` | Builds with the Rust core | ✅ after `rustup target add i686-linux-android` (all four Android targets are needed) |
| 4 | Real phone connects to `lenny-desktop` | Live preview + stats | ✅ 1920x1080 30 fps, ~5 ms round trip, 34-58 ms latency |
| 5 | Lens list | Per-lens buttons from the phone | ✅ 0.6x, 1x, 2x, Front; portrait phone shows 9:16 preview |
| 6 | Restart the desktop app | Phone reconnects by itself | ✅ |
| 7 | Virtual camera | — | not run: `regsvr32` needs an elevated prompt (non-admin fails with code 5) |

The first, VirtualBox version of `tools/linux-test-vm.ps1` on this PC: the script itself works (VirtualBox via winget, IMAPI2 seed ISO, VM boots,
cloud-init runs), but with Hyper-V on (WSL2 / VBS) VirtualBox runs on top of it and the guest hits RCU stalls and
soft lockups (4 and 2 vCPUs alike), and bridging over a USB Wi-Fi adapter downloaded at ~60 kB/s (NAT: normal).
The script now builds a Hyper-V VM instead (2026-09-28); not run yet.

## Windows virtual cameras (Rust, `vcam/com`)

Last run: 2026-09-27, Windows 11 Pro (26200), installed with `installer\build.ps1` → `Lenny-Setup-0.1.0.exe`, fake phone
and Nothing Phone (3a) over Wi-Fi, app started unelevated (Start menu / explorer) with the broker service running.
Consumers driven by script: OpenCV (DirectShow) and headless Edge getUserMedia (Media Foundation). 2026-09-28, Lenny
1.0.0: the user ran the by-hand list (Zoom, Teams, Discord in calls, OBS, 32-bit app, Win10, standard account) and
reports it all passes; per-item details weren't recorded.

Setup: install with the setup exe (elevated). For development without the installer, copy both DLLs somewhere
**outside your user profile** (e.g. `C:\Program Files\Lenny\` and `...\x86\`) before `regsvr32`: Frame Server runs as
LOCAL SERVICE, can't read `C:\Users\<you>\...`, and `MFCreateVirtualCamera`'s `Start` then fails with
`Access is denied (0x80070005)`. DirectShow works from anywhere. Consumers (browsers, Discord, Frame Server) keep the
DLL loaded after enumerating cameras, so rebuilding it fails with "Access is denied": rename the old file first.

Findings: Windows appends " (Windows Virtual Camera)" to the MF camera's name, so Edge lists "Lenny (Windows Virtual
Camera)" and "Lenny (Classic)". Win11 also exposes the MF camera to DirectShow apps, so those see two Lenny devices too
(R5). The MF camera exists only while the app runs (Session lifetime).

| # | Step | Expected | Win10 | Win11 |
|---|---|---|---|---|
| 1 | Desktop app not running, open the camera | "Lenny (Classic)" with the placeholder (MF camera gone: Session lifetime) | | ✅ DirectShow placeholder |
| 2 | Start the app, phone streams | Live picture within 1 s, upright | | ✅ fake phone, both cameras 1280×720 |
| 3 | Quit the app while a consumer is open | Last frame ≤ 0.5 s, then placeholder; consumer doesn't crash | | ✅ killed the app: last frame, placeholder after ~1.5 s (heartbeat 1 s + 0.5 s), consumer kept reading |
| 4 | Chrome/Edge getUserMedia (webcamtests.com) | Camera listed, live | | ✅ headless Edge: both listed, live |
| 5 | Zoom, Teams, Discord | Camera listed, live, call keeps running through app restarts | ✅ user, in calls (1.0.0) | ✅ user, in calls (1.0.0) |
| 6 | 32-bit consumer (a 32-bit DirectShow app, e.g. AMCap x86) | Live | ✅ user (1.0.0) | ✅ user (1.0.0) |
| 7 | Unelevated app (normal launch) | Broker holds `Global\`: both cameras live | | ✅ admin account, unelevated token; a true standard account not tried |
| 7b | Real phone streams to the installed app | Both cameras show the phone | | ✅ Nothing Phone (3a), Wi-Fi marked Public (needed the all-profiles firewall rule) |
| 8 | Installer: install, upgrade over a running consumer, uninstall | Files, both COM registrations, broker service, firewall rule, shortcuts, Add/Remove entry; uninstall removes all (locked DLLs on reboot) | | ✅ silent `/S` install, reinstall, uninstall; 1.0.0: uninstall with Brave/Discord holding the DLL removes the install folder at once (user) |
