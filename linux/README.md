# Linux receiver (future)

Not built yet. Plan: decode with VA-API (FFmpeg fallback) and write to a v4l2loopback device (`/dev/videoN`,
installed via DKMS). Avahi for discovery. With Secure Boot on, the module has to be MOK-signed, so document that in setup.
A PipeWire camera backend is a later option. See docs/architecture.md §11.
