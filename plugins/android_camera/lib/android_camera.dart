import 'package:flutter/services.dart';

/// Android sender pipeline. Only the service layer may use this (widgets never touch native code).
class AndroidCamera {
  static const _channel = MethodChannel('lenny/android_camera');

  /// Asks for camera (+ notification) permission. True if the camera is allowed.
  static Future<bool> requestPermissions() async =>
      await _channel.invokeMethod<bool>('requestPermissions') ?? false;

  /// Starts camera + encoder + core session and connects. Returns the `lenny_session*` address for FFI.
  static Future<int> start({required String host, required int port, Uint8List? token}) async =>
      (await _channel.invokeMethod<int>('start', {'host': host, 'port': port, 'token': token}))!;

  static Future<void> stop() => _channel.invokeMethod('stop');
}
