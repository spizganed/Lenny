# iOS sender (future)

Not built yet. Plan: Swift Flutter plugin with AVFoundation capture, VideoToolbox H.264 encode, and NWBrowser for
`_lenny._tcp` discovery, calling the same `lenny_core` C ABI. It speaks the same protocol. iOS stops camera
access in the background, so streaming needs the app in the foreground. See docs/architecture.md §11.
