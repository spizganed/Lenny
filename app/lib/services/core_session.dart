import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../core_bindings/lenny_bindings.dart';
import '../state/camera.dart';

/// The one lenny_core library in this process. The native plugins load the very same file, so a session created
/// natively can be driven from here by its address.
final LennyBindings core =
    LennyBindings(DynamicLibrary.open(Platform.isAndroid ? 'liblenny_core.so' : 'lenny_core.dll'));

/// Mirrors lenny_state.
enum LinkState { idle, connecting, handshake, awaitingApproval, streaming, reconnecting, closed }

class CoreEvent {
  const CoreEvent(this.type, this.a, this.b);
  final lenny_event type;
  final int a, b;
}

/// One resolution + frame rate the phone offers (CAPS mode).
typedef StreamMode = ({int width, int height, int fps});

class PeerInfo {
  const PeerInfo(this.deviceId, this.name, this.platform, this.caps, this.modes);
  final String deviceId; // hex, stable per phone install
  final String name;
  final int platform;
  final CameraCaps caps; // receiver: the phone's camera, from its CAPS
  final List<StreamMode> modes; // receiver: what the phone can stream
}

class StreamInfo {
  const StreamInfo(this.width, this.height, this.fps, this.bitrateKbps);
  final int width, height;
  final double fps;
  final int bitrateKbps;
}

class CoreStats {
  const CoreStats({
    required this.rttUs,
    required this.frames,
    required this.bytes,
    required this.reconnects,
    required this.latencyUs,
  });
  final int rttUs, frames, bytes, reconnects;
  final int latencyUs; // receiver: capture -> received; -1 unknown
}

/// Control-plane view of a native session: events, status getters, approve. Video never passes through here.
class CoreSession {
  CoreSession(int address) : _ptr = Pointer<lenny_session>.fromAddress(address) {
    _listener = NativeCallable<Void Function(Pointer<Void>, Int32, Int32, Int32)>.listener(_onEvent);
    core.lenny_session_set_event_listener(_ptr, _listener.nativeFunction, nullptr);
  }

  final Pointer<lenny_session> _ptr;
  late final NativeCallable<Void Function(Pointer<Void>, Int32, Int32, Int32)> _listener;
  final _events = StreamController<CoreEvent>.broadcast();
  bool _detached = false;

  /// Events from the moment this object was created. The session may have moved on before that (it starts
  /// natively), so read [state] once after subscribing.
  Stream<CoreEvent> get events => _events.stream;

  void _onEvent(Pointer<Void> _, int type, int a, int b) {
    // Unknown event numbers (a newer core) are skipped, never fatal.
    final kind = lenny_event.values.where((e) => e.value == type).firstOrNull;
    if (kind != null && !_events.isClosed) _events.add(CoreEvent(kind, a, b));
  }

  LinkState get state => LinkState.values[core.lenny_session_state(_ptr)];

  PeerInfo? peer() => using((arena) {
        final p = arena<lenny_peer_info>();
        if (core.lenny_session_peer(_ptr, p) != LENNY_OK) return null;
        final r = p.ref;
        final lenses = List.filled(r.lens_count, '');
        for (var i = 0; i < r.lens_count; i++) {
          if (r.lens_ids[i] < lenses.length) lenses[r.lens_ids[i]] = _cString(r.lens_labels[i], 32);
        }
        final hasExposure = r.exposure_step_milli != 0;
        final id = [for (var i = 0; i < LENNY_DEVICE_ID_SIZE; i++) r.device_id[i].toRadixString(16).padLeft(2, '0')];
        final modes = <StreamMode>[
          for (var i = 0; i < r.mode_count; i++)
            if (r.modes[i].fps_den != 0)
              (width: r.modes[i].width, height: r.modes[i].height, fps: r.modes[i].fps_num ~/ r.modes[i].fps_den),
        ];
        return PeerInfo(
          id.join(),
          _cString(r.name, 64),
          r.platform,
          CameraCaps(
            controls: r.controls,
            lenses: lenses,
            exposure: hasExposure ? (min: r.exposure_min, max: r.exposure_max, step: r.exposure_step_milli) : null,
          ),
          modes,
        );
      });

