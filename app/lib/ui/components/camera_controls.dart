import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_bindings/lenny_bindings.dart';
import '../../state/camera.dart';
import '../../theme/lenny_tokens.dart';
import 'sticker.dart';

/// Camera controls shared by the phone (local) and the desktop (remote). Each piece shows only what the camera
/// supports; the screens decide which card holds which piece.
extension CameraCapsUi on CameraCaps {
  bool get hasLenses => has(LENNY_CAP_LENS) && lenses.length > 1;
  bool get hasTorch => has(LENNY_CAP_TORCH);
  bool get hasExposure => has(LENNY_CAP_EXPOSURE_COMP) && exposure != null && exposure!.max > exposure!.min;
}

class LensPicker extends StatelessWidget {
  const LensPicker({super.key, required this.caps, required this.controls, required this.onCommand});
  final CameraCaps caps;
  final CameraControls controls;
  final ValueChanged<CameraCommand> onCommand;

  @override
  Widget build(BuildContext context) => Segmented(
        labels: caps.lenses,
        selected: controls.lens.clamp(0, caps.lenses.length - 1),
        onSelect: (i) => onCommand(Commands.lens(i)),
      );
}

/// Auto (on while everything is automatic; tapping it resets) + Lock focus.
class FocusButtons extends StatelessWidget {
  const FocusButtons({super.key, required this.caps, required this.controls, required this.onCommand});
  final CameraCaps caps;
  final CameraControls controls;
  final ValueChanged<CameraCommand> onCommand;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: ToggleSticker(
            label: 'Auto',
            on: controls.isAuto,
            onPressed: controls.isAuto ? () {} : () => onCommand(Commands.auto),
          ),
        ),
        if (caps.has(LENNY_CAP_FOCUS_LOCK)) ...[
          const SizedBox(width: 12),
          Expanded(
            child: ToggleSticker(
              label: 'Lock focus',
              on: controls.focusLocked,
              onPressed: () => onCommand(Commands.focusLock(!controls.focusLocked)),
            ),
          ),
        ],
      ]);
}

class TorchRow extends StatelessWidget {
  const TorchRow({super.key, required this.controls, required this.onCommand});
  final CameraControls controls;
  final ValueChanged<CameraCommand> onCommand;

  @override
  Widget build(BuildContext context) => Row(children: [
        const Icon(Icons.flash_on_rounded, size: 22, color: LennyTokens.text),
        const SizedBox(width: 12),
        Expanded(child: Text('Torch', style: LennyTokens.button())),
        StickerSwitch(
          value: controls.torch,
          semanticLabel: 'Torch',
          onChanged: (on) => onCommand(Commands.torch(on)),
        ),
      ]);
}

/// Exposure compensation. Dragging only moves the thumb; the command goes out on release (one camera change, not
/// thirty). Arrow keys step it.
class ExposureSlider extends StatefulWidget {
  const ExposureSlider({super.key, required this.caps, required this.controls, required this.onCommand, this.title});
  final CameraCaps caps;
  final CameraControls controls;
  final ValueChanged<CameraCommand> onCommand;
  final String? title; // the phone labels it; the desktop card label already says EXPOSURE

  @override
  State<ExposureSlider> createState() => _ExposureSliderState();
}

class _ExposureSliderState extends State<ExposureSlider> {
  static const _thumb = 34.0;
  double? _drag; // EV*1000 while held

  ({int min, int max, int step}) get _range => widget.caps.exposure!;
  int get _value => (_drag ?? widget.controls.exposureEvMilli.toDouble()).round().clamp(_range.min, _range.max);

  int _snap(double v) {
    final r = _range;
    final step = r.step > 0 ? r.step : 1;
    return (r.min + ((v - r.min) / step).round() * step).clamp(r.min, r.max);
  }

