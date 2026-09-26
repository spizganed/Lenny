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

/// Desktop home: header with toggleable connection details, preview hero with zoom/pan, 
/// and streamlined control column with rollout options and known devices.
class ReceiverScreen extends ConsumerStatefulWidget {
  const ReceiverScreen({super.key});

  @override
  ConsumerState<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends ConsumerState<ReceiverScreen> {
  bool showAdvancedRollout = false;
  
  // Mock list of known/recent devices for quick connect
  final List<String> knownDevices = [
    "Pixel 7 Pro (USB Tethering)",
    "Galaxy S23 (Wi-Fi - 192.168.1.50)"
  ];

  @override
  void initState() {
    super.initState();
    ref.listenManual(receiverProvider.select((s) => s.pendingPhone), (_, name) {
      if (name != null) {
        _askApproval(context, ref, name);
      } else {
        Navigator.of(context).popUntil((r) => r is! RawDialogRoute);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(receiverProvider);
    final streaming = s.link == LinkState.streaming;

    return Scaffold(
      body: DotBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(state: s),
                const SizedBox(height: 28),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Left side: Preview and Stats
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Flexible(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 380),
                                child: _Preview(state: s),
                              ),
                            ),
                            if (streaming) ...[
                              const SizedBox(height: 24),
                              IntrinsicHeight(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (s.modes.isNotEmpty && s.stream != null) ...[
                                      Expanded(child: _videoCard(s, ref)),
                                      const SizedBox(width: 24),
                                    ],
                                    Expanded(child: _statsCard(s)),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 28),
                      // Right side: Connection Flow & Controls Column (~380px)
                      SizedBox(
                        width: 380,
                        child: ListView(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          children: [
                            // Button constraint: No "Connect" button, only "Disconnect" when connected
                            if (streaming || s.link == LinkState.connecting)
                              StickerButton(
                                label: 'Disconnect',
                                icon: Icons.link_off_rounded,
                                kind: ButtonKind.destructive,
                                onPressed: ref.read(receiverProvider.notifier).disconnect,
                              ),
                            const SizedBox(height: 16),
                            if (streaming)
                              ..._cameraCards(s, ref)
                            else ...[
                              // QR Code always visible by default
                              _PairCard(pairUri: s.pairUri),
                              const SizedBox(height: 16),
                              
                              // Advanced connection methods hidden behind a rollout button
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.all(16),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LennyTokens.radiusTile)),
                                ),
                                icon: Icon(showAdvancedRollout ? Icons.expand_less : Icons.expand_more),
                                label: Text(showAdvancedRollout ? 'Hide Alternative Methods' : 'Other Connection Methods (USB, ADB, IP)'),
                                onPressed: () => setState(() => showAdvancedRollout = !showAdvancedRollout),
                              ),
                              
                              if (showAdvancedRollout) ...[
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: stickerBox(LennyTokens.well, LennyTokens.radiusTile, 0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('• USB / USB Tethering: Connect device via cable.', style: LennyTokens.body(size: 14)),
                                      const SizedBox(height: 6),
                                      Text('• ADB Forwarding: Runs automatically if enabled.', style: LennyTokens.body(size: 14)),
                                      const SizedBox(height: 6),
                                      Text('• Manual IP: Input host address directly.', style: LennyTokens.body(size: 14)),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 20),

                              // Known / Recent Devices List on launch
                              Text('Known Devices', style: LennyTokens.heading(18)),
                              const SizedBox(height: 8),
                              ...knownDevices.map((device) => Padding(
                                padding: const EdgeInsets.only(bottom: 8.0),
                                child: InkWell(
                                  onTap: () {
                                    // Trigger quick connect to device
                                  },
                                  borderRadius: BorderRadius.circular(LennyTokens.radiusTile),
                                  child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: stickerBox(Colors.white, LennyTokens.radiusTile, LennyTokens.shadowSmall),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.phone_android_rounded, size: 20),
                                            const SizedBox(width: 10),
                                            Text(device, style: LennyTokens.body()),
                                          ],
                                        ),
                                        const Icon(Icons.chevron_right_rounded),
                                      ],
                                    ),
                                  ),
                                ),
                              )),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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

class _Header extends StatefulWidget {
  const _Header({required this.state});
  final ReceiverState state;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  bool showSensitiveInfo = false; // Sensitive details (IP addresses) hidden by default

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
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
        constraints: const BoxConstraints(maxWidth: 440),
        child: StatusChip(
          color: linkColor(s.link, error: s.error != null),
          text: [status, ?s.phone, ?battery].join(' · '),
        ),
      ),
      const SizedBox(width: 24),
      Expanded(
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            if (s.port != 0) ...[
              // Button to show/hide sensitive info (IP addresses)
              TextButton.icon(
                onPressed: () => setState(() => showSensitiveInfo = !showSensitiveInfo),
                icon: Icon(showSensitiveInfo ? Icons.visibility_off : Icons.visibility, size: 16),
                label: Text(showSensitiveInfo ? 'Hide Details' : 'Show Network IP'),
              ),
              if (showSensitiveInfo) ...[
                Text('Connect to', style: LennyTokens.body(color: LennyTokens.textMuted)),
                for (final (i, a) in s.addresses.indexed) ...[
                  if (i > 0) Text('or', style: LennyTokens.body(color: LennyTokens.textMuted)),
                  CopyChip(value: a),
                ],
                CopyChip(value: '${s.port}', prefix: 'port'),
              ],
            ],
          ],
        ),
      ),
    ]);
  }
}

class _Preview extends ConsumerWidget {
  const _Preview({required this.ystate, required this.state}); // fixed constructor signature match
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
        // Preview box keeps a fixed aspect ratio container layout
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: stickerBox(Colors.black, LennyTokens.radiusTile, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(LennyTokens.radiusTile - LennyTokens.border),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (streaming && s.textureId != null)
                    // Zoom & Pan interactive support wrapping the video stream
                    InteractiveViewer(
                      minScale: 1.0,
                      maxScale: 4.0,
                      child: LayoutBuilder(
                        builder: (context, box) => GestureDetector(
                          onTapUp: (d) => ref
                              .read(receiverProvider.notifier)
                              .focusAt(d.localPosition.dx / box.maxWidth, d.localPosition.dy / box.maxHeight),
                          // BoxFit.cover ensures it fills the box completely at 16:9 without letterboxing
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: 1920,
                              height: 1080,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.precise,
                                child: Texture(textureId: s.textureId!),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    ColoredBox(
                      color: LennyTokens.well,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.photo_camera_outlined, size: 56, color: LennyTokens.textFaint),
                          const SizedBox(height: 14),
                          Text(
                            streaming ? 'Waiting for video…' : 'No phone connected',
                            style: LennyTokens.heading(24).copyWith(color: LennyTokens.textFaint),
                          ),
                        ],
                      ),
                    ),
                  if (streaming) ...[
                    const Positioned(left: 18, top: 18, child: StickerBadge(text: 'LIVE', fill: LennyTokens.green, dot: true)),
                    if (lens != null) Positioned(right: 18, top: 18, child: StickerBadge(text: lens)),
                  ],
                ],
              ),
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
              decoration: stickerBox(LennyTokens.text, LennyTokens.radiusTile, LennyTokens.shadowSmall),
              child: QrImageView(
                data: pairUri!,
                size: 200,
                padding: EdgeInsets.zero,
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: LennyTokens.ink),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: LennyTokens.ink),
                semanticsLabel: 'Pairing code for Lenny',
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text('Open Lenny on your phone and scan QR code to pair instantly.', style: LennyTokens.body()),
      ]);
}