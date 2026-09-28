import 'dart:async';
import 'dart:ffi';

import '../core_bindings/lenny_bindings.dart';

/// The one lenny_core library in this process. The native plugins load the very same file, so a session created
/// natively can be driven from here by its address.
final LennyBindings core = LennyBindings(DynamicLibrary.open('liblenny_core.so'));

/// Mirrors lenny_state.
enum LinkState { idle, connecting, handshake, awaitingApproval, streaming, reconnecting, closed }

class CoreEvent {
  const CoreEvent(this.type, this.a, this.b);
  final lenny_event type;
  final int a, b;
}

/// One resolution + frame rate the phone offers (CAPS mode).
typedef StreamMode = ({int width, int height, int fps});

/// Control-plane view of a native session: events and state. Video never passes through here.
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

  /// Must run before the native side destroys the session. Afterwards this object is dead.
  void detach() {
    if (_detached) return;
    _detached = true;
    core.lenny_session_set_event_listener(_ptr, nullptr, nullptr); // returns only once no call is in flight
    _listener.close();
    _events.close();
  }
}
