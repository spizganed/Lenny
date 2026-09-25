You are a senior engineer helping me build a cross-platform "phone as webcam" system.
Build it in phases. Phase 1 targets Android (sender) + Windows 10/11 (receiver),
but the architecture MUST be designed so iOS (sender) and macOS/Linux (receivers)
can be added later as thin platform layers, without changing the shared core or protocol.

## Terminology
- Sender = phone app (captures, encodes, streams). Android first, iOS later.
- Receiver = desktop app (receives, decodes, feeds a virtual camera). Windows first, macOS/Linux later.
- Virtual camera = OS-level camera device that Zoom, Teams, Discord, browsers, OBS etc. see as a real webcam.

## Brand
- The apps and mascot are both named "Lenny" (Lenny for Android/iOS, Lenny
  Desktop for Windows/macOS/Linux). Keep the name in ONE constants file.
- No mascot artwork or animation work yet — that's being designed separately
  and will be dropped in later as sprite assets. Don't invent placeholder
  mascot art; leave a clearly marked spot for it in the home/connection screen.

## Architecture rules (the "universal" part)
1. Shared core library in C++20 with CMake, exposing a stable C ABI so it can be
   called from Kotlin (JNI/NDK), Swift, and native desktop code. No platform
   headers in the core. Core contains:
   - Wire protocol (framing, versioning, message types, serialization)
   - Session logic (handshake, capability negotiation, keepalive, reconnect)
   - Transport interface (ITransport) with a TCP implementation
   - Jitter/latency handling and frame timestamping
   - Frame buffer / shared-memory ring buffer format definition
2. Platform-specific code lives in separate modules behind interfaces:
   - ICameraSource (Android CameraX, iOS AVFoundation later)
   - IEncoder / IDecoder (Android MediaCodec, Windows Media Foundation,
     VideoToolbox later, VA-API/FFmpeg later)
   - IVirtualCamera (Windows DirectShow + MF, macOS CMIO extension later,
     Linux v4l2loopback later)
   - IDiscovery (mDNS/DNS-SD via Android NsdManager, Windows DNS-SD API, Bonjour, Avahi)
3. The protocol is documented in /docs/protocol.md and versioned from day one.
   Every message has a type + length + version. Unknown messages are ignored,
   not fatal. Capability negotiation covers codecs, resolutions, fps, and controls.
4. Repo layout:
   /app       Flutter app (UI, state management, platform channels)
   /core      C++ shared library + tests
   /plugins   native platform plugins (android_camera, windows_vcam, ...)
   /protocol  protocol spec + test vectors
   /ios /macos /linux   placeholders with README describing future work
   /docs      architecture.md, protocol.md, decisions (ADR) folder

## Tech stack
- UI for ALL apps (Android, Windows now; iOS, macOS, Linux later): Flutter
  (Dart), one shared UI codebase in /app.
- Shared core: C++20 with a C ABI, called from Flutter via dart:ffi (generate
  bindings with ffigen). Same core compiles for all 5 platforms.
