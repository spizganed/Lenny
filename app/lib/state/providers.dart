import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../brand.dart';
import '../core_bindings/lenny_bindings.dart';
import '../services/core_session.dart';
import '../services/platform_services.dart';
import 'camera.dart';

final senderServiceProvider = Provider((_) => SenderService());
final receiverServiceProvider = Provider((_) => ReceiverService());

// ---- Sender (phone) --------------------------------------------------------
class SenderState {
  const SenderState({
    this.link = LinkState.idle,
    this.reason = 0,
    this.error,
    this.caps = const CameraCaps(),
    this.controls = const CameraControls(),
  });

  final LinkState link;
  final int reason;
  final String? error;
  final CameraCaps caps;
  final CameraControls controls;

  bool get active => link != LinkState.idle && link != LinkState.closed;

  SenderState copyWith({LinkState? link, int? reason, CameraCaps? caps, CameraControls? controls}) => SenderState(
        link: link ?? this.link,
        reason: reason ?? this.reason,
        error: error,
        caps: caps ?? this.caps,
        controls: controls ?? this.controls,
      );
}

class SenderController extends Notifier<SenderState> {
  CoreSession? _session;
  final _subs = <StreamSubscription<Object>>[];

  @override
  SenderState build() {
    ref.onDispose(disconnect);
    return const SenderState();
  }

  Future<void> connect(String host, int port) async {
    await disconnect();
    state = const SenderState(link: LinkState.connecting);
    try {
      final service = ref.read(senderServiceProvider);
      final r = await service.start(host, port);
      _session = r.session;
      _subs
        ..add(r.session.events.where((e) => e.type == lenny_event.LENNY_EVENT_STATE).listen((e) {
          state = state.copyWith(link: LinkState.values[e.a], reason: e.b);
        }))
        ..add(service.controls.listen((c) => state = state.copyWith(controls: c)));
      // Catch up on anything that happened before the listeners were attached.
      state = state.copyWith(link: r.session.state, caps: r.caps);
    } catch (e) {
      state = SenderState(link: LinkState.closed, error: e.toString());
    }
  }

  /// The phone's own camera buttons.
  Future<void> command(CameraCommand c) => ref.read(senderServiceProvider).control(c);

  Future<void> disconnect() async {
    final s = _session;
    if (s == null) return;
    _session = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await ref.read(senderServiceProvider).stop(s);
    state = const SenderState(link: LinkState.closed, reason: LENNY_REASON_USER);
  }
}

final senderProvider = NotifierProvider<SenderController, SenderState>(SenderController.new);

// ---- Receiver (desktop) ------------------------------------------------------
class ReceiverState {
  const ReceiverState({
    this.link = LinkState.idle,
    this.reason = 0,
    this.port = 0,
    this.textureId,
    this.addresses = const [],
    this.pendingPhone,
    this.phone,
    this.stream,
    this.caps = const CameraCaps(),
    this.controls = const CameraControls(),
    this.fps = 0,
    this.kbps = 0,
    this.rttMs,
    this.networkLatencyMs,
    this.displayLatencyMs,
    this.error,
  });

  final LinkState link;
  final int reason;
  final int port;
  final int? textureId;
  final List<String> addresses; // this PC's IPv4 addresses, for typing into the phone
  final String? pendingPhone; // name of a phone waiting for approval
  final String? phone;
  final StreamInfo? stream;
  final CameraCaps caps; // the connected phone's camera
  final CameraControls controls;
  final double fps;
  final int kbps;
  final double? rttMs;
  final double? networkLatencyMs; // capture -> received here
  final double? displayLatencyMs; // capture -> shown in the preview
  final String? error;

  ReceiverState copyWith({
    LinkState? link,
    int? reason,
    String? Function()? pendingPhone,
    String? Function()? phone,
    StreamInfo? Function()? stream,
    CameraCaps? caps,
    CameraControls? controls,
    double? fps,
    int? kbps,
    double? Function()? rttMs,
    double? Function()? networkLatencyMs,
    double? Function()? displayLatencyMs,
  }) =>
      ReceiverState(
        link: link ?? this.link,
        reason: reason ?? this.reason,
        port: port,
        textureId: textureId,
        addresses: addresses,
        pendingPhone: pendingPhone != null ? pendingPhone() : this.pendingPhone,
        phone: phone != null ? phone() : this.phone,
        stream: stream != null ? stream() : this.stream,
        caps: caps ?? this.caps,
        controls: controls ?? this.controls,
        fps: fps ?? this.fps,
        kbps: kbps ?? this.kbps,
        rttMs: rttMs != null ? rttMs() : this.rttMs,
        networkLatencyMs: networkLatencyMs != null ? networkLatencyMs() : this.networkLatencyMs,
        displayLatencyMs: displayLatencyMs != null ? displayLatencyMs() : this.displayLatencyMs,
        error: error,
      );
}

