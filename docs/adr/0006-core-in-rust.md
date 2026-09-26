# ADR-0006: Core in Rust, C ABI unchanged

Status: accepted (supersedes [ADR-0003](0003-native-code-in-cpp.md) for the core; Windows-side native code is
decided separately in Phase B, see CLAUDE.md)

**Context.** The core (protocol, session state machine, transport, pairing, clock sync) was C++20 behind a C ABI
(`core/include/lenny/lenny.h`). Phase B replaces Flutter with native apps per platform, and the Windows desktop app
will be Rust (egui/iced), linking the core directly. The core is also the most security- and crash-sensitive code we
own: it parses bytes from the network on every platform.

**Decision.** Port the core to Rust (`/core`, crate `lenny_core`), keeping the C ABI byte for byte:
- Crate types `cdylib` (liblenny_core.so for Android JNI + Dart FFI), `staticlib` (C/C++ linking) and `rlib` (Rust
  apps link the crate directly, no FFI).
- `include/lenny/lenny.h` stays the published, documented header. `core/tools/abi_check.sh` regenerates a header with
  cbindgen and requires identical struct layouts, constant values and function types; CI runs it. The original C++
  end-to-end tests (`core/tests/c_abi/`) still build against lenny.h and pass against the Rust library.
- Wire protocol unchanged; `protocol/vectors/` encode and decode identically.
- Android builds the crate with cargo-ndk from Gradle; the C++ JNI shim links it.

**Why.**
- Memory safety where it matters: every byte from the network goes through `wire` and `session`. Safe Rust removes
  the out-of-bounds / use-after-free class that the C++ code guarded by hand, and data races on the session's shared
  state are compile errors instead of TSan findings.
- One language with the Phase B desktop app: Rust calling Rust, no marshalling layer.
- std + socket2 cover Winsock and BSD sockets, so the core has no OS `#if` left except one errno check.

**Cost.**
- A Rust toolchain (+ Android targets and cargo-ndk) in every build. The Windows CMake build now shells out to cargo
  (`core/CMakeLists.txt`) and hasn't been built on Windows yet.
- `unsafe` is concentrated in `c_api.rs` (pointer arguments) and the C callback calls in `session.rs`.

**Intentional deviations from the C++ core** (none visible on the wire or through the ABI):
- `lenny_now_us()` epoch: process-relative monotonic clock (shifted so it's never near 0) instead of
  `steady_clock`'s. Only differences of it are ever used (pts conversion, clock sync), so callers are unaffected.
- Connect and accept wait in 10 ms sleep slices instead of `poll()`/`select()` (keeps transport free of OS code);
  up to 10 ms extra connect/accept latency.
- `recv` timeouts use `SO_RCVTIMEO` (minimum 1 ms) instead of `poll()`.
- Strings from the wire are kept as raw bytes; callbacks get them up to the first NUL, as the C++ `c_str()` did.
- ThreadSanitizer CI job dropped (safe Rust makes data races compile errors; the C++ ABI test runs under ASan/UBSan).