- Native code ONLY where the OS requires it, as Flutter plugins or separate
  modules:
  - Android: Kotlin plugin for CameraX/Camera2Interop + MediaCodec encoding
    (the Flutter camera package is NOT sufficient; don't use it).
  - Windows: C++ for Media Foundation decode, DirectShow filter, MF virtual camera.
  - Future: Swift (iOS capture, macOS CMIO extension), C++ (Linux v4l2loopback).
- Video frames must never pass through Dart. Dart only handles UI, settings,
  and control commands; the video path stays native/C++ end to end.

## Android sender (phase 1)
- Kotlin, CameraX, with Camera2Interop for low-level settings.
- Continuous autofocus: CONTROL_AF_MODE_CONTINUOUS_VIDEO; tap-to-focus via
  FocusMeteringAction, triggered remotely through the control channel.
- Auto exposure/ISO: CONTROL_AE_MODE_ON (automatic ISO + shutter speed). Lock
  the AE target FPS range (e.g. [30,30]) so framerate doesn't drop in low
  light. Anti-banding AUTO for indoor lighting.
- Encoding: MediaCodec hardware H.264 encoder fed by a CameraX Preview
  surface. Low latency: KEY_LOW_LATENCY on API 30+, no B-frames, short GOP,
  on-demand sync frame on client (re)connect.
- Handle device rotation; send orientation metadata so the receiver outputs a
  stable landscape image.
- Foreground service so streaming survives screen-off.

## Transports (phase 1)
All transports carry the same TCP protocol:
- Wi-Fi: TCP, with mDNS auto-discovery (Android NsdManager) plus manual IP/port entry.
- USB via ADB: receiver bundles adb and runs adb forward/reverse automatically
  (requires USB debugging; show clear setup instructions in the UI).
- USB via USB tethering (RNDIS): no debugging needed, phone becomes a network
  adapter, same TCP code path.
Do NOT use Android Open Accessory (it requires WinUSB driver installation on Windows).

## Windows receiver (phase 1, must support Windows 10 AND 11)
- Receiver app (propose C++ or C#/.NET UI calling the core via C ABI, and
  justify the choice) — UI itself is Flutter per the tech stack above.
- Hardware H.264 decode via Media Foundation, NV12 output.
- Decoded frames written to a shared-memory ring buffer + events.
  IMPORTANT: use Global\ names and an ACL readable by the Local Service
  account, because the MF virtual camera runs inside the Windows Camera Frame
  Server service, not the user session.
- Virtual camera backends, both reading from the same shared memory:
  a) DirectShow source filter (Windows 10 + 11 baseline), user-mode COM DLL,
     built as BOTH x86 and x64, registered via installer.
  b) Media Foundation virtual camera via MFCreateVirtualCamera (Windows 11
     only, registered at runtime when available) for MF-only apps like the
     built-in Camera app.
- Advertise fixed formats (1280x720, 1920x1080 at 30fps; NV12 + YUY2) and
  scale/letterbox incoming frames to whatever format the consuming app selects.
- When no phone is connected, output a placeholder frame instead of black/frozen video.
- Installer (WiX or MSIX, justify choice) that registers/unregisters cleanly.
- Reference implementation to study: OBS Studio's virtual camera (GPL
  licensed — learn from it, don't copy code unless we accept GPL).

## Future phases (design for now, don't build yet)
- iOS sender: AVFoundation + VideoToolbox, same protocol.
- macOS receiver: CoreMediaIO Camera Extension (system extension, macOS
  12.3+), NOT legacy DAL plugins. Requires signing, entitlements, notarization.
- Linux receiver: v4l2loopback (via DKMS) writing to /dev/videoN; keep a
  PipeWire camera backend as a future option. Note Secure Boot module signing.

## Visual style — "sticker" style, dark mode
Reference for shape/shadow language only (do NOT use their mascot, characters,
or content): play.mukiz.com.

- Every interactive surface (button, card, input, chip) has:
  a) a flat solid fill color — no gradients
  b) a solid outline, ~3px, using a theme color (e.g. light lavender-gray
     `#b9b5cc`) so it reads against the dark background
  c) a hard, NON-blurred offset drop shadow in solid near-black (e.g.
     `#0c0c18`), offset ~4-6px down-right
- On press: the shadow offset shrinks toward 0 and the element shifts
  down-right to meet it, simulating a physical push. On release: springs back.
  Use spring physics, not linear easing (flutter_animate is fine). Keep these
  animations short (150-400ms). Respect the OS "reduce motion" setting by
  falling back to simple fades.
- FLUTTER IMPLEMENTATION NOTE: do not use Flutter's default `BoxShadow`
  as-is — its default blur reads as a soft Material shadow, which breaks this
  style. Every sticker-style shadow must be built with `blurRadius: 0` and a
  fixed `Offset` (no spread blur at all), and border + shadow must be built as
  one shared reusable style (e.g. a `StickerDecoration` widget/theme extension)
  applied consistently, not re-implemented ad hoc per screen.
- Page background: deep navy/charcoal (`#14162b`), with a very faint grid or
  dot pattern overlay (low opacity, decorative only, never distracting).
