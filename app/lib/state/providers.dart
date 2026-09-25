import 'dart:async';
import 'dart:io';
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
final receiverServiceProvider = Provider((_) => ReceiverService());

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
    final raw = await ref.read(senderServiceProvider).scanQr();
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
    this.pairUri,
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
  final String? pairUri; // lenny:// link for the QR code, with a fresh single-use token
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
    String? pairUri,
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
        pairUri: pairUri ?? this.pairUri,
        error: error,
      );
}

class ReceiverController extends Notifier<ReceiverState> {
  CoreSession? _session;
  StreamSubscription<CoreEvent>? _sub;
  Timer? _statsTimer, _pairTimer;
  CoreStats? _lastStats;
  final _discovery = DiscoveryResponder();

  static const _trustedKey = 'trustedPhones';
  static const _pairTtl = Duration(seconds: 90), _pairRefresh = Duration(seconds: 80);

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
      final prefs = await SharedPreferences.getInstance();
      for (final id in prefs.getStringList(_trustedKey) ?? const <String>[]) {
        r.session.trustDevice(id);
      }
      _sub = r.session.events.listen(_onEvent);
      _onEvent(CoreEvent(lenny_event.LENNY_EVENT_STATE, r.session.state.index, 0)); // catch up
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
      _refreshPairCode();
      await _discovery.start(Brand.defaultPort, () => PcLink(hosts: const [], port: r.port, name: Platform.localHostname));
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
        if (link == LinkState.streaming && peer != null) {
          _trust(peer.deviceId);
          _refreshPairCode(); // the shown token may just have been used
        }
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

  /// A phone that streamed once connects later without asking.
  Future<void> _trust(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_trustedKey) ?? const <String>[];
    if (!ids.contains(deviceId)) await prefs.setStringList(_trustedKey, [...ids, deviceId]);
  }

  /// New single-use token in the QR code, renewed before the old one expires.
  void _refreshPairCode() {
    final s = _session;
    if (s == null) return;
    _pairTimer?.cancel();
    _pairTimer = Timer(_pairRefresh, _refreshPairCode);
    final token = s.newPairToken(_pairTtl);
    if (token == null) return;
    state = state.copyWith(
      pairUri: PcLink(hosts: state.addresses, port: state.port, name: Platform.localHostname, token: token).toUri(),
    );
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
    _pairTimer?.cancel();
    _discovery.stop();
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
