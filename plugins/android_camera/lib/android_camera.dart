import 'dart:async';

import 'package:flutter/services.dart';

/// Camera control state as the phone applies it (mirrors lenny_control_state).
class CameraControlState {
  const CameraControlState({
    this.afMode = 0,
    this.focusLocked = false,
    this.exposureEvMilli = 0,
    this.aeLock = false,
    this.awbLock = false,
    this.torch = false,
    this.lens = 0,
    this.zoom100 = 100,
  });

  factory CameraControlState.fromMap(Map<Object?, Object?> m) => CameraControlState(
        afMode: m['afMode'] as int? ?? 0,
        focusLocked: m['focusLocked'] as bool? ?? false,
        exposureEvMilli: m['exposureEvMilli'] as int? ?? 0,
        aeLock: m['aeLock'] as bool? ?? false,
        awbLock: m['awbLock'] as bool? ?? false,
        torch: m['torch'] as bool? ?? false,
        lens: m['lens'] as int? ?? 0,
        zoom100: m['zoom100'] as int? ?? 100,
      );

  final int afMode; // 0 continuous, 1 locked, 2 focusing
  final bool focusLocked;
  final int exposureEvMilli;
  final bool aeLock, awbLock, torch;
  final int lens, zoom100;
}

class SenderStart {
  const SenderStart({required this.session, required this.controls, required this.lenses, this.exposure});

  /// `lenny_session*` address for FFI.
  final int session;

  /// LENNY_CAP_* bits this phone's cameras support.
  final int controls;
  final List<String> lenses;

  /// Exposure compensation range in EV*1000, or null if the camera has none.
  final ({int min, int max, int step})? exposure;
}

/// Android sender pipeline. Only the service layer may use this (widgets never touch native code).
class AndroidCamera {
  static const _channel = MethodChannel('lenny/android_camera');
  static final _state = StreamController<CameraControlState>.broadcast();
  static bool _listening = false;

  /// Camera control changes, whoever made them (phone UI or the desktop).
  static Stream<CameraControlState> get controlState {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'state') _state.add(CameraControlState.fromMap(call.arguments as Map<Object?, Object?>));
      });
    }
    return _state.stream;
  }

  /// Applies a LENNY_CTL_* command from the phone's own UI. Returns LENNY_ACK_*.
  static Future<int> control(int cmd, {int x = 0, int y = 0, int value = 0}) async =>
      await _channel.invokeMethod<int>('control', {'cmd': cmd, 'x': x, 'y': y, 'value': value}) ?? 2;

  /// Asks for camera (+ notification) permission. True if the camera is allowed.
  static Future<bool> requestPermissions() async =>
      await _channel.invokeMethod<bool>('requestPermissions') ?? false;

  /// Starts camera + encoder + core session and connects.
  static Future<SenderStart> start({required String host, required int port, Uint8List? token}) async {
    final r = (await _channel.invokeMapMethod<String, Object?>('start', {'host': host, 'port': port, 'token': token}))!;
    final exposure = (r['exposure'] as List<Object?>).cast<int>();
    return SenderStart(
      session: r['session']! as int,
      controls: r['controls']! as int,
      lenses: (r['lenses'] as List<Object?>).cast<String>(),
      exposure: exposure.length == 3 ? (min: exposure[0], max: exposure[1], step: exposure[2]) : null,
    );
  }

  static Future<void> stop() => _channel.invokeMethod('stop');
}