- Bright, saturated accent colors per function (primary action stays bright
  yellow, danger stays a warm red/pink, etc.), all defined in one theme file.
- Rounded corners: chunky but not pill-shaped for cards/buttons (~16-20px
  radius); true pills only for status chips/toggles.
- Keep this functional and consistent across every screen (phone and
  desktop), not one-off flourishes. No filler decoration: every card/button
  uses the same outline+shadow+press language, spacing is consistent, nothing
  is added purely for decoration.

## UI requirements
- Material 3 base, but skinned entirely with the sticker style above (dark
  background is the default and primary theme; a light variant is a stretch
  goal, not required day one).
- Strict separation of UI and logic (use Riverpod or Bloc; justify the
  choice). Widgets never talk to native code directly, only through a service
  layer.
- Phone (sender) screens: full-screen camera preview, connection control (see
  below), quick controls (switch lens, torch, focus lock, exposure slider),
  settings (resolution, fps, bitrate, codec).
- Desktop (receiver) screens: device list with auto-discovered phones,
  connection control (see below), live preview, stats (fps, bitrate,
  latency), virtual camera on/off status, remote camera controls (tap preview
  to focus), settings, first-run setup guide (USB debugging / tethering help).
- Responsive layouts that work on phone, tablet, and desktop window sizes.
- Clear error states (e.g. "Phone disconnected, reconnecting..."), never
  silent failures.
- Start with a neat, functional UI; polish comes later. Put reusable
  components (buttons, cards, status chips, the connection control) in
  /app/lib/ui/components.

## Connect/disconnect control (combo button + drawer)
Single pill-shaped control, always visible, replacing a plain "Connect" button:
- Collapsed: left zone shows connection status (dot + label) and is the main
  tap target (tap to disconnect when connected). Right zone is a separate
  chevron tap target that expands/collapses a drawer — it does NOT
  connect/disconnect by itself.
- Expanded (only reachable when disconnected): the same pill grows downward
  into an attached panel (not a separate floating popup) containing two
  stacked sections:
  - Wi-Fi: IP address field, port field, Connect button, the auto-discovered
    device list, AND a QR code quick-connect (see below).
  - USB: detected device dropdown (ADB / tethering), Connect button.
- Chevron rotates 180 degrees on expand; tapping it again collapses without
  disconnecting. A successful connection auto-collapses the drawer.
- Expand/collapse uses a smooth height/opacity transition (not springy);
  press/hover feedback on buttons inside the drawer still follows the
  standard sticker-style press animation.
- Build as one reusable component (e.g. `ConnectionControl`) shared between
  the phone and desktop apps, since both need the same Wi-Fi/USB choice.

## QR code quick-connect (desktop -> phone)
Goal: skip typing an IP/port by hand. The desktop (receiver) already knows
its own address, so it generates a QR code; the phone (sender) scans it and
connects immediately.
- Desktop: in the Wi-Fi section of the ConnectionControl drawer, render a QR
  code encoding a small JSON/URI payload: local IP, port, protocol version,
  and a short-lived pairing token (see security note below). Regenerate it
  whenever the IP changes (network switch, VPN toggle, etc.) or the token
  expires, and show a "refresh" action if it goes stale while the drawer is
  open.
- Phone: add a "Scan to connect" action alongside the manual IP/port entry
  (reuse the OS camera, this is a one-off scan, not the streaming pipeline).
  On successful scan, parse the payload, prefill/auto-connect over Wi-Fi, and
  fall back to manual entry with a clear error if the QR is invalid, expired,
  or unreachable (e.g. phone and desktop are on different subnets/VLANs).
- Security: don't encode a permanent secret in the QR code. Use a pairing
  token that's short-lived (e.g. regenerated every 60-120s or on each drawer
  open) and single-use, so a photo of an old QR code can't be replayed later
  to connect without permission. The underlying TCP session still goes
  through the normal handshake/capability negotiation in the core protocol;
  the QR code only replaces typing the address, it isn't a new trust
  boundary on its own.
