import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../brand.dart';
import '../../services/core_session.dart';
import '../../state/providers.dart';
import '../../state/status_text.dart';
import '../../theme/lenny_tokens.dart';
import '../components/camera_controls.dart';
import '../components/sticker.dart';

/// Desktop home (design.md §6): header with status + where to connect, preview hero, ~380px control column.
class ReceiverScreen extends ConsumerWidget {
  const ReceiverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(receiverProvider.select((s) => s.pendingPhone), (_, name) {
      if (name != null) {
        _askApproval(context, ref, name);
      } else {
        // The request went away on its own (timeout, phone gave up): drop the stale prompt.
        Navigator.of(context).popUntil((r) => r is! RawDialogRoute);
      }
    });
    final s = ref.watch(receiverProvider);
    final streaming = s.link == LinkState.streaming;
    return Scaffold(
      body: DotBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _Header(state: s),
              const SizedBox(height: 28),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: _Preview(state: s)),
                  const SizedBox(width: 28),
                  SizedBox(
                    width: 380,
                    // Room for the card shadows, which paint outside the list's box.
                    child: ListView(padding: const EdgeInsets.only(right: 8, bottom: 8), children: [
                      if (streaming) ..._cameraCards(s, ref) else _PairCard(pairUri: s.pairUri),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  List<Widget> _cameraCards(ReceiverState s, WidgetRef ref) {
    final command = ref.read(receiverProvider.notifier).command;
    const gap = SizedBox(height: 16);
    String ms(double? v, [int digits = 0]) => v == null ? '–' : '${v.toStringAsFixed(digits)} ms';
    return [
      if (s.caps.hasLenses) ...[
        StickerCard(label: 'Camera', children: [LensPicker(caps: s.caps, controls: s.controls, onCommand: command)]),
        gap,
      ],
      StickerCard(label: 'Focus & light', children: [
        FocusButtons(caps: s.caps, controls: s.controls, onCommand: command),
        if (s.caps.hasTorch) TorchRow(controls: s.controls, onCommand: command),
      ]),
      gap,
      if (s.caps.hasExposure) ...[
        StickerCard(label: 'Exposure', children: [ExposureSlider(caps: s.caps, controls: s.controls, onCommand: command)]),
        gap,
      ],
      StickerCard(label: 'Stream', children: [
        _tiles(
          StatTile(label: 'Resolution', value: s.stream == null ? '–' : '${s.stream!.width}×${s.stream!.height}'),
          StatTile(label: 'Frame rate', value: '${s.fps.toStringAsFixed(0)} fps'),
        ),
        _tiles(
          StatTile(label: 'Bitrate', value: '${s.kbps} kbps'),
          StatTile(label: 'Latency', value: ms(s.displayLatencyMs)),
        ),
        _tiles(
          StatTile(label: 'Network', value: ms(s.networkLatencyMs)),
          StatTile(label: 'RTT', value: ms(s.rttMs, 1)),
        ),
      ]),
    ];
  }

  static Widget _tiles(Widget a, Widget b) =>
      Row(children: [Expanded(child: a), const SizedBox(width: 12), Expanded(child: b)]);

  Future<void> _askApproval(BuildContext context, WidgetRef ref, String name) async {
    final ok = await showStickerDialog<bool>(
      context,
      (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Allow this phone?', style: LennyTokens.heading()),
        const SizedBox(height: 10),
        Text('"$name" wants to stream its camera to this PC.', style: LennyTokens.body(size: 16)),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: StickerButton(label: 'Decline', onPressed: () => Navigator.pop(ctx, false))),
          const SizedBox(width: 12),
          Expanded(
            child: StickerButton(label: 'Allow', kind: ButtonKind.primary, onPressed: () => Navigator.pop(ctx, true)),
          ),
        ]),
      ]),
    );
    ref.read(receiverProvider.notifier).approve(ok ?? false);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});
  final ReceiverState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final status = s.error ?? statusText(s.link, s.reason, sender: false);
    return Row(children: [
      Text(Brand.appName, style: LennyTokens.wordmark(46)),
      const SizedBox(width: 16),
      const StickerBadge(text: 'DESKTOP', fill: LennyTokens.lilac),
      const SizedBox(width: 16),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440), // long statuses ellipsize; the rest goes to the chips
        child: StatusChip(
          color: linkColor(s.link, error: s.error != null),
          text: s.phone != null ? '$status · ${s.phone}' : status,
        ),
      ),
      const SizedBox(width: 24),
      // Wraps under itself on narrow windows instead of overflowing.
      Expanded(
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            if (s.port != 0) ...[
              Text('On your phone, connect to', style: LennyTokens.body(color: LennyTokens.textMuted)),
              for (final (i, a) in s.addresses.indexed) ...[
                if (i > 0) Text('or', style: LennyTokens.body(color: LennyTokens.textMuted)),
                CopyChip(value: a),
              ],
              CopyChip(value: '${s.port}', prefix: 'port'),
            ],
          ],
        ),
      ),
    ]);
  }
}

