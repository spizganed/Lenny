import 'package:flutter_test/flutter_test.dart';
import 'package:lenny/core_bindings/lenny_bindings.dart';
import 'package:lenny/services/core_session.dart';
import 'package:lenny/state/status_text.dart';

void main() {
  test('every state has text, and reasons change it where it matters', () {
    for (final s in LinkState.values) {
      expect(statusText(s, 0, sender: true), isNotEmpty);
      expect(statusText(s, 0, sender: false), isNotEmpty);
    }
    expect(statusText(LinkState.reconnecting, LENNY_REASON_BUSY, sender: true), contains('busy'));
    expect(statusText(LinkState.closed, LENNY_REASON_PAIR_DENIED, sender: true), contains('declined'));
    expect(statusText(LinkState.connecting, LENNY_REASON_LINK_LOST, sender: false), contains('disconnected'));
  });
}
