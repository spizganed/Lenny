import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand.dart';
import '../../core_bindings/lenny_bindings.dart';
import '../../services/core_session.dart';
import '../../services/pc_link.dart';
import '../../state/providers.dart';
import '../../state/status_text.dart';
import '../../theme/lenny_tokens.dart';
import '../components/camera_controls.dart';
import '../components/sticker.dart';

/// Phone home (design.md §6): status hero → connection card → camera card. Single column.
class SenderScreen extends ConsumerStatefulWidget {
  const SenderScreen({super.key});

  @override
  ConsumerState<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends ConsumerState<SenderScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '${Brand.defaultPort}');

  @override
  void initState() {
    super.initState();
    // Prefill with the last PC that streamed, once it's loaded (unless the user already typed something).
    ref.listenManual(senderProvider.select((s) => (s.lastHost, s.lastPort)), (_, last) {
      if (last.$1 != null && _host.text.isEmpty) _host.text = last.$1!;
      if (last.$2 != null && _port.text == '${Brand.defaultPort}') _port.text = '${last.$2}';
    }, fireImmediately: true);
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
      body: DotBackground(
        spacing: 22,
        child: SafeArea(
          child: OrientationBuilder(builder: (context, o) {
            final title = Text(Brand.appName, style: LennyTokens.wordmark(32));
            final hero = _StatusHero(state: s);
            // While connected the hero already shows where to; the fields only matter before connecting.
            final connection = StickerCard(label: 'Connection', children: [
                  if (!s.active) StickerField(
                    label: 'PC address',
                    controller: _host,
                    enabled: !s.active,
                    hint: '192.168.x.x',
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                  ),
                  if (!s.active) StickerField(
                    label: 'Port',
                    controller: _port,
                    enabled: !s.active,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _connect(),
                  ),
                  s.active
                      ? StickerButton(label: 'Disconnect', kind: ButtonKind.destructive, onPressed: ctl.disconnect)
                      : StickerButton(label: 'Connect', kind: ButtonKind.primary, onPressed: _connect),
                  if (!s.active) ...[
                    Row(children: [
                      Expanded(
                        child: StickerButton(
                          label: 'Scan QR',
                          icon: Icons.qr_code_scanner_rounded,
                          onPressed: ctl.scanAndConnect,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: StickerButton(
                          label: s.searching ? 'Searching…' : 'Find PCs',
                          icon: Icons.wifi_find_rounded,
                          onPressed: s.searching ? null : ctl.findPcs,
                        ),
                      ),
                    ]),
                    if (s.found case final found?)
                      if (found.isEmpty)
                        Text(
                          'No Lenny Desktop answered. Is it open and on the same Wi-Fi?',
                          style: LennyTokens.body(color: LennyTokens.textMuted),
                        )
                      else
                        for (final pc in found) _FoundPc(pc: pc, onTap: () => _connectTo(pc)),
                  ],
                ]);
            final camera = !streaming
                ? null
                : StickerCard(label: 'Camera', children: [
                    if (s.caps.hasLenses) LensPicker(caps: s.caps, controls: s.controls, onCommand: ctl.command),
                    FocusButtons(caps: s.caps, controls: s.controls, onCommand: ctl.command),
                    if (s.caps.hasTorch) TorchRow(controls: s.controls, onCommand: ctl.command),
                    if (s.caps.hasExposure)
                      ExposureSlider(caps: s.caps, controls: s.controls, onCommand: ctl.command, title: 'Exposure'),
                    if (s.caps.has(LENNY_CAP_EXPOSURE_LOCK))
                      ExposureLockToggle(controls: s.controls, onCommand: ctl.command),
                  ]);
            const gap = SizedBox(height: 12);
            Widget column(List<Widget> children) => ListView(padding: const EdgeInsets.all(16), children: children);
            // Landscape: status + connection left, camera controls right, instead of one thin centered strip.
            if (o == Orientation.landscape) {
              return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: column([title, gap, hero, gap, connection])),
                if (camera != null) Expanded(child: column([camera])),
              ]);
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: column([title, const SizedBox(height: 12), hero, gap, connection, if (camera != null) ...[gap, camera]]),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.state});
  final SenderState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final sub = s.error ??
        (s.link == LinkState.streaming && s.lastHost != null ? 'to ${s.lastHost} · port ${s.lastPort}' : null);
    return Sticker(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
      child: Semantics(
        liveRegion: true,
        child: Row(children: [
          StatusDot(color: linkColor(s.link, error: s.error != null), size: 28),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(statusText(s.link, s.reason, sender: true), style: LennyTokens.heading(26)),
              if (sub != null) ...[
                const SizedBox(height: 4),
                // Errors are sentences; the address is a technical value.
                Text(sub, style: s.error != null ? LennyTokens.body() : LennyTokens.mono(size: 14, color: LennyTokens.textMuted)),
              ],
            ]),
          ),
        ]),
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
      child: Row(children: [
        const Icon(Icons.computer_rounded, size: 22, color: LennyTokens.text),
        const SizedBox(width: 14),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: LennyTokens.button(), overflow: TextOverflow.ellipsis),
            Text('${pc.hosts.first}:${pc.port}', style: LennyTokens.mono(size: 13, color: LennyTokens.textMuted)),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: LennyTokens.textMuted),
      ]),
    );
  }
}
