import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lenny/services/pc_link.dart';

void main() {
  test('round trip keeps hosts, port, token and name', () {
    final token = Uint8List.fromList(List.generate(16, (i) => i * 7));
    final link = PcLink(hosts: ['192.168.1.20', '192.168.42.129'], port: 47474, name: 'Desk PC', token: token);
    final back = PcLink.parse(link.toUri())!;
    expect(back.hosts, ['192.168.1.20', '192.168.42.129']);
    expect(back.port, 47474);
    expect(back.name, 'Desk PC');
    expect(back.token, token);
  });

  test('discovery answer: no hosts, no token', () {
    final back = PcLink.parse(const PcLink(hosts: [], port: 5000, name: 'PC').toUri())!;
    expect(back.hosts, isEmpty);
    expect(back.token, isNull);
  });

  test('rejects foreign or broken links', () {
    expect(PcLink.parse('https://example.com'), isNull);
    expect(PcLink.parse('lenny://c?v=1&h=1.2.3.4'), isNull); // no port
    expect(PcLink.parse('lenny://c?v=1&p=99999'), isNull);
    expect(PcLink.parse('lenny://c?v=1&p=1&t=short'), isNull);
    expect(() => PcLink.parse('lenny://c?v=2&p=1'), throwsFormatException);
  });
}
