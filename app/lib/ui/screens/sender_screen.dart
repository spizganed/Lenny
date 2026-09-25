import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../brand.dart';
import '../../state/providers.dart';
import '../../state/status_text.dart';
import '../../services/core_session.dart';
import '../components/camera_controls.dart';
import '../components/mascot_slot.dart';
import '../components/status_line.dart';

/// Phone home screen. ponytail: plain connect form. The ConnectionControl pill + drawer, QR scan and on-phone
/// preview arrive in later milestones (preview M3, control + QR M5/M6).
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

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(senderProvider);
    return Scaffold(
      appBar: AppBar(title: const Text(Brand.appName)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              const Center(child: MascotSlot()),
              const SizedBox(height: 16),
              Center(child: StatusLine(link: s.link, text: s.error ?? statusText(s.link, s.reason, sender: true))),
              const SizedBox(height: 24),
              TextField(
                controller: _host,
                enabled: !s.active,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'PC address', hintText: 'e.g. 192.168.1.20'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _port,
                enabled: !s.active,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _connect(),
                decoration: const InputDecoration(labelText: 'Port'),
              ),
              const SizedBox(height: 20),
              s.active
                  ? OutlinedButton(
                      onPressed: () => ref.read(senderProvider.notifier).disconnect(),
                      child: const Text('Disconnect'),
                    )
                  : FilledButton(onPressed: _connect, child: const Text('Connect')),
              if (!s.active) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: ref.read(senderProvider.notifier).scanAndConnect,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR code'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: s.searching ? null : ref.read(senderProvider.notifier).findPcs,
                  icon: const Icon(Icons.wifi_find),
                  label: Text(s.searching ? 'Searching…' : 'Find PCs on this Wi-Fi'),
                ),
                for (final pc in s.found)
                  ListTile(
                    leading: const Icon(Icons.computer),
                    title: Text(pc.name.isEmpty ? pc.hosts.first : pc.name),
                    subtitle: Text('${pc.hosts.first}:${pc.port}'),
                    onTap: () => ref.read(senderProvider.notifier).connect(pc.hosts.first, pc.port),
                  ),
              ],
              if (s.link == LinkState.streaming) ...[
                const SizedBox(height: 24),
                CameraControlsBar(
                  caps: s.caps,
                  controls: s.controls,
                  onCommand: ref.read(senderProvider.notifier).command,
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
