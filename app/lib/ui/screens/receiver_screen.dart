import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand.dart';
import '../../services/core_session.dart';
import '../../state/providers.dart';
import '../../state/status_text.dart';
import '../../theme/lenny_colors.dart';
import '../components/mascot_slot.dart';
import '../components/status_line.dart';

/// Desktop home: status, where to point the phone, live preview, stats, approval prompt.
class ReceiverScreen extends ConsumerWidget {
  const ReceiverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(receiverProvider.select((s) => s.pendingPhone), (_, name) {
      if (name != null) _askApproval(context, ref, name);
    });
    final s = ref.watch(receiverProvider);
    final streaming = s.link == LinkState.streaming;
    final status = s.error ?? statusText(s.link, s.reason, sender: false);
    final where = s.addresses.isEmpty ? "this PC's IP" : s.addresses.join('  or  ');
    return Scaffold(
      appBar: AppBar(title: const Text(Brand.desktopAppName)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const MascotSlot(size: 56),
              const SizedBox(width: 12),
              Expanded(child: StatusLine(link: s.link, text: s.phone != null ? '$status · ${s.phone}' : status)),
            ]),
            const SizedBox(height: 12),
            if (s.port != 0) SelectableText('On your phone, connect to: $where   port ${s.port}'),
            const SizedBox(height: 16),
            // The preview takes whatever height is left, so the stats line below always stays visible.
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: LennyColors.outline, width: 3),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: streaming && s.textureId != null
                          ? Texture(textureId: s.textureId!)
                          : Center(child: Text(streaming ? 'Waiting for video…' : 'No phone connected')),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              streaming
                  ? [
                      if (s.stream != null) '${s.stream!.width}×${s.stream!.height}',
                      '${s.fps.toStringAsFixed(0)} fps',
                      '${s.kbps} kbps',
                      if (s.rttMs != null) 'RTT ${s.rttMs!.toStringAsFixed(1)} ms',
                    ].join('   ·   ')
                  : ' ',
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _askApproval(BuildContext context, WidgetRef ref, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow this phone?'),
        content: Text('"$name" wants to stream its camera to this PC.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Decline')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
        ],
      ),
    );
    ref.read(receiverProvider.notifier).approve(ok ?? false);
  }
}
