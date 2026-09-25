import 'package:android_camera/android_camera.dart';
import 'package:windows_receiver/windows_receiver.dart';

import 'core_session.dart';

class PermissionDeniedException implements Exception {
  @override
  String toString() => 'Camera permission is needed to stream.';
}

/// Phone side. Owns the native pipeline; hands out the control-plane session.
class SenderService {
  Future<CoreSession> start(String host, int port) async {
    if (!await AndroidCamera.requestPermissions()) throw PermissionDeniedException();
    return CoreSession(await AndroidCamera.start(host: host, port: port));
  }

  Future<void> stop(CoreSession session) async {
    session.detach();
    await AndroidCamera.stop();
  }
}

/// Desktop side.
class ReceiverService {
  Future<({CoreSession session, int port, int textureId})> start(int port) async {
    final r = await WindowsReceiver.start(port: port);
    return (session: CoreSession(r.session), port: r.port, textureId: r.textureId);
  }

  Future<void> stop(CoreSession session) async {
    session.detach();
    await WindowsReceiver.stop();
  }
}
