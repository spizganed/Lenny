# ADR-0009: Broker service for the Global\ frame buffer

Status: accepted (2026-09-27).

**Problem.** The MF virtual camera's media source runs in Frame Server (session 0, LOCAL SERVICE), which only sees
`Global\` kernel objects. Creating a `Global\` object needs `SeCreateGlobalPrivilege`, which a normal (unelevated) app
launch doesn't have, even for an admin account. Without it the app fell back to `Local\`: DirectShow worked, the MF
camera didn't. Measured on Windows 11: elevated launch → `Global\` + MF camera; Start menu launch → `Local\`, MF off.

**Decision.** A tiny Windows service, `LennyBroker` (`lenny-broker.exe`, `vcam/src/bin/lenny-broker.rs`), runs as
LocalSystem, starts automatically, creates `Global\LennyFrames_v1` and `Global\LennyFrameReady_v1` with the §7.3 DACL,
and holds them until it stops. Opening an existing `Global\` object needs no privilege, only the DACL (interactive users
read/write), so the app opens the broker's objects first, then tries creating `Global\` itself (elevated), then
`Local\`. The installer creates, starts, stops and deletes the service (ADR-0008).

**Alternatives rejected.**
- Frame Server creates the objects (its LOCAL SERVICE token has the privilege): no service to install, but the MF
  source only loads after the app has registered the camera, so the app would start on `Local\` and switch over
  mid-stream, and the objects' lifetime would follow Frame Server loading and unloading the source.
- Run the app elevated (manifest `requireAdministrator`): a UAC prompt every launch, and a network-facing app running
  as admin.
- Grant `SeCreateGlobalPrivilege` to Users: a system-wide security change for one app.

**Trade-offs accepted.** One more always-running process (a few hundred KB, idle; the ~9 MB mapping is pagefile-backed
and only touched pages cost memory). Auto start rather than on demand, because a normal user can't start a service
unless its DACL is changed, and auto start keeps that simple.
