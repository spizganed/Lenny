import '../core_bindings/lenny_bindings.dart';

/// What the phone's camera can do (from its CAPS). Same model on the phone and the desktop.
class CameraCaps {
  const CameraCaps({this.controls = 0, this.lenses = const [], this.exposure});

  final int controls; // LENNY_CAP_*
  final List<String> lenses; // index = lens id
  final ({int min, int max, int step})? exposure; // EV*1000

  bool has(int cap) => controls & cap != 0;
}

/// What the camera is currently doing (lenny_control_state).
class CameraControls {
  const CameraControls({
    this.afMode = 0,
    this.exposureEvMilli = 0,
    this.aeLock = false,
    this.awbLock = false,
    this.torch = false,
    this.lens = 0,
    this.zoom100 = 100,
    this.battery,
    this.charging = false,
  });

  final int afMode; // 0 continuous, 1 locked, 2 focusing
  final int exposureEvMilli;
  final bool aeLock, awbLock, torch;
  final int lens, zoom100;
  final int? battery; // phone battery percent, null if unknown
  final bool charging;

  bool get focusLocked => afMode == 1;

  /// Everything on Auto, i.e. what "Auto" resets to.
  bool get isAuto => afMode != 1 && exposureEvMilli == 0 && !aeLock && !awbLock;
}

/// A camera command, as sent to lenny_control / the phone plugin.
typedef CameraCommand = ({int cmd, int value});

abstract final class Commands {
  static CameraCommand torch(bool on) => (cmd: lenny_control_cmd.LENNY_CTL_TORCH.value, value: on ? 1 : 0);
  static CameraCommand focusLock(bool on) => (cmd: lenny_control_cmd.LENNY_CTL_FOCUS_LOCK.value, value: on ? 1 : 0);
  static CameraCommand exposureLock(bool on) =>
      (cmd: lenny_control_cmd.LENNY_CTL_EXPOSURE_LOCK.value, value: on ? 1 : 0);
  static CameraCommand exposure(int evMilli) => (cmd: lenny_control_cmd.LENNY_CTL_EXPOSURE_COMP.value, value: evMilli);
  static CameraCommand lens(int id) => (cmd: lenny_control_cmd.LENNY_CTL_SELECT_LENS.value, value: id);
  static final CameraCommand auto = (cmd: lenny_control_cmd.LENNY_CTL_RESET_AUTO.value, value: 0);
}
