# ADR-0011: Flutter desktop receiver removed

Status: accepted (2026-09-28). Follows [ADR-0007](0007-linux-desktop-first.md).

**Decision.** The Flutter desktop receiver (`app/windows`, `receiver_screen.dart`, the receiver state and services)
and the C++ `plugins/windows_receiver` are deleted. The Rust desktop app (`/desktop`) with the Rust virtual cameras
(`vcam/com`) replaces them on Windows and Linux; 1.0.0 shipped without them.

**Why.** Nothing used them any more, and keeping them building cost time on every Flutter and core change.

**What stays.** The Flutter app is the phone (sender) app only, until the Kotlin/Compose port. The C ABI keeps its
receiver functions: the Rust desktop and the tests use them. Git history has the old code.
