import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../brand.dart';
import '../../core_bindings/lenny_bindings.dart';
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
              // Everything fits without scrolling: the preview takes whatever height the cards leave. The column only
              // scrolls on windows too short for it.
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      // Capped so the space under it is free for controls; the virtual camera is the real output.
                      Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 380), child: _Preview(state: s))),
                      if (streaming) ...[
                        const SizedBox(height: 24),
                        IntrinsicHeight(
                          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            if (s.modes.isNotEmpty && s.stream != null) ...[
                              Expanded(child: _videoCard(s, ref)),
                              const SizedBox(width: 24),
                            ],
                            Expanded(child: _statsCard(s)),
                          ]),
                        ),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 28),
                  SizedBox(
                    width: 380,
                    // Room for the card shadows, which paint outside the list's box.
                    child: ListView(padding: const EdgeInsets.only(right: 8, bottom: 8), children: [
                      _linkButton(s, ref),
                      const SizedBox(height: 16),
                      if (streaming)
                        ..._cameraCards(s, ref)
                      else if (!_stopped(s))
                        _PairCard(pairUri: s.pairUri),
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

  static bool _stopped(ReceiverState s) => s.link == LinkState.closed && s.reason == LENNY_REASON_USER;

  Widget _linkButton(ReceiverState s, WidgetRef ref) {
    final ctl = ref.read(receiverProvider.notifier);
    return _stopped(s)
        ? StickerButton(label: 'Connect', icon: Icons.link_rounded, kind: ButtonKind.primary, onPressed: ctl.connect)
        : StickerButton(
            label: 'Disconnect',
            icon: Icons.link_off_rounded,
            kind: ButtonKind.destructive,
            onPressed: ctl.disconnect,
          );
  }

  List<Widget> _cameraCards(ReceiverState s, WidgetRef ref) {
    final command = ref.read(receiverProvider.notifier).command;
    const gap = SizedBox(height: 16);
    return [
      if (s.caps.hasLenses) ...[
        StickerCard(label: 'Camera', children: [LensPicker(caps: s.caps, controls: s.controls, onCommand: command)]),
        gap,
      ],
      StickerCard(label: 'Focus & light', children: [
        FocusButtons(caps: s.caps, controls: s.controls, onCommand: command),
        if (s.caps.hasTorch) TorchRow(controls: s.controls, onCommand: command),
      ]),
      if (s.caps.hasExposure || s.caps.has(LENNY_CAP_EXPOSURE_LOCK)) ...[
        gap,
        StickerCard(label: 'Exposure', children: [
          if (s.caps.hasExposure) ExposureSlider(caps: s.caps, controls: s.controls, onCommand: command),
          if (s.caps.has(LENNY_CAP_EXPOSURE_LOCK)) ExposureLockToggle(controls: s.controls, onCommand: command),
        ]),
      ],
    ];
  }

  Widget _videoCard(ReceiverState s, WidgetRef ref) {
    final st = s.stream!;
    return StickerCard(label: 'Video', children: [
      VideoPicker(
        modes: s.modes,
        current: (width: st.width, height: st.height, fps: st.fps.round()),
        onSelect: ref.read(receiverProvider.notifier).selectMode,
      ),
    ]);
  }

  Widget _statsCard(ReceiverState s) {
    String ms(double? v, [int digits = 0]) => v == null ? '–' : '${v.toStringAsFixed(digits)} ms';
    Widget row(List<Widget> tiles) => Row(children: [
          for (final (i, t) in tiles.indexed) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: t)],
        ]);
    return StickerCard(label: 'Stream', children: [
      row([
        StatTile(label: 'Resolution', value: s.stream == null ? '–' : '${s.stream!.width}×${s.stream!.height}'),
        StatTile(label: 'Frame rate', value: '${s.fps.toStringAsFixed(0)} fps'),
        StatTile(label: 'Bitrate', value: '${(s.kbps / 1000).toStringAsFixed(1)} Mbps'),
      ]),
      row([
        StatTile(label: 'Latency', value: ms(s.displayLatencyMs)),
        StatTile(label: 'Network', value: ms(s.networkLatencyMs)),
        StatTile(label: 'RTT', value: ms(s.rttMs, 1)),
      ]),
    ]);
  }

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
    final battery = s.link != LinkState.streaming || s.controls.battery == null
        ? null
        : '${s.controls.battery}%${s.controls.charging ? ' charging' : ''}';
    return Row(children: [
      Text(Brand.appName, style: LennyTokens.wordmark(46)),
      const SizedBox(width: 16),
      const StickerBadge(text: 'DESKTOP', fill: LennyTokens.lilac),
      const SizedBox(width: 16),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440), // long statuses ellipsize; the rest goes to the chips
        child: StatusChip(
          color: linkColor(s.link, error: s.error != null),
          text: [status, ?s.phone, ?battery].join(' · '),
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
