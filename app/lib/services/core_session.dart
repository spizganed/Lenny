import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../core_bindings/lenny_bindings.dart';

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

class PeerInfo {
  const PeerInfo(this.name, this.platform);
  final String name;
  final int platform;
}

class StreamInfo {
  const StreamInfo(this.width, this.height, this.fps, this.bitrateKbps);
  final int width, height;
  final double fps;
  final int bitrateKbps;
}

class CoreStats {
  const CoreStats({required this.rttUs, required this.frames, required this.bytes, required this.reconnects});
  final int rttUs, frames, bytes, reconnects;
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
        final bytes = <int>[];
        for (var i = 0; i < 64 && p.ref.name[i] != 0; i++) {
          bytes.add(p.ref.name[i] & 0xFF);
        }
        return PeerInfo(utf8.decode(bytes, allowMalformed: true), p.ref.platform);
      });

  StreamInfo? streamInfo() => using((arena) {
        final s = arena<lenny_stream_settings>();
        if (core.lenny_session_stream_settings(_ptr, s) != LENNY_OK) return null;
        final m = s.ref.mode;
        return StreamInfo(m.width, m.height, m.fps_den == 0 ? 0 : m.fps_num / m.fps_den, s.ref.bitrate_kbps);
      });

  CoreStats stats() => using((arena) {
        final s = arena<lenny_stats>();
        core.lenny_session_get_stats(_ptr, s);
        return CoreStats(rttUs: s.ref.rtt_us, frames: s.ref.frames, bytes: s.ref.bytes, reconnects: s.ref.reconnects);
      });

  /// Receiver: answer an approval prompt.
  void approve(bool accept) => core.lenny_receiver_approve(_ptr, accept ? 1 : 0);

  /// Must run before the native side destroys the session. Afterwards this object is dead.
  void detach() {
    if (_detached) return;
    _detached = true;
    core.lenny_session_set_event_listener(_ptr, nullptr, nullptr); // returns only once no call is in flight
    _listener.close();
    _events.close();
  }
}
