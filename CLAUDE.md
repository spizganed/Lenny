# Lenny

Phone-as-webcam: a phone (sender) streams its camera to a desktop (receiver),
which exposes it as a real OS-level virtual camera to Zoom/Teams/Discord/OBS/
browsers. Wi-Fi or USB.

Always read these before making changes in their area:
- @docs/architecture.md — overall system shape
- @docs/protocol.md — wire protocol (byte-for-byte spec, do not improvise)
- @docs/design.md — visual design system (colors, shape, shadow, motion rules)
- @docs/testing.md — manual smoke-test checklists per milestone
- @docs/adr/ — one decision per file; read before revisiting a past decision

## Current phase vs. target architecture — read this first

This project is mid-migration.

**Phase A (done):** the C++ core was ported to Rust with the C ABI held
identical (ADR-0006), so the Flutter phone app and its `dart:ffi` bindings kept
working unchanged.

**Phase B (in progress):** each platform gets a native app.
- Windows + Linux desktop: done. Rust egui app (`/desktop`, ADR-0007) linking
  the core crate directly; Windows virtual cameras in Rust (`vcam/com`, windows-rs).
  The Flutter desktop + `plugins/windows_receiver` were removed (ADR-0011).
- Android: still Flutter + the Kotlin `android_camera` plugin. Target: Kotlin +
  Jetpack Compose over JNI (or UniFFI), no Flutter. Not started.
- iOS: later, same pattern. macOS dropped.

**The UI is never shared as code across platforms, only as a spec.**
`docs/design.md` is the single source of truth for how every screen should
look and animate (colors, outline width, hard offset shadow, press-sink
animation, corner radii). Every platform's native UI must match it visually;
none of them share UI code or a UI framework to do so. When `docs/design.md`
changes, every platform's implementation needs a matching update — check for
drift, it won't happen automatically like it would in one shared codebase.

## Status and next (2026-09-28)

Lenny 1.0.0 is released (GitHub Releases: setup exe, APK, debug-signed AAB).
Works on Windows 11 with both virtual cameras (Edge/OpenCV/Discord enumeration),
broker service (ADR-0009), NSIS installer (ADR-0008). Phones tested: Nothing
Phone (3a), Honor X5c Plus, Honor Magic7 Lite. Zoom/Teams/Discord calls, OBS,
32-bit, Win10 and a standard account pass (user, by hand). Licence: GPL-3.0
(ADR-0010). Test records: `docs/testing.md`.

Next:
- Phone layout must adapt to any screen size: labels truncate in portrait on
  the Honor X5c Plus ("Scan …", "Find P…", "USB"), and landscape needs rework.
- Linux on real v4l2loopback: `tools/linux-test-vm.ps1` builds a Hyper-V VM
  (never run yet; VirtualBox stalls with Hyper-V on).
- Phone: lock-screen streaming untested (testing.md M2 row 9).
- One vcam size (1280×720); add 1080p once the desktop writes a 1080p canvas.
  If both cameras showing in MF-aware apps confuses people, revisit (R5).

Loose ends: openh264 rejects frames over 1 MB (check 4K keyframes); the
Android encoder doesn't request a profile (Baseline by default, which openh264
needs); `core/CMakeLists.txt` cargo wrapper never built on Windows.

Decided, don't revisit without asking: no known-devices list in either app
(the desktop still saves phones for trust, the phone prefills the last PC); the preview follows the video's aspect, not a fixed
16:9; Auto is the phone's own 3A with nothing on top (fps range [30,30]; [15,30],
hidden +EV and face-priority AE were tried and reverted); pan only on
FREEFORM-cropping cameras; Discord mirrors its own self-view (not a bug); no
digital zoom fallback on Android. Lag reports: check 2.4 GHz Wi-Fi first
(5 GHz / USB tether ≈ 30 ms).

Free-forever check (2026-09-27; the user never wants to pay fees): all 409
Rust crates are permissive (MIT/Apache/BSD/Zlib/ISC/Unicode-3.0), Flutter and
Android deps too, NSIS is zlib (ADR-0008), GitHub Actions is free for public
repos. Watch:
- H.264 patents: openh264 built from source isn't covered by Cisco's royalty
  payment (only Cisco's prebuilt binary is). Via LA has a free tier (first
  100k units/year), and Windows' own MF decoder is licensed with the OS, so
  prefer MF decode on Windows; Linux can load Cisco's binary at runtime.
- adb: platform-tools binaries come under the Android SDK licence, so nothing
  is bundled; USB ADB uses the user's own adb.
- Google Play: one-time $25 developer fee when publishing the Android app.

Checks before any push: `cargo fmt --all --check`, `cargo clippy --workspace
--all-targets -- -D warnings` (CI uses the latest stable, whose lints are
stricter than older toolchains), `cargo test --workspace`,
`core/tools/abi_check.sh` (needs cbindgen + clang), and for app changes
`flutter analyze && flutter test` in `app/` plus
`./gradlew :android_camera:testDebugUnitTest` in `app/android`.

## Non-negotiable engineering rules (apply in both phases)

- **Auto mode is the default, always.** Continuous autofocus, auto exposure/
  ISO, auto white balance, from first connect. Manual controls are opt-in
  overlays, never a required setup step.
- **Never let a native failure crash the host app.** The DirectShow filter /
  MF virtual camera runs inside Zoom/Teams/whatever process consumes it. Any
  native-side error must fail safely: log it, show a placeholder frame, keep
  the device alive. A crash here takes down someone else's call, which is
  worse than any other class of bug in this project.
- **Reconnect automatically** through phone sleep/lock, app switching,
  rotation, and Wi-Fi/USB hot-swap. Never leave a frozen or black frame
  without an explanatory UI state.
- **QR quick-connect uses a short-lived, single-use pairing token** — never
  bake a permanent secret into the QR payload. See `docs/protocol.md` for the
  pairing message types.
- **Windows needs both virtual camera backends**, not one: DirectShow filter
  (Win10+11 baseline, x86 and x64) and `MFCreateVirtualCamera` (Win11 extra,
  for MF-only consumers). Skipping either silently breaks some apps.
- **Wire protocol is versioned and forward-tolerant**: unknown message types
  are ignored, not fatal. Don't change framing/magic/limits without updating
  `docs/protocol.md` and `protocol/vectors/` together.
- **Test against real consumers, not just a preview window**: Zoom, Discord,
  Teams, Chrome/Edge (getUserMedia), and OBS, on both Windows 10 and 11.

## Code-minimalism tools

If a "write less code" style skill/rule is active in a session, it does not
override the architecture above. The core/platform boundaries, the dual
Windows virtual-camera backends, and the design-spec-not-shared-code approach
to UI are intentional, even where a shorter single-platform hack would work.
Apply minimalism inside a component's implementation, not by removing these
boundaries.

## Repo hygiene

- One ADR per real decision in `docs/adr/`. Superseded ADRs stay in the repo
  (marked superseded), never deleted — they're the record of why we changed
  course.
