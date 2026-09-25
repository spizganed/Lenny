import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../brand.dart';
import '../core_bindings/lenny_bindings.dart';
import '../services/core_session.dart';
import '../services/platform_services.dart';

final senderServiceProvider = Provider((_) => SenderService());
final receiverServiceProvider = Provider((_) => ReceiverService());

// ---- Sender (phone) --------------------------------------------------------
class SenderState {
  const SenderState({this.link = LinkState.idle, this.reason = 0, this.error});
  final LinkState link;
  final int reason;
  final String? error;

  bool get active => link != LinkState.idle && link != LinkState.closed;
}

class SenderController extends Notifier<SenderState> {
  CoreSession? _session;
  StreamSubscription<CoreEvent>? _sub;

  @override
  SenderState build() {
    ref.onDispose(disconnect);
    return const SenderState();
  }

  Future<void> connect(String host, int port) async {
    await disconnect();
    state = const SenderState(link: LinkState.connecting);
    try {
      final s = await ref.read(senderServiceProvider).start(host, port);
      _session = s;
      _sub = s.events.where((e) => e.type == lenny_event.LENNY_EVENT_STATE).listen((e) {
        state = SenderState(link: LinkState.values[e.a], reason: e.b);
      });
      state = SenderState(link: s.state); // catch up on anything before the listener was attached
    } catch (e) {
      state = SenderState(link: LinkState.closed, error: e.toString());
    }
  }

  Future<void> disconnect() async {
    final s = _session;
    if (s == null) return;
    _session = null;
    await _sub?.cancel();
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
    this.fps = 0,
    this.kbps = 0,
    this.rttMs,
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
  final double fps;
  final int kbps;
  final double? rttMs;
  final String? error;

  ReceiverState copyWith({
    LinkState? link,
    int? reason,
    String? Function()? pendingPhone,
    String? Function()? phone,
    StreamInfo? Function()? stream,
    double? fps,
    int? kbps,
    double? Function()? rttMs,
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
        fps: fps ?? this.fps,
        kbps: kbps ?? this.kbps,
        rttMs: rttMs != null ? rttMs() : this.rttMs,
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
        state = state.copyWith(
          link: link,
          reason: e.b,
          pendingPhone: link == LinkState.awaitingApproval ? null : () => null,
          phone: () => live ? s.peer()?.name : null,
          stream: live ? null : () => null,
        );
      case lenny_event.LENNY_EVENT_APPROVAL_NEEDED:
        state = state.copyWith(pendingPhone: () => s.peer()?.name ?? 'Unknown phone');
      case lenny_event.LENNY_EVENT_STREAM_START:
        state = state.copyWith(stream: s.streamInfo);
      default:
        break;
    }
  }

  void approve(bool accept) {
    _session?.approve(accept);
    state = state.copyWith(pendingPhone: () => null);
  }

  void _pollStats() {
    final s = _session;
    if (s == null) return;
    final now = s.stats();
    final last = _lastStats;
    _lastStats = now;
    if (last == null) return;
    state = state.copyWith(
      fps: (now.frames - last.frames).toDouble(),
      kbps: (now.bytes - last.bytes) * 8 ~/ 1000,
      rttMs: () => now.rttUs < 0 ? null : now.rttUs / 1000,
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
