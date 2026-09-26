# ADR-0003: Windows native code in C++, no C#/.NET

Status: superseded by [ADR-0006](0006-core-in-rust.md) (core in Rust). The reasoning below about keeping
C#/.NET out of the DirectShow filter still holds for Phase B's Windows work.

The prompt asks: receiver in C++ or C#/.NET calling the core via C ABI? The UI is Flutter either way, so the question is only
what the native Windows parts are written in.

**Decision.** C++ (C++20, MSVC), as Flutter Windows plugins + standalone COM DLLs.

**Why.**
- DirectShow, Media Foundation and `MFCreateVirtualCamera` are native COM. C# would wrap all of it through interop.
- The DirectShow filter runs inside Zoom/Teams/Chrome. Injecting a CLR into those processes is unacceptable for
  stability and load time. That part has to be native no matter what, and one language beats two.
- The core is C++, so it links directly with no marshalling, and there's one debugger and one build (CMake).
- Flutter's Windows embedding is C++ already.

**Cost.** Manual COM refcounting. Mitigated with `wil`/`winrt::com_ptr` (MIT, header-only).
