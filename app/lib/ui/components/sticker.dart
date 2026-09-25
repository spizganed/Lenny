import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/core_session.dart';
import '../../theme/lenny_tokens.dart';

typedef _T = LennyTokens;

BoxDecoration stickerBox(Color fill, double radius, double shadow) => BoxDecoration(
      color: fill,
      border: Border.all(color: _T.ink, width: _T.border),
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [if (shadow > 0) BoxShadow(color: _T.ink, offset: Offset(shadow, shadow))],
    );

/// A static sticker: fill, ink outline, hard offset shadow (design.md §2).
class Sticker extends StatelessWidget {
  const Sticker({
    super.key,
    required this.child,
    this.fill = _T.surface,
    this.radius = _T.radiusCard,
    this.shadow = _T.shadowCard,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final Color fill;
  final double radius, shadow;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) =>
      Container(decoration: stickerBox(fill, radius, shadow), padding: padding, child: child);
}

/// A sticker that sinks into its shadow while pressed. [onPressed] null = disabled: `well` fill, no shadow.
class PressableSticker extends StatefulWidget {
  const PressableSticker({
    super.key,
    required this.child,
    required this.onPressed,
    required this.semanticLabel,
    this.fill = _T.well,
    this.radius = _T.radiusButton,
    this.shadow = _T.shadowButton,
    this.padding = const EdgeInsets.symmetric(horizontal: 18),
    this.height = 52,
    this.selected,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final String semanticLabel;
  final Color fill;
  final double radius, shadow;
  final EdgeInsetsGeometry padding;
  final double? height;
  final bool? selected; // toggles: announced as on/off

  @override
  State<PressableSticker> createState() => _PressableStickerState();
}

class _PressableStickerState extends State<PressableSticker> {
  bool _down = false;
  bool _focused = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final sink = enabled && _down ? widget.shadow : 0.0;
    return Semantics(
      button: true,
      enabled: enabled,
      toggled: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: (f) => setState(() => _focused = f),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onPressed?.call())},
        child: GestureDetector(
          onTapDown: enabled ? (_) => _set(true) : null,
          onTapUp: enabled ? (_) => _set(false) : null,
          onTapCancel: () => _set(false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            curve: Curves.easeOut,
            height: widget.height,
            padding: widget.padding,
            transform: Matrix4.translationValues(sink, sink, 0),
            decoration: stickerBox(
              enabled ? widget.fill : _T.well,
              widget.radius,
              enabled ? widget.shadow - sink : 0,
            ).copyWith(
              // Keyboard focus: cream outline, visible on every fill.
              border: Border.all(color: _focused ? _T.text : _T.ink, width: _T.border),
            ),
            // widthFactor 1: shrink-wraps where width is free (header chips), centres where it's tight (buttons).
            child: Align(
              widthFactor: 1,
              child: DefaultTextStyle.merge(
                style: enabled ? null : const TextStyle(color: _T.textMuted),
                child: IconTheme.merge(
                  data: enabled ? const IconThemeData() : const IconThemeData(color: _T.textMuted),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum ButtonKind { primary, destructive, neutral }

/// Primary (yellow), destructive (coral) or neutral button with an optional leading icon.
class StickerButton extends StatelessWidget {
  const StickerButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = ButtonKind.neutral,
    this.icon,
    this.onPage = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final ButtonKind kind;
  final IconData? icon;
  final bool onPage; // neutral on the page = surface; inside a card = well

  @override
  Widget build(BuildContext context) {
    final (fill, fg, shadow) = switch (kind) {
      ButtonKind.primary => (_T.yellow, _T.ink, _T.shadowPrimary),
      ButtonKind.destructive => (_T.coral, _T.ink, _T.shadowPrimary),
      ButtonKind.neutral => (onPage ? _T.surface : _T.well, _T.text, _T.shadowButton),
    };
    final color = onPressed == null ? _T.textMuted : fg;
    return PressableSticker(
      onPressed: onPressed,
      semanticLabel: label,
      fill: fill,
      shadow: shadow,
      height: kind == ButtonKind.neutral ? 52 : 56,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 20, color: color), const SizedBox(width: 10)],
        Flexible(child: Text(label, style: _T.button(color), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

/// Toggle button (Auto, Lock focus): `well` when off, `mint` + check when on.
class ToggleSticker extends StatelessWidget {
  const ToggleSticker({super.key, required this.label, required this.on, required this.onPressed});
  final String label;
  final bool on;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final fg = on ? _T.ink : _T.text;
    return PressableSticker(
      onPressed: onPressed,
      semanticLabel: label,
      selected: on,
      fill: on ? _T.mint : _T.well,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (on) ...[Icon(Icons.check_rounded, size: 20, color: fg), const SizedBox(width: 8)],
        Flexible(child: Text(label, style: _T.button(fg), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }
}

/// Pill switch (Torch): `well` track + knob left when off, `mint` + knob right when on.
class StickerSwitch extends StatelessWidget {
  const StickerSwitch({super.key, required this.value, required this.onChanged, required this.semanticLabel});
  final bool value;
  final ValueChanged<bool> onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
        toggled: value,
        label: semanticLabel,
        excludeSemantics: true,
        onTap: () => onChanged(!value),
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => onChanged(!value))},
          child: GestureDetector(
            onTap: () => onChanged(!value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 68,
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: stickerBox(value ? _T.mint : _T.well, _T.radiusPill, _T.shadowSmall),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 120),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: _T.text,
                    shape: BoxShape.circle,
                    border: Border.all(color: _T.ink, width: _T.border),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Segmented pill (lenses): selected segment `mint`, others `well`, 3px ink dividers.
class Segmented extends StatelessWidget {
  const Segmented({super.key, required this.labels, required this.selected, required this.onSelect, this.height = 52});
  final List<String> labels;
  final int selected; // -1 = none (e.g. the current mode isn't in the list)
  final ValueChanged<int> onSelect;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: stickerBox(_T.well, _T.radiusPill, _T.shadowButton),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_T.radiusPill),
          child: Row(children: [
            for (var i = 0; i < labels.length; i++) ...[
              if (i > 0) const VerticalDivider(width: _T.border, thickness: _T.border, color: _T.ink),
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == selected,
                  label: labels[i],
                  excludeSemantics: true,
                  child: FocusableActionDetector(
                    mouseCursor: SystemMouseCursors.click,
                    actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => onSelect(i))},
                    child: GestureDetector(
                      onTap: () => onSelect(i),
                      child: ColoredBox(
                        color: i == selected ? _T.mint : _T.well,
                        child: Center(
                          child: Text(labels[i], style: _T.button(i == selected ? _T.ink : _T.text), maxLines: 1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ]),
        ),
      );
}

/// Label + `well` input. Monospace, since everything typed here is an address or a port.
class StickerField extends StatefulWidget {
  const StickerField({
    super.key,
    required this.label,
    required this.controller,
    this.enabled = true,
    this.hint,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
  });
  final String label;
  final TextEditingController controller;
  final bool enabled;
  final String? hint;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  @override
  State<StickerField> createState() => _StickerFieldState();
}

class _StickerFieldState extends State<StickerField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.label, style: _T.body(size: 14, weight: FontWeight.w700)),
        const SizedBox(height: 8),
        Focus(
          onFocusChange: (f) => setState(() => _focused = f),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
            decoration: stickerBox(
              _T.well,
              _T.radiusInput,
              !widget.enabled ? 0 : (_focused ? _T.shadowButton : _T.shadowSmall),
            ),
            child: TextField(
              controller: widget.controller,
              enabled: widget.enabled,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              onSubmitted: widget.onSubmitted,
              style: _T.mono(size: 17, color: widget.enabled ? _T.text : _T.textMuted),
              decoration: InputDecoration.collapsed(
                hintText: widget.hint,
                hintStyle: _T.mono(size: 17, color: _T.textFaint),
              ),
            ),
          ),
        ),
      ]);
}

/// Card with a mono section label (design.md §4 Card).
class StickerCard extends StatelessWidget {
  const StickerCard({super.key, required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Sticker(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label.toUpperCase(), style: _T.label()),
          for (final c in children) ...[const SizedBox(height: 14), c],
        ]),
      );
}

/// Status dot color: green live, lilac waiting, coral stopped/failed, muted when idle.
Color linkColor(LinkState link, {bool error = false}) => error
    ? _T.coral
    : switch (link) {
        LinkState.streaming => _T.green,
        LinkState.closed => _T.coral,
        LinkState.idle => _T.textMuted,
        _ => _T.lilac,
      };

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 14});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: _T.ink, width: _T.border)),
      );
}

/// Pill with a status dot. The label says the same as the dot, so state is never color-only.
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: stickerBox(_T.surface, _T.radiusPill, _T.shadowSmall),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            StatusDot(color: color),
            const SizedBox(width: 10),
            Flexible(child: Text(text, style: _T.button(), overflow: TextOverflow.ellipsis)),
          ]),
        ),
      );
}

