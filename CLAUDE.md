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

This project is mid-migration. Don't assume either state without checking
which phase is active (see "Where we are" below).

**Phase A (current, interim):** C++ core is being ported to Rust with the C
ABI held identical, so the existing Flutter app and its `dart:ffi` bindings
keep working unchanged throughout. Flutter is scaffolding here — it exists so
the Rust core can be validated end-to-end (real sender ↔ real receiver)
without also rewriting the UI at the same time. Do not add new Flutter
screens or features during this phase; only keep it building.

**Phase B (planned, not started):** once the Rust core is fully ported and
tested, Flutter is removed entirely. Each platform gets a normal native app:
- Android: Kotlin + Jetpack Compose, calling the Rust core via JNI (or UniFFI
  if the boundary gets complex). No Flutter, no `dart:ffi`.
- Windows: a Rust desktop app (egui or iced), linking the Rust core crate
  directly — no FFI layer needed since it's Rust calling Rust. Spike this
  early: confirm `windows-rs` can register a DirectShow filter and drive
  `MFCreateVirtualCamera` before writing any UI. Only fall back to a small
  isolated C++ shim for a specific COM interface `windows-rs` genuinely
  doesn't expose — never for the whole app.
- iOS/macOS/Linux: come later, same pattern (native per platform).

**The UI is never shared as code across platforms, only as a spec.**
`docs/design.md` is the single source of truth for how every screen should
look and animate (colors, outline width, hard offset shadow, press-sink
animation, corner radii). Every platform's native UI must match it visually;
none of them share UI code or a UI framework to do so. When `docs/design.md`
changes, every platform's implementation needs a matching update — check for
drift, it won't happen automatically like it would in one shared codebase.

**Where we are:** check the current branch and `docs/adr/` for the latest
superseding ADR before assuming which phase applies. If unclear, ask rather
than guessing which architecture is currently in force.

Status (2026-09-26, end of the cloud session):
- **Core**: ported to Rust and tested (ADR-0006). C ABI unchanged and checked by
  `core/tools/abi_check.sh`; wire protocol now 1.1 (per-lens modes/zoom, pan).
