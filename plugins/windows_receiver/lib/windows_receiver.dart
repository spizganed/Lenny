import 'package:flutter/services.dart';

typedef ReceiverStart = ({int session, int port, int textureId});

/// Windows receiver pipeline. Only the service layer may use this (widgets never touch native code).
class WindowsReceiver {
  static const _channel = MethodChannel('lenny/windows_receiver');

  /// Listens for phones. `session` is the `lenny_session*` address for FFI; `textureId` feeds a `Texture` widget.
  static Future<ReceiverStart> start({int port = 47474}) async {
    final r = (await _channel.invokeMapMethod<String, Object?>('start', {'port': port}))!;
    return (session: r['session']! as int, port: r['port']! as int, textureId: r['textureId']! as int);
  }

  /// Tap on the preview at (x, y) normalised to its 16:9 box. The native side knows the letterbox and rotation.
  static Future<bool> focusAt(double x, double y) async =>
      await _channel.invokeMethod<bool>('focusAt', {'x': x, 'y': y}) ?? false;

  /// Capture -> shown in the preview, smoothed. Null until the clocks are synced.
  static Future<double?> displayLatencyMs() async {
    final v = await _channel.invokeMethod<double>('displayLatencyMs') ?? -1;
    return v < 0 ? null : v;
  }

  static Future<void> stop() => _channel.invokeMethod('stop');
}