/// Small mono pill: LIVE badge, platform tag, lens badge.
class StickerBadge extends StatelessWidget {
  const StickerBadge({super.key, required this.text, this.fill = _T.surface, this.dot = false});
  final String text;
  final Color fill;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final fg = fill == _T.surface ? _T.text : _T.ink;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: stickerBox(fill, _T.radiusPill, _T.shadowSmall),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot) ...[
          Container(width: 8, height: 8, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
          const SizedBox(width: 8),
        ],
        Text(text, style: _T.mono(size: 13, weight: FontWeight.w700, color: fg)),
      ]),
    );
  }
}

/// Stat tile inside a card: outline only, no shadow.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: stickerBox(_T.well, _T.radiusTile, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: _T.body(size: 12, color: _T.textMuted)),
          const SizedBox(height: 2),
          Text(value, style: _T.mono(size: 18, weight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}

/// Header chip that copies [value]; the icon flips to a check for a moment.
class CopyChip extends StatefulWidget {
  const CopyChip({super.key, required this.value, this.prefix});
  final String value;
  final String? prefix; // shown muted before the value, e.g. "port"

  @override
  State<CopyChip> createState() => _CopyChipState();
}

class _CopyChipState extends State<CopyChip> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.value));
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1200), () => setState(() => _copied = false));
  }

  @override
  Widget build(BuildContext context) => PressableSticker(
        onPressed: _copy,
        semanticLabel: 'Copy ${widget.prefix ?? ''} ${widget.value}',
        fill: _T.surface,
        radius: _T.radiusChipSmall,
        shadow: _T.shadowSmall,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (widget.prefix != null) Text('${widget.prefix}  ', style: _T.mono(size: 14, color: _T.textMuted)),
          Text(widget.value, style: _T.mono(size: 14, weight: FontWeight.w700)),
          const SizedBox(width: 10),
          Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 18, color: _T.text),
        ]),
      );
}

/// Flat ink scrim + sticker dialog (design.md §4 Menus, sheets, dialogs).
Future<R?> showStickerDialog<R>(BuildContext context, WidgetBuilder builder) => showGeneralDialog<R>(
      context: context,
      barrierDismissible: false,
      barrierColor: _T.ink.withValues(alpha: 0.6),
      transitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (ctx, _, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Material(
              type: MaterialType.transparency,
              child: Sticker(shadow: _T.shadowHero, padding: const EdgeInsets.all(24), child: builder(ctx)),
            ),
          ),
        ),
      ),
    );
