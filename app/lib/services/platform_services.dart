import 'package:android_camera/android_camera.dart';
import 'package:windows_receiver/windows_receiver.dart';

import '../state/camera.dart';
import 'core_session.dart';

class PermissionDeniedException implements Exception {
  @override
  String toString() => 'Camera permission is needed to stream.';
}

/// Phone side. Owns the native pipeline; hands out the control-plane session.
class SenderService {
  Future<({CoreSession session, CameraCaps caps})> start(String host, int port) async {
    if (!await AndroidCamera.requestPermissions()) throw PermissionDeniedException();
    final r = await AndroidCamera.start(host: host, port: port);
    return (
      session: CoreSession(r.session),
      caps: CameraCaps(controls: r.controls, lenses: r.lenses, exposure: r.exposure),
    );
  }

  /// The phone's own camera buttons. Returns LENNY_ACK_*.
  Future<int> control(CameraCommand c) => AndroidCamera.control(c.cmd, value: c.value);

  Stream<CameraControls> get controls => AndroidCamera.controlState.map((s) => CameraControls(
        afMode: s.afMode,
        exposureEvMilli: s.exposureEvMilli,
        aeLock: s.aeLock,
        awbLock: s.awbLock,
        torch: s.torch,
        lens: s.lens,
        zoom100: s.zoom100,
      ));

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

  /// Tap on the preview, normalised to its 16:9 box. True if it hit the picture (a focus command went out).
  Future<bool> focusAt(double x, double y) => WindowsReceiver.focusAt(x, y);

  Future<double?> displayLatencyMs() => WindowsReceiver.displayLatencyMs();
}
