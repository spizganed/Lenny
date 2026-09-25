import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pc_link.dart';

/// LAN discovery without mDNS: the phone broadcasts a UDP probe to the Lenny port, Lenny Desktop answers with a
/// [PcLink] (no host: the answer's source address is the host). Stdlib only, same code on both sides.
/// ponytail: IPv4 broadcast, so only the local subnet; mDNS (protocol.md §2) if multi-subnet setups ever matter.
const _probe = 'LENNY?1';

/// Desktop: answers probes until [stop].
class DiscoveryResponder {
  RawDatagramSocket? _socket;

  /// Binds UDP [udpPort]. Returns false if it's taken (another Lenny Desktop): discovery is then just off.
  Future<bool> start(int udpPort, PcLink Function() answer) async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
      _socket = s;
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null || utf8.decode(d.data, allowMalformed: true) != _probe) return;
        s.send(utf8.encode(answer().toUri()), d.address, d.port);
      });
      return true;
    } on SocketException {
      return false;
    }
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}

/// Phone: probes [targets] (default: the whole subnet) a few times and returns every Lenny Desktop that answered,
/// each with its answering address as the only host.
Future<List<PcLink>> discoverPcs(int udpPort, {List<String>? targets, Duration wait = const Duration(seconds: 1)}) async {
  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)..broadcastEnabled = true;
  final found = <String, PcLink>{};
  s.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = s.receive();
    if (d == null) return;
    try {
      final link = PcLink.parse(utf8.decode(d.data, allowMalformed: true));
      if (link != null) found[d.address.address] = link.withHosts([d.address.address]);
    } on FormatException {
      // a newer, incompatible desktop: not listed
    }
  });
  final to = [for (final t in targets ?? const ['255.255.255.255']) InternetAddress(t)];
  for (var i = 0; i < 3; i++) {
    for (final a in to) {
      s.send(utf8.encode(_probe), a, udpPort);
    }
    await Future<void>.delayed(wait ~/ 3);
  }
  s.close();
  return found.values.toList();
}
