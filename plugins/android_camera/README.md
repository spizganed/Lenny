# android_camera

Lenny's Android sender pipeline: Camera2 capture (all lenses, including ones hidden from `cameraIdList`) into a
MediaCodec H.264 encoder, streamed by `lenny_core` (built from `/core` into `liblenny_core.so`), kept alive by a camera foreground service.
Dart only calls `start`/`stop` here and then talks to the same core session over FFI. Video never enters Dart.