class _Preview extends ConsumerWidget {
  const _Preview({required this.state});
  final ReceiverState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = state;
    final streaming = s.link == LinkState.streaming;
    final lens = s.caps.lenses.length > s.controls.lens ? s.caps.lenses[s.controls.lens] : null;
    return Sticker(
      fill: LennyTokens.well,
      shadow: LennyTokens.shadowHero,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9, // the native side letterboxes into this box and maps taps through it
          child: Container(
            decoration: stickerBox(Colors.black, LennyTokens.radiusTile, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(LennyTokens.radiusTile - LennyTokens.border),
              child: Stack(fit: StackFit.expand, children: [
                if (streaming && s.textureId != null)
                  // Tap to focus there. The native side maps the tap through letterbox + rotation.
                  LayoutBuilder(
                    builder: (context, box) => GestureDetector(
                      onTapUp: (d) => ref
                          .read(receiverProvider.notifier)
                          .focusAt(d.localPosition.dx / box.maxWidth, d.localPosition.dy / box.maxHeight),
                      child: MouseRegion(cursor: SystemMouseCursors.precise, child: Texture(textureId: s.textureId!)),
                    ),
                  )
                else
                  ColoredBox(
                    color: LennyTokens.well,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.photo_camera_outlined, size: 56, color: LennyTokens.textFaint),
                      const SizedBox(height: 14),
                      Text(
                        streaming ? 'Waiting for video…' : 'No phone connected',
                        style: LennyTokens.heading(24).copyWith(color: LennyTokens.textFaint),
                      ),
                    ]),
                  ),
                if (streaming) ...[
                  const Positioned(left: 18, top: 18, child: StickerBadge(text: 'LIVE', fill: LennyTokens.green, dot: true)),
                  if (lens != null) Positioned(right: 18, top: 18, child: StickerBadge(text: lens)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _PairCard extends StatelessWidget {
  const _PairCard({required this.pairUri});
  final String? pairUri;

  @override
  Widget build(BuildContext context) => StickerCard(label: 'Pair a phone', children: [
        if (pairUri != null)
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              // A light, high-contrast field so every phone camera reads the code.
              decoration: stickerBox(LennyTokens.text, LennyTokens.radiusTile, LennyTokens.shadowSmall),
              child: QrImageView(
                data: pairUri!,
                size: 220,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: LennyTokens.ink),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: LennyTokens.ink),
                semanticsLabel: 'Pairing code for Lenny',
              ),
            ),
          ),
        Text('Open Lenny on your phone and tap Scan QR. It connects without asking here.', style: LennyTokens.body()),
        Text('Or tap Find PCs, or type an address from the top bar.', style: LennyTokens.body(color: LennyTokens.textMuted)),
      ]);
}
