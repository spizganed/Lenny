import 'package:flutter/material.dart';

import '../../core_bindings/lenny_bindings.dart';
import '../../state/camera.dart';

/// Quick camera controls, shared by the phone (local) and the desktop (remote). Shows only what the camera supports.
/// Everything is an opt-in overlay on top of Auto; "Auto" puts it all back.
class CameraControlsBar extends StatefulWidget {
  const CameraControlsBar({super.key, required this.caps, required this.controls, required this.onCommand});

  final CameraCaps caps;
  final CameraControls controls;
  final ValueChanged<CameraCommand> onCommand;

  @override
  State<CameraControlsBar> createState() => _CameraControlsBarState();
}

class _CameraControlsBarState extends State<CameraControlsBar> {
  double? _dragEv; // while the slider is held; the command goes out on release

  @override
  Widget build(BuildContext context) {
    final caps = widget.caps;
    final c = widget.controls;
    final exposure = caps.exposure;
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      FilledButton.tonal(
        onPressed: c.isAuto ? null : () => widget.onCommand(Commands.auto),
        child: const Text('Auto'),
      ),
      if (caps.has(LENNY_CAP_FOCUS_LOCK))
        FilterChip(
          label: const Text('Lock focus'),
          selected: c.focusLocked,
          onSelected: (on) => widget.onCommand(Commands.focusLock(on)),
        ),
      if (caps.has(LENNY_CAP_TORCH))
        FilterChip(
          label: const Text('Torch'),
          selected: c.torch,
          onSelected: (on) => widget.onCommand(Commands.torch(on)),
        ),
      if (caps.has(LENNY_CAP_LENS) && caps.lenses.length > 1)
        SegmentedButton<int>(
          segments: [
            for (var i = 0; i < caps.lenses.length; i++) ButtonSegment(value: i, label: Text(caps.lenses[i])),
          ],
          selected: {c.lens.clamp(0, caps.lenses.length - 1)},
          onSelectionChanged: (s) => widget.onCommand(Commands.lens(s.first)),
          showSelectedIcon: false,
        ),
      if (caps.has(LENNY_CAP_EXPOSURE_COMP) && exposure != null && exposure.max > exposure.min)
        SizedBox(
          width: 260,
          child: Row(children: [
            const Text('Exposure'),
            Expanded(
              child: Slider(
                min: exposure.min.toDouble(),
                max: exposure.max.toDouble(),
                divisions: exposure.step > 0 ? ((exposure.max - exposure.min) / exposure.step).round() : null,
                value: (_dragEv ?? c.exposureEvMilli.toDouble()).clamp(exposure.min.toDouble(), exposure.max.toDouble()),
                label: _evLabel((_dragEv ?? c.exposureEvMilli.toDouble()).round()),
                semanticFormatterCallback: (v) => 'Exposure ${_evLabel(v.round())}',
                onChanged: (v) => setState(() => _dragEv = v),
                onChangeEnd: (v) {
                  setState(() => _dragEv = null);
                  widget.onCommand(Commands.exposure(v.round()));
                },
              ),
            ),
          ]),
        ),
    ]);
  }

  static String _evLabel(int evMilli) {
    final ev = evMilli / 1000;
    return '${ev > 0 ? '+' : ''}${ev.toStringAsFixed(1)} EV';
  }
}
