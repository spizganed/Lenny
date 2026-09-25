# Lenny

Use your phone as a webcam. The phone app streams its camera to the Lenny desktop app over Wi-Fi, and
the desktop app is where you pick the camera, resolution, frame rate, focus and exposure.

<p align="center">
  <img src="docs/screenshots/desktop.png" alt="Lenny Desktop streaming from a phone" width="820">
</p>

<p align="center">
  <img src="docs/screenshots/phone-portrait.png" alt="Lenny on the phone, portrait" height="420">
  &nbsp;
  <img src="docs/screenshots/phone-landscape.png" alt="Lenny on the phone, landscape" height="420">
</p>

## Status

Early and in progress. What works today, on **Android → Windows**:

- Live H.264 stream over Wi-Fi, around 100 ms end to end on a home network.
- Pairing: scan the QR code on the PC, tap *Find PCs*, or type the address. Phones you allowed once reconnect without asking.
- Remote camera control from the PC: lens (0.6× / 1× / 2× / front), tap to focus, focus lock, exposure and exposure lock, torch.
- Aspect, resolution (720p / 1080p / 4K) and frame rate, switched live.
- Phone battery level on the PC, Connect / Disconnect on both sides.

Not there yet:

- **Virtual camera** for Discord, Teams, Zoom, browsers (the main goal; next milestone).
- **OBS plugin.**
- iOS phone app and Linux desktop app (designed for, not built). macOS is out of scope.
- USB connection, encryption.

## Try it

Grab the Android APK and the Windows zip from the [Releases](../../releases) page, when there is one. Otherwise build it:

1. Install the phone app and open Lenny Desktop on the PC. Both must be on the same Wi-Fi.
2. On the phone, tap **Scan QR** and point it at the code on the PC (or **Find PCs**).
3. The first time, allow the phone on the PC.

Windows may ask to let Lenny through the firewall: allow it on private networks, or the phone can't find the PC.

## Build

Needs Flutter (stable), Android Studio (SDK + NDK) and, for Windows, Visual Studio 2022 with the C++ workload.

```sh
cd app
flutter build apk --release       # app/build/app/outputs/flutter-apk/app-release.apk
flutter build windows --release   # app/build/windows/x64/runner/Release/ (ship the whole folder)
```

Core library tests (C++):

```sh
cmake -S core -B core/build -G Ninja && cmake --build core/build && core/build/lenny_tests
```

## How it's built

| Part | What |
| --- | --- |
| `core/` | C++ library shared by every platform: protocol, sessions, pairing, clock sync. C ABI. |
| `app/` | Flutter app, one codebase: phone UI on Android, desktop UI on Windows. |
| `plugins/android_camera` | Camera2 capture + MediaCodec H.264 encoder (Kotlin + JNI). |
| `plugins/windows_receiver` | Media Foundation decoder + preview texture (C++). |

More: [architecture](docs/architecture.md), [wire protocol](docs/protocol.md), [design system](docs/design.md), [testing](docs/testing.md).
