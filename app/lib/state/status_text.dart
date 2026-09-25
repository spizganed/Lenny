import '../core_bindings/lenny_bindings.dart';
import '../services/core_session.dart';

/// Human text for a link state + reason. Every state says something: never a silent failure.
String statusText(LinkState state, int reason, {required bool sender}) {
  switch (state) {
    case LinkState.idle:
      return 'Not connected';
    case LinkState.connecting:
      if (sender) return 'Connecting…';
      if (reason == LENNY_REASON_LINK_LOST) return 'Phone disconnected. Waiting for it to come back…';
      return 'Waiting for a phone';
    case LinkState.handshake:
      return 'Connecting…';
    case LinkState.awaitingApproval:
      return 'A phone wants to connect';
    case LinkState.streaming:
      return 'Streaming';
    case LinkState.reconnecting:
      if (reason == LENNY_REASON_BUSY) return 'The PC is busy with another phone. Retrying…';
      return 'Connection lost. Reconnecting…';
    case LinkState.closed:
      return switch (reason) {
        LENNY_REASON_PAIR_DENIED => sender ? 'The PC declined the connection' : 'Phone declined',
        LENNY_REASON_VERSION => 'Versions don\'t match. Update Lenny on both devices.',
        LENNY_REASON_ROLE => 'That device is not a Lenny ${sender ? 'Desktop' : 'phone'}',
        _ => 'Disconnected',
      };
  }
}
