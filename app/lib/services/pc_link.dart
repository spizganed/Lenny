import 'dart:convert';
import 'dart:typed_data';

/// Where a Lenny Desktop can be reached: `lenny://c?v=1&h=<ip>[,<ip>…]&p=<port>&t=<token>&n=<pc name>`
/// (protocol.md §6.4). The QR code carries all of it; a discovery answer leaves out `h` (the sender address is the
/// host) and `t`.
class PcLink {
  const PcLink({required this.hosts, required this.port, this.name = '', this.token});

  final List<String> hosts;
  final int port;
  final String name;
  final Uint8List? token; // single-use pairing token, 16 bytes

  static const version = '1';

  String toUri() => Uri(scheme: 'lenny', host: 'c', queryParameters: {
        'v': version,
        if (hosts.isNotEmpty) 'h': hosts.join(','),
        'p': '$port',
        if (token != null) 't': base64Url.encode(token!).replaceAll('=', ''),
        if (name.isNotEmpty) 'n': name,
      }).toString();

  /// Null if [text] isn't a Lenny link. Throws [FormatException] for a link from a newer, incompatible Lenny.
  /// Unknown parameters are ignored (room for later additions such as a cert fingerprint).
  static PcLink? parse(String text) {
    final u = Uri.tryParse(text.trim());
    if (u == null || u.scheme != 'lenny' || u.host != 'c') return null;
    final q = u.queryParameters;
    if (q['v'] != version) throw const FormatException('This code is from a newer Lenny. Update the app.');
    final port = int.tryParse(q['p'] ?? '');
    if (port == null || port <= 0 || port > 65535) return null;
    Uint8List? token;
    final t = q['t'];
    if (t != null) {
      try {
        token = base64Url.decode(base64Url.normalize(t));
      } on FormatException {
        return null;
      }
      if (token.length != 16) return null;
    }
    return PcLink(
      hosts: [for (final h in (q['h'] ?? '').split(',')) if (h.trim().isNotEmpty) h.trim()],
      port: port,
      name: q['n'] ?? '',
      token: token,
    );
  }

  PcLink withHosts(List<String> hosts) => PcLink(hosts: hosts, port: port, name: name, token: token);
}
