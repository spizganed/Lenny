# Testing

Automated:
- `core/`: `lenny_tests` (wire format, test vectors, full sessions over localhost TCP). CI runs it on MSVC, GCC,
  ASan/UBSan and TSan.
- `app/`: `flutter test`.
- `plugins/windows_receiver/windows/test/nv12_test.cpp`: preview converter (rotation + letterbox).

Tools:
- `core/build/lenny_probe [port] [seconds]`: headless receiver that auto-accepts phones and prints fps, bitrate,
  keyframes, RTT and latency once a second. Use it to test a sender without the desktop app, and for soak tests (M6).
- Emulator: the phone reaches the PC at `10.0.2.2`. The AVD's back camera should be `virtualscene`.

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
| 6 | Real phone over Wi-Fi | Same as 1–5, glass-to-glass < 150 ms | not yet run (phone busy) |
