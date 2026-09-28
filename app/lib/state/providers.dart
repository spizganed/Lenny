import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../brand.dart';
import '../core_bindings/lenny_bindings.dart';
import '../services/core_session.dart';
import '../services/discovery.dart';
import '../services/pc_link.dart';
import '../services/platform_services.dart';
import 'camera.dart';

final senderServiceProvider = Provider((_) => SenderService());

// ---- Sender (phone) --------------------------------------------------------
class SenderState {
  const SenderState({
    this.link = LinkState.idle,
    this.reason = 0,
    this.error,
    this.caps = const CameraCaps(),
    this.controls = const CameraControls(),
    this.lastHost,
    this.lastPort,
    this.found,
    this.searching = false,
  });

  final LinkState link;
  final int reason;
  final String? error;
  final CameraCaps caps;
  final CameraControls controls;
  final String? lastHost; // the PC that streamed last (or now), to prefill the form
  final int? lastPort;
  final List<PcLink>? found; // Lenny Desktops on this network, from [SenderController.findPcs]; null = not searched
  final bool searching;

  bool get active => link != LinkState.idle && link != LinkState.closed;

  SenderState copyWith({
    LinkState? link,
    int? reason,
    String? Function()? error,
    CameraCaps? caps,
    CameraControls? controls,
    String? lastHost,
    int? lastPort,
    List<PcLink>? found,
    bool? searching,
  }) =>
      SenderState(
        link: link ?? this.link,
        reason: reason ?? this.reason,
        error: error != null ? error() : this.error,
        caps: caps ?? this.caps,
        controls: controls ?? this.controls,
        lastHost: lastHost ?? this.lastHost,
        lastPort: lastPort ?? this.lastPort,
        found: found ?? this.found,
        searching: searching ?? this.searching,
      );

  /// A fresh connection attempt: keeps the remembered PC and the found list, drops everything else.
  SenderState restart({required LinkState link, String? error}) => SenderState(
        link: link,
        error: error,
        lastHost: lastHost,
        lastPort: lastPort,
        found: found,
        searching: searching,
      );
}

class SenderController extends Notifier<SenderState> {
  CoreSession? _session;
  final _subs = <StreamSubscription<Object>>[];
  ({String host, int port})? _target;

  static const _hostKey = 'lastHost', _portKey = 'lastPort';

  @override
  SenderState build() {
    ref.onDispose(disconnect);
    Future.microtask(_loadLastPc);
    return const SenderState();
  }

  Future<void> _loadLastPc() async {
    final p = await SharedPreferences.getInstance();
    state = state.copyWith(lastHost: p.getString(_hostKey), lastPort: p.getInt(_portKey));
  }

  Future<void> connect(String host, int port, {Uint8List? token}) async {
    await disconnect();
    _target = (host: host, port: port);
    state = state.restart(link: LinkState.connecting);
    try {
      final service = ref.read(senderServiceProvider);
      final r = await service.start(host, port, token: token);
      _session = r.session;
      _subs
        ..add(r.session.events.where((e) => e.type == lenny_event.LENNY_EVENT_STATE).listen((e) {
          _onLink(LinkState.values[e.a], e.b);
        }))
        ..add(service.controls.listen((c) => state = state.copyWith(controls: c)));
      // Catch up on anything that happened before the listeners were attached.
      state = state.copyWith(caps: r.caps);
      _onLink(r.session.state, state.reason);
    } catch (e) {
      state = state.restart(link: LinkState.closed, error: e.toString());
    }
  }

  void _onLink(LinkState link, int reason) {
    state = state.copyWith(link: link, reason: reason);
    final t = _target;
    if (link != LinkState.streaming || t == null) return;
    // Remember only a PC that actually streamed, so a typo never overwrites a good address.
    state = state.copyWith(lastHost: t.host, lastPort: t.port);
    SharedPreferences.getInstance().then((p) => p
      ..setString(_hostKey, t.host)
      ..setInt(_portKey, t.port));
  }

  /// Fills [SenderState.found] with the Lenny Desktops answering on this network.
  Future<void> findPcs() async {
    if (state.searching) return;
    state = state.copyWith(searching: true);
    try {
      state = state.copyWith(found: await discoverPcs(Brand.defaultPort), searching: false);
    } catch (e) {
      state = state.copyWith(searching: false, error: () => 'Could not search the network: $e');
    }
  }

  /// Scans a desktop's QR code and connects with its pairing token (no approval prompt on the PC).
  Future<void> scanAndConnect() async {
    final String? raw;
    try {
      raw = await ref.read(senderServiceProvider).scanQr();
    } catch (e) {
      return setError('Could not open the QR scanner: $e');
    }
    if (raw == null) return; // cancelled
    final PcLink? link;
    try {
      link = PcLink.parse(raw);
    } on FormatException catch (e) {
      return setError(e.message);
    }
    if (link == null || link.hosts.isEmpty) return setError('That is not a Lenny Desktop code');
    // The code lists every address the PC has (Wi-Fi, VPN, virtual adapters): use one that answers.
    var host = link.hosts.first;
    try {
      final answered = await discoverPcs(Brand.defaultPort, targets: link.hosts);
      if (answered.isNotEmpty) host = answered.first.hosts.first;
    } catch (_) {
      // discovery blocked: try the first address anyway
    }
    await connect(host, link.port, token: link.token);
  }

  void setError(String? message) => state = state.copyWith(error: () => message);

  /// The phone's own camera buttons.
  Future<void> command(CameraCommand c) => ref.read(senderServiceProvider).control(c);

  Future<void> disconnect() async {
    final s = _session;
    if (s == null) return;
    _session = null;
    _target = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await ref.read(senderServiceProvider).stop(s);
    state = state.restart(link: LinkState.closed).copyWith(reason: LENNY_REASON_USER);
  }
}

final senderProvider = NotifierProvider<SenderController, SenderState>(SenderController.new);
