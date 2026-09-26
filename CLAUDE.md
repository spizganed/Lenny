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

- `lenny-prompt.md` at the repo root is a historical one-time kickoff prompt,
  not standing instructions — this file (CLAUDE.md) replaced it. Safe to
  delete once its content is confirmed covered here and in `docs/`.
- One ADR per real decision in `docs/adr/`. Superseded ADRs stay in the repo
  (marked superseded), never deleted — they're the record of why we changed
  course.
