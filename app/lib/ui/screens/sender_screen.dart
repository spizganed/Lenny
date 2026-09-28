import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand.dart';
import '../../services/core_session.dart';
import '../../services/pc_link.dart';
import '../../state/providers.dart';
import '../../state/status_text.dart';
import '../../theme/lenny_tokens.dart';
import '../components/camera_controls.dart';
import '../components/sticker.dart';

/// Phone home (design.md §6): status hero → connection card → camera card. Single column.
/// Not connected, the QR scan and the PC search come first (a search also runs on open); Manual, USB ADB and
/// USB tether stay folded behind one button each.
class SenderScreen extends ConsumerStatefulWidget {
  const SenderScreen({super.key});

  @override
  ConsumerState<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends ConsumerState<SenderScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '${Brand.defaultPort}');
  int? _method; // 0 Manual, 1 USB ADB, 2 USB tether; null = folded

  @override
  void initState() {
    super.initState();
    // Prefill with the last PC that streamed, once it's loaded (unless the user already typed something).
    ref.listenManual(senderProvider.select((s) => (s.lastHost, s.lastPort)), (_, last) {
      if (last.$1 != null && _host.text.isEmpty) _host.text = last.$1!;
      if (last.$2 != null && _port.text == '${Brand.defaultPort}') _port.text = '${last.$2}';
    }, fireImmediately: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !ref.read(senderProvider).active) ref.read(senderProvider.notifier).findPcs();
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _connect() {
    final port = int.tryParse(_port.text.trim());
    if (_host.text.trim().isEmpty || port == null || port <= 0 || port > 65535) {
      ref.read(senderProvider.notifier).setError('Enter the PC address and port');
      return;
    }
    ref.read(senderProvider.notifier).connect(_host.text.trim(), port);
  }

  /// USB ADB: Lenny Desktop runs `adb reverse`, so the PC is at this phone's own 127.0.0.1.
  void _connectUsb() =>
      ref.read(senderProvider.notifier).connect('127.0.0.1', int.tryParse(_port.text.trim()) ?? Brand.defaultPort);

  void _connectTo(PcLink pc) {
    _host.text = pc.hosts.first;
    _port.text = '${pc.port}';
    ref.read(senderProvider.notifier).connect(pc.hosts.first, pc.port);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(senderProvider);
    final ctl = ref.read(senderProvider.notifier);
    final streaming = s.link == LinkState.streaming;
    return Scaffold(
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, o) {
            final title = Text(Brand.appName, style: LennyTokens.wordmark(32));
            final wide = o == Orientation.landscape;
            final hero = _StatusHero(state: s, compact: wide);
            final muted = LennyTokens.body(color: LennyTokens.textMuted);
            final quick = [
              Row(
                children: [
                  Expanded(
                    child: StickerButton(
                      label: 'Scan QR',
                      // Landscape columns are too narrow for icon + label.
                      icon: wide ? null : Icons.qr_code_scanner_rounded,
                      onPressed: ctl.scanAndConnect,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StickerButton(
                      label: s.searching ? 'Searching…' : 'Find PCs',
                      icon: wide ? null : Icons.wifi_find_rounded,
                      onPressed: s.searching ? null : ctl.findPcs,
                    ),
                  ),
                ],
              ),
              if (s.found case final found?)
                if (found.isEmpty)
                  Text('No Lenny Desktop answered. Is it open and on the same Wi-Fi?', style: muted)
                else
                  for (final pc in found) _FoundPc(pc: pc, onTap: () => _connectTo(pc)),
            ];
            // The other ways in, one folded panel each; a second tap folds it again.
            final other = [
              Segmented(
                labels: const ['Manual', 'USB ADB', 'USB tether'],
                selected: _method ?? -1,
                height: 48,
                onSelect: (i) => setState(() => _method = _method == i ? null : i),
              ),
              ...switch (_method) {
                0 => [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        flex: 3,
                        child: StickerField(
                          label: 'PC address',
                          controller: _host,
                          hint: '192.168.x.x',
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: StickerField(
                          label: 'Port',
                          controller: _port,
                          keyboardType: TextInputType.number,
                          textInputAction: TextInputAction.go,
                          onSubmitted: (_) => _connect(),
                        ),
                      ),
                    ],
                  ),
                  StickerButton(label: 'Connect', kind: ButtonKind.primary, onPressed: _connect),
                ],
                1 => [
                  Text('Plug into the PC with USB debugging on, and open USB ADB in Lenny Desktop.', style: muted),
                  StickerButton(label: 'Connect over USB', kind: ButtonKind.primary, onPressed: _connectUsb),
                ],
                2 => [
                  Text('Turn on USB tethering (Settings → Hotspot & tethering), then search.', style: muted),
                  StickerButton(
                    label: 'Find PC over USB',
                    icon: Icons.usb_rounded,
                    onPressed: s.searching ? null : ctl.findPcs,
                  ),
                ],
                _ => <Widget>[],
              },
            ];
            final connection = StickerCard(
              label: 'Connection',
              children: s.active
                  ? [StickerButton(label: 'Disconnect', kind: ButtonKind.destructive, onPressed: ctl.disconnect)]
                  : [...quick, ...other],
            );
            final lensTorch = [
              if (s.caps.hasLenses) LensPicker(caps: s.caps, controls: s.controls, onCommand: ctl.command),
              if (s.caps.hasTorch) TorchRow(controls: s.controls, onCommand: ctl.command),
            ];
            // The phone shows no preview, so tap-to-focus happens on the PC.
            Widget mode({String? title}) => ModeControls(
              caps: s.caps,
              controls: s.controls,
              onCommand: ctl.command,
              tapHint: 'Tap the PC preview to focus.',
              exposureTitle: title,
            );
            const gap = SizedBox(height: 12);
            Widget column(List<Widget> children) => ListView(padding: const EdgeInsets.all(16), children: children);
            // Landscape: side by side, so nothing scrolls on a phone held sideways.
            if (o == Orientation.landscape && !s.active) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // No wordmark here: on a short landscape screen it pushes the found PCs off screen.
                  Expanded(child: column([hero, gap, StickerCard(label: 'Find your PC', children: quick)])),
                  Expanded(
                    child: column([StickerCard(label: 'Other ways', children: other)]),
                  ),
                ],
              );
            }
            if (o == Orientation.landscape) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 4, child: column([hero, gap, connection])),
                  if (streaming) ...[
                    if (lensTorch.isNotEmpty)
                      Expanded(
                        flex: 4,
                        child: column([StickerCard(label: 'Camera', children: lensTorch)]),
                      ),
                    Expanded(
                      flex: 5,
                      child: column([
                        StickerCard(label: 'Focus & exposure', children: [mode()]),
                      ]),
                    ),
                  ],
                ],
              );
            }
            final camera = streaming
                ? StickerCard(
                    label: 'Camera',
                    children: [
                      ...lensTorch,
                      mode(title: 'Exposure'),
                    ],
                  )
                : null;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: column([
                  title,
                  const SizedBox(height: 12),
                  hero,
                  gap,
                  connection,
                  if (camera != null) ...[gap, camera],
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.state, this.compact = false});
  final SenderState state;
  final bool compact; // landscape: a narrower column, so a smaller heading that doesn't break mid-word

  @override
  Widget build(BuildContext context) {
    final s = state;
    final sub =
        s.error ??
        (s.link == LinkState.streaming && s.lastHost != null ? 'to ${s.lastHost} · port ${s.lastPort}' : null);
    return Sticker(
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 22, vertical: compact ? 16 : 20),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            StatusDot(color: linkColor(s.link, error: s.error != null), size: compact ? 20 : 28),
            SizedBox(width: compact ? 12 : 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(statusText(s.link, s.reason, sender: true), style: LennyTokens.heading(compact ? 20 : 26)),
                  if (sub != null) ...[
                    const SizedBox(height: 4),
                    // Errors are sentences; the address is a technical value.
                    Text(
                      sub,
                      style: s.error != null
                          ? LennyTokens.body()
                          : LennyTokens.mono(size: 14, color: LennyTokens.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FoundPc extends StatelessWidget {
  const _FoundPc({required this.pc, required this.onTap});
  final PcLink pc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = pc.name.isEmpty ? pc.hosts.first : pc.name;
    return PressableSticker(
      onPressed: onTap,
      semanticLabel: 'Connect to $name',
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.computer_rounded, size: 22, color: LennyTokens.text),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: LennyTokens.button(), overflow: TextOverflow.ellipsis),
                Text('${pc.hosts.first}:${pc.port}', style: LennyTokens.mono(size: 13, color: LennyTokens.textMuted)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: LennyTokens.textMuted),
        ],
      ),
    );
  }
}