- UI: the QR code sits in the sticker-style visual language like everything
  else (outlined card, flat background so the code stays scannable — do NOT
  put the hard-shadow/outline treatment on the QR image itself, only on the
  card containing it, since a decorative border too close to the QR's quiet
  zone can break scanning).
- Add a corresponding message type to /docs/protocol.md for the pairing
  handshake (token exchange -> normal capability negotiation), so this isn't
  a special-cased side channel.

## Quality bar: stability, compatibility, and "just works" defaults
The competitive gap in this space is polish, not features — DroidCam/Iriun/
VCamdroid all get a phone image onto a PC, but lose points on crashes from
touching the phone mid-call, no real camera controls, manual IP entry only,
and dated UI. Close that gap deliberately:

- **Default mode is Auto, always.** On first run and on every reconnect, the
  phone sends autofocus (continuous), auto exposure/ISO, and auto white
  balance as the default state — the user should never have to touch a
  setting to get a good, correctly focused, correctly exposed image. Manual
  controls (focus lock, exposure compensation, WB lock) are opt-in overlays
  on top of auto, not a mode you must configure first.
- **Never crash the desktop app.** Every native boundary (DirectShow filter,
  MF virtual camera, shared-memory access, decoder) must fail safely: on any
  native-side error, log it, show a "Lenny lost the signal" error state in
  the UI, and keep the virtual camera device alive showing the placeholder
  frame — never let a native crash take down Zoom/Teams/Discord's whole
  process along with it. This is the single most important reliability
  requirement: a crash inside a DirectShow filter running inside another
  app's process is worse than any other kind of bug in this project.
- **Survive real-world phone events without dropping the call:** incoming
  phone calls, notifications, screen lock/unlock, app switching, rotation,
  and Wi-Fi/USB hot-swap must not kill the stream. Reconnect automatically
  and resume within a couple of seconds; show "reconnecting" in the UI
  (per the error-state requirement above), never a frozen or black frame
  with no explanation.
- **Compatibility matrix to explicitly test against, not just "it worked
  once":** Windows 10 and 11 (both DirectShow and, where applicable, MF
  paths), at minimum Zoom, Discord, Microsoft Teams, and Chrome/Edge
  (getUserMedia) as consuming apps, plus OBS as a capture-card-style
  consumer. Track this as a real checklist in /docs, updated per milestone,
  not assumed from one manual test.
- **Quick install has a real bar:** Android app install to first successful
  virtual-camera frame in Zoom, from a clean machine, should be achievable
  in well under two minutes without the user reading documentation — QR
  quick-connect is the mechanism, but also means: no manual driver
  installation step exposed to the user (the DirectShow/MF registration
  happens silently inside the installer), no confusing intermediate account
  or pairing service, no "restart your computer" step if avoidable.
- **Testing requirements per milestone:** in addition to unit tests on the
  core, each milestone that touches native code needs a manual smoke-test
  checklist (documented in /docs/testing.md) covering the failure modes
  above, and M6 explicitly includes a stability pass: repeated
  connect/disconnect cycles, phone sleep/wake during streaming, and
  long-duration (1hr+) soak tests before considering a phase "done".

## Milestones
M1: Protocol spec + core library with tests (loopback test sender->receiver on one PC).
M2: Android streams H.264 over Wi-Fi; Windows receiver shows it in a preview window.
M3: Latency tuning (target < 150 ms glass-to-glass on LAN) + control channel (focus, lens, torch).
M4: DirectShow virtual camera working in Zoom, Teams, Discord, Chrome on Win10 and Win11.
M5: MF virtual camera on Win11 + USB (ADB and tethering) transports.
M6: Installer, reconnect robustness, placeholder frames, settings UI polish, sticker-style visual pass.

## How to work
- Start by writing /docs/architecture.md and /docs/protocol.md, then stop and
  let me review before writing implementation code.
- For each milestone: explain the plan, list risks, then implement with tests.
- Keep platform code out of /core. If something tempts you to break that
  rule, flag it and propose an interface instead.
- Prefer clarity and robustness over cleverness; comment non-obvious OS quirks.