  double _fromX(double x, double width) {
    final r = _range;
    final f = ((x - _thumb / 2) / (width - _thumb)).clamp(0.0, 1.0);
    return r.min + f * (r.max - r.min);
  }

  void _send(int v) {
    setState(() => _drag = null);
    if (v != widget.controls.exposureEvMilli) widget.onCommand(Commands.exposure(v));
  }

  void _stepBy(int dir) {
    final step = _range.step > 0 ? _range.step : 1;
    _send((_value + dir * step).clamp(_range.min, _range.max));
  }

  static String _ev(int evMilli) {
    final ev = evMilli / 1000;
    return '${ev > 0 ? '+' : ''}${ev.toStringAsFixed(1)} EV';
  }

  @override
  Widget build(BuildContext context) {
    final r = _range;
    final f = (_value - r.min) / (r.max - r.min);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: widget.title == null ? const SizedBox() : Text(widget.title!, style: LennyTokens.button())),
        Text(_ev(_value), style: LennyTokens.mono(size: 14, weight: FontWeight.w700, color: LennyTokens.lilac)),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        const Icon(Icons.brightness_low_rounded, size: 16, color: LennyTokens.textMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Semantics(
            slider: true,
            label: 'Exposure',
            value: _ev(_value),
            increasedValue: _ev((_value + r.step).clamp(r.min, r.max)),
            decreasedValue: _ev((_value - r.step).clamp(r.min, r.max)),
            onIncrease: () => _stepBy(1),
            onDecrease: () => _stepBy(-1),
            excludeSemantics: true,
            child: FocusableActionDetector(
              mouseCursor: SystemMouseCursors.click,
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.arrowRight): _Step(1),
                SingleActivator(LogicalKeyboardKey.arrowUp): _Step(1),
                SingleActivator(LogicalKeyboardKey.arrowLeft): _Step(-1),
                SingleActivator(LogicalKeyboardKey.arrowDown): _Step(-1),
              },
              actions: {_Step: CallbackAction<_Step>(onInvoke: (s) => _stepBy(s.dir))},
              child: LayoutBuilder(builder: (context, box) {
                final w = box.maxWidth;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (d) => setState(() => _drag = _fromX(d.localPosition.dx, w)),
                  onHorizontalDragUpdate: (d) => setState(() => _drag = _fromX(d.localPosition.dx, w)),
                  onHorizontalDragEnd: (_) => _send(_snap(_drag ?? _value.toDouble())),
                  onHorizontalDragCancel: () => setState(() => _drag = null),
                  onTapUp: (d) => _send(_snap(_fromX(d.localPosition.dx, w))),
                  child: SizedBox(
                    height: _thumb + LennyTokens.shadowSmall,
                    child: Stack(alignment: Alignment.centerLeft, children: [
                      // Track: hard-edged lilac fill over the well, no blend.
                      Container(
                        height: 22,
                        decoration: stickerBox(LennyTokens.well, LennyTokens.radiusPill, LennyTokens.shadowSmall),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(LennyTokens.radiusPill),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: (f * (w - _thumb) + _thumb / 2) / w,
                            child: const ColoredBox(color: LennyTokens.lilac),
                          ),
                        ),
                      ),
                      Positioned(
                        left: f * (w - _thumb),
                        child: Container(
                          width: _thumb,
                          height: _thumb,
                          decoration: BoxDecoration(
                            color: LennyTokens.text,
                            shape: BoxShape.circle,
                            border: Border.all(color: LennyTokens.ink, width: LennyTokens.border),
                            boxShadow: const [
                              BoxShadow(
                                color: LennyTokens.ink,
                                offset: Offset(LennyTokens.shadowSmall, LennyTokens.shadowSmall),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ]),
                  ),
                );
              }),
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Icon(Icons.brightness_high_rounded, size: 24, color: LennyTokens.textMuted),
      ]),
    ]);
  }
}

class _Step extends Intent {
  const _Step(this.dir);
  final int dir;
}
