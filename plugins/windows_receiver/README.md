# windows_receiver

Lenny Desktop's receive path on Windows: `lenny_core` session (built from `/core` into `lenny_core.dll`) ->
Media Foundation H.264 decode (NV12) -> preview texture. Dart only calls `start`/`stop` here and then talks to the same
core session over FFI. Video never enters Dart. The virtual camera (M4/M5) reads the same decoded frames.