  /// Receiver: the phone's current camera state (LENNY_EVENT_CONTROL_STATE).
  CameraControls? controlState() => using((arena) {
        final c = arena<lenny_control_state>();
        if (core.lenny_session_control_state(_ptr, c) != LENNY_OK) return null;
        final r = c.ref;
        return CameraControls(
          afMode: r.af_mode,
          exposureEvMilli: r.exposure_comp,
          aeLock: r.exposure_lock != 0,
          awbLock: r.wb_lock != 0,
          torch: r.torch != 0,
          lens: r.lens_id,
          zoom100: r.zoom,
          battery: r.battery > 100 ? null : r.battery,
          charging: r.charging != 0,
        );
      });

  /// Receiver: send a camera control to the phone. Returns LENNY_OK or an error code.
  int sendControl(int cmd, {int x = 0, int y = 0, int value = 0}) => using((arena) {
        final c = arena<lenny_control>();
        c.ref
          ..cmd = cmd
          ..x = x
          ..y = y
          ..value = value;
        return core.lenny_receiver_send_control(_ptr, c);
      });

  static String _cString(Array<Char> chars, int max) {
    final bytes = <int>[];
    for (var i = 0; i < max && chars[i] != 0; i++) {
      bytes.add(chars[i] & 0xFF);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  StreamInfo? streamInfo() => using((arena) {
        final s = arena<lenny_stream_settings>();
        if (core.lenny_session_stream_settings(_ptr, s) != LENNY_OK) return null;
        final m = s.ref.mode;
        return StreamInfo(m.width, m.height, m.fps_den == 0 ? 0 : m.fps_num / m.fps_den, s.ref.bitrate_kbps);
      });

  CoreStats stats() => using((arena) {
        final s = arena<lenny_stats>();
        core.lenny_session_get_stats(_ptr, s);
        return CoreStats(
          rttUs: s.ref.rtt_us,
          frames: s.ref.frames,
          bytes: s.ref.bytes,
          reconnects: s.ref.reconnects,
          latencyUs: s.ref.latency_us,
        );
      });

  /// Receiver: ask the phone for [mode] now (if streaming) and on every later connect.
  int selectStream(StreamMode mode, int bitrateKbps) => using((arena) {
        final s = arena<lenny_stream_settings>();
        s.ref
          ..codec = LENNY_CODEC_H264
          ..mode.width = mode.width
          ..mode.height = mode.height
          ..mode.fps_num = mode.fps
          ..mode.fps_den = 1
          ..bitrate_kbps = bitrateKbps;
        return core.lenny_receiver_select_stream(_ptr, s);
      });

  /// Receiver: answer an approval prompt.
  void approve(bool accept) => core.lenny_receiver_approve(_ptr, accept ? 1 : 0);

  /// Receiver: a fresh single-use pairing token for the QR code; the previous one stops working.
  Uint8List? newPairToken(Duration ttl) => using((arena) {
        final out = arena<Uint8>(LENNY_PAIR_TOKEN_SIZE);
        if (core.lenny_receiver_new_pair_token(_ptr, ttl.inMilliseconds, out) != LENNY_OK) return null;
        return Uint8List.fromList(out.asTypedList(LENNY_PAIR_TOKEN_SIZE));
      });

  /// Receiver: a phone approved earlier (hex [PeerInfo.deviceId]) connects without asking.
  void trustDevice(String hexId) => using((arena) {
        final id = arena<Uint8>(LENNY_DEVICE_ID_SIZE);
        for (var i = 0; i < LENNY_DEVICE_ID_SIZE; i++) {
          id[i] = int.parse(hexId.substring(2 * i, 2 * i + 2), radix: 16);
        }
        core.lenny_receiver_trust_device(_ptr, id);
      });

  /// Must run before the native side destroys the session. Afterwards this object is dead.
  void detach() {
    if (_detached) return;
    _detached = true;
    core.lenny_session_set_event_listener(_ptr, nullptr, nullptr); // returns only once no call is in flight
    _listener.close();
    _events.close();
  }
}