class ReceiverController extends Notifier<ReceiverState> {
  CoreSession? _session;
  StreamSubscription<CoreEvent>? _sub;
  Timer? _statsTimer;
  CoreStats? _lastStats;

  @override
  ReceiverState build() {
    ref.onDispose(_stop);
    Future.microtask(_start);
    return const ReceiverState();
  }

  Future<void> _start() async {
    try {
      final r = await ref.read(receiverServiceProvider).start(Brand.defaultPort);
      _session = r.session;
      state = ReceiverState(
        link: LinkState.connecting,
        port: r.port,
        textureId: r.textureId,
        addresses: await _localAddresses(),
      );
      _sub = r.session.events.listen(_onEvent);
      _onEvent(CoreEvent(lenny_event.LENNY_EVENT_STATE, r.session.state.index, 0)); // catch up
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
    } catch (e) {
      state = ReceiverState(link: LinkState.closed, error: 'Could not start: $e');
    }
  }

  void _onEvent(CoreEvent e) {
    final s = _session;
    if (s == null) return;
    switch (e.type) {
      case lenny_event.LENNY_EVENT_STATE:
        final link = LinkState.values[e.a];
        final live = link == LinkState.streaming || link == LinkState.awaitingApproval || link == LinkState.handshake;
        final peer = live ? s.peer() : null;
        state = state.copyWith(
          link: link,
          reason: e.b,
          pendingPhone: link == LinkState.awaitingApproval ? null : () => null,
          phone: () => peer?.name,
          caps: peer?.caps ?? const CameraCaps(),
          stream: live ? null : () => null,
          controls: live ? null : const CameraControls(),
        );
      case lenny_event.LENNY_EVENT_APPROVAL_NEEDED:
        state = state.copyWith(pendingPhone: () => s.peer()?.name ?? 'Unknown phone');
      case lenny_event.LENNY_EVENT_STREAM_START:
        state = state.copyWith(stream: s.streamInfo, caps: s.peer()?.caps);
      case lenny_event.LENNY_EVENT_CONTROL_STATE:
        final c = s.controlState();
        if (c != null) state = state.copyWith(controls: c);
      default:
        break;
    }
  }

  void approve(bool accept) {
    _session?.approve(accept);
    state = state.copyWith(pendingPhone: () => null);
  }

  /// Remote camera control. The phone answers with a new control state.
  void command(CameraCommand c) => _session?.sendControl(c.cmd, value: c.value);

  /// Tap on the preview (normalised to its 16:9 box).
  Future<void> focusAt(double x, double y) => ref.read(receiverServiceProvider).focusAt(x, y);

  Future<void> _pollStats() async {
    final s = _session;
    if (s == null) return;
    final now = s.stats();
    final display = await ref.read(receiverServiceProvider).displayLatencyMs();
    final last = _lastStats;
    _lastStats = now;
    if (last == null) return;
    state = state.copyWith(
      fps: (now.frames - last.frames).toDouble(),
      kbps: (now.bytes - last.bytes) * 8 ~/ 1000,
      rttMs: () => now.rttUs < 0 ? null : now.rttUs / 1000,
      networkLatencyMs: () => now.latencyUs < 0 ? null : now.latencyUs / 1000,
      displayLatencyMs: () => display,
    );
  }

  Future<void> _stop() async {
    _statsTimer?.cancel();
    await _sub?.cancel();
    final s = _session;
    _session = null;
    if (s != null) await ref.read(receiverServiceProvider).stop(s);
  }

  static Future<List<String>> _localAddresses() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [for (final i in ifaces) for (final a in i.addresses) a.address];
    } catch (_) {
      return const [];
    }
  }
}

final receiverProvider = NotifierProvider<ReceiverController, ReceiverState>(ReceiverController.new);