- **Linux desktop receiver** (`/desktop`, Rust/egui, ADR-0007): working end to
  end with a synthetic phone. Virtual camera ran on the **null backend** (the
  sandbox can't load v4l2loopback); the real v4l2loopback path needs a local run.
- **Android**: per-lens camera discovery, capture-level zoom/pan, Auto/Manual
  modes, all on Camera2. APK builds with the Rust core via cargo-ndk. Real
  camera behaviour (AF, exposure, lenses) is untested — needs a real phone.
- **Windows** (2026-09-27): both virtual cameras live on Win11 (Edge getUserMedia via MF and DirectShow, OpenCV
  DirectShow, real phone), broker service (ADR-0009), NSIS installer + uninstaller (`installer\build.ps1`,
  ADR-0008). Zoom/Teams/Discord/OBS by hand and Win10 not run yet (testing.md Windows table).

## Handoff: next session runs on the Windows PC (CLI agent)

The cloud session (branch `rust-rewrite-cloud`, PR #3, CI green) did Tasks 1–8:
Rust core behind the unchanged C ABI, protocol 1.1, Android per-lens discovery /
capture-level zoom+pan / Auto-Manual, the Rust egui desktop (Linux) with
`lenny_vcam` (`IVirtualCamera`, v4l2loopback + null backends), fake phone,
`tools/linux-test-vm.ps1`. Details: ADR-0006, ADR-0007, architecture §7a,
testing.md "Desktop (Rust, Linux)". Nothing was run on real hardware.

Do these in order:

1. **Done 2026-09-27:** PR #3 merged into main after a Windows 11 + real phone run (results in
   `docs/testing.md`). Still open: Linux on real v4l2loopback (row 8). `tools/linux-test-vm.ps1`
   stalls on this PC because Hyper-V is on; the next Linux VM should be a Hyper-V VM, not VirtualBox.
2. **Windows virtual camera backends: written in the cloud, never run on a real
   Windows desktop.** They exist and compile for x64 and x86. The CI `windows` job
   drives them in-process: DirectShow in a real filter graph, MF through
   IMFActivate. It also round-trips regsvr32. Nothing has seen Zoom and the rest
   yet. What exists:
   - `framebuf/` (`lenny_framebuf`): the §7.3 shared-memory ring format
     (seqlock slots, heartbeat, state, bounds-checked `Reader`), CLSIDs. No deps.
   - `vcam/src/windows.rs` (`WindowsCamera`, what `open_best` returns on
     Windows): creates `Global\LennyFrames_v1` (falls back to `Local\` without
     `SeCreateGlobalPrivilege`), writes each I420 frame as NV12, and on Win11
     calls `MFCreateVirtualCamera` (Session lifetime, current user) if the MF
     class is registered. `is_real()` = DirectShow class registered.
   - `vcam/com/` (`lenny_vcam_com.dll`, one DLL for both COM classes):
     `filter.rs` DirectShow push source (1280×720 NV12/YUY2 30 fps,
     IAMStreamConfig, IKsPropertySet, graph-clock timestamps), `mf.rs` MF media
     source (SimpleMediaSource shape), `frames.rs` shared picture choice (live,
     last good ≤ 500 ms, placeholder), `server.rs` class factory + regsvr32
     registration ("Lenny (Classic)" on Win11, "Lenny" on Win10; MF "Lenny").
     Every COM entry and both streaming threads run in `catch_unwind`, and a
     panic switches to placeholder-only.
   **Done 2026-09-27:** both cameras live on Win11 with a real phone, broker service `lenny-broker` (ADR-0009),
   NSIS installer/uninstaller (`installer\build.ps1` → `target\Lenny-Setup-<ver>.exe`), static CRT
   (`.cargo/config.toml`), release desktop logs to `%APPDATA%\Lenny\lenny.log`. Lessons: Frame Server can't read
   DLLs under a user profile (MF `Start` → access denied); consumers keep the DLL loaded after enumeration; home
   Wi-Fi is usually "Public" (firewall rule is app-scoped, all profiles).
   Still to do:
   - OBS, Zoom, Teams, Discord in a real call; a 32-bit consumer; Win10; a true standard account. Friend's PC.
   - The DirectShow side is Win10's only camera and must work alone. The MF side
     is Win11 only. If both show up in MF-aware apps, revisit naming (R5).
   - One size (1280×720). Add 1080p once the desktop writes a 1080p canvas.
3. **Then:** build `lenny_desktop` on Windows (expected to work as-is: winit
   chrome, openh264 from source), retire the Flutter desktop +
   `plugins/windows_receiver` once the Rust app has the Windows camera
   (ADR). (Desktop builds on Windows and the installer exist as of 2026-09-27.)

Loose ends: design fonts not committed (drop OFL TTFs in
`desktop/assets/fonts`, see `theme.rs`); openh264 rejects frames over 1 MB
(check 4K keyframes); the Android encoder doesn't request a profile (Baseline
by default, which openh264 needs); `core/CMakeLists.txt` cargo wrapper never
built on Windows.

Open from the user's change list (checked against the code 2026-09-27; the
Rust desktop is the target, the Flutter desktop is not worth changing):
- Done 2026-09-28: no dotted page; QR / Find PCs first on both apps, Manual / USB ADB /
  USB tether folded behind one segmented control each (desktop USB ADB runs `adb reverse`,
  `desktop/src/adb.rs`); smaller preview and two card columns so a maximized desktop and a
  landscape phone don't scroll (checked on Honor X5c Plus, 1536x816 desktop).
- Done 2026-09-28 (second pass, tested on Nothing Phone (3a) over Wi-Fi + USB tether and Honor over
  USB tether): desktop title bar = status chip + phone name/battery pill + Disconnect (no connection card
  while streaming, no LIVE badge); preview top-left, stream card under a landscape preview / beside a
  portrait one (portrait runs to the window bottom), aspect eases on rotation; phone layout fades on
  rotation; sliders update the camera while dragging; Manual/USB tether show only their own IPs
  (adapter description on Windows, USB driver on Linux; VPN/VM adapters hidden); known-phones list
  removed from the desktop (still saved for trust); vcam status line only "active"; pan only offered
  on FREEFORM-cropping cameras (Nothing and Honor are CENTER_ONLY: zoom works, pan can't); focus
  Auto | Manual with exposure slider + lock always shown, tap-to-focus sets AF regions only;
  congestion control fixed (it cascaded to 1 Mbps in 1.5 s: now drops the whole backlog, one cut per
  second, +20%/2 s back). Lag the user saw was mostly 2.4 GHz Wi-Fi: 5 GHz / USB tether = ~30 ms.
  Tried and reverted: AE fps range [15,30] (choppy motion), hidden low-light +EV, face-priority AE.
- Pending: both virtual cameras now register as plain "Lenny" (was "Lenny (Classic)") but that
  needs a rebuilt installer (`installer\build.ps1`) + reinstall; not done yet. Windows still adds
  " (Windows Virtual Camera)" to the MF one in some apps. Discord mirrors its own self-view: not a bug.
- Pending: phone portrait on the Honor truncates button labels ("Scan …", "Find P…", "USB").
- Known devices: the desktop no longer lists known phones (2026-09-28, user: not needed;
  still saved for trust). Quick connect belongs on the phone (ADR-0001). The phone has no known-PCs list, only the last PC prefilled.
  Wanted: a list below the connection buttons, tap = connect, at least the last PC.
- Preview box: still follows the video's aspect (Task 6); the user asked for it smaller
  (done), not for a fixed 16:9 box.
- Lock screen streaming: foreground service exists, never tested (testing.md
  M2 row 9). Digital zoom fallback: not needed on Android (every Camera2
  device can crop via `SCALER_CROP_REGION`); revisit for iOS.

Free-forever check (2026-09-27; the user never wants to pay fees): all 409
Rust crates are permissive (MIT/Apache/BSD/Zlib/ISC/Unicode-3.0), Flutter and
Android deps too, NSIS is zlib (ADR-0008), GitHub Actions is free for public
repos. Watch:
- No LICENSE file: the public repo isn't legally open source until one is added.
- H.264 patents: openh264 built from source isn't covered by Cisco's royalty
  payment (only Cisco's prebuilt binary is). Via LA has a free tier (first
  100k units/year), and Windows' own MF decoder is licensed with the OS, so
  prefer MF decode on Windows; Linux can load Cisco's binary at runtime.
- Bundled `adb.exe`: platform-tools binaries come under the Android SDK
  licence, not plain Apache 2.0. Prefer the user's adb, or build it from AOSP.
- Google Play: one-time $25 developer fee when publishing the Android app.

Checks before any push: `cargo fmt --all --check`, `cargo clippy --workspace
--all-targets -- -D warnings` (CI uses the latest stable, whose lints are
stricter than older toolchains), `cargo test --workspace`,
`core/tools/abi_check.sh` (needs cbindgen + clang), and for app changes
`flutter analyze && flutter test` in `app/` plus
`./gradlew :android_camera:testDebugUnitTest` in `app/android`.

**Desktop build order: Linux first, Windows later, most of it shared.** The
Rust desktop receiver (egui or iced, over `winit`) is being built and tested
on Linux first, in a cloud sandbox with no Windows machine available. This
is not a Linux-only detour: `winit`-based custom window chrome (the
borderless window + hand-drawn title bar from `docs/design.md`) works the
same way on Windows and Linux, so that UI layer is expected to carry over to
Windows with little to no change. The one genuinely OS-specific piece is the
virtual camera backend, already isolated behind `IVirtualCamera`:
`v4l2loopback` on Linux now, DirectShow + `MFCreateVirtualCamera` on Windows
later. Because `v4l2loopback` is a kernel module, it likely can't be loaded
inside a sandboxed container at all — a "null" `IVirtualCamera` backend
(writes decoded frames to a file/log instead of a real device) exists
specifically so the rest of the pipeline (capture → encode → network →
decode) can be built and tested without kernel privileges. The real
`v4l2loopback` wiring and, later, the Windows backend both get implemented
and tested locally, using the null-backend-validated pipeline as the known-
good base to build on top of — port the *shape* of the Linux
`IVirtualCamera` implementation, not the syscalls themselves.

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
