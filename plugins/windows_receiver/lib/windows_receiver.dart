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

  static Future<void> stop() => _channel.invokeMethod('stop');
}
