import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Filled button. Defaults to the brand green primary action; pass [background]
/// / [hoverBackground] for the ink and red variants.
class FilledActionButton extends StatelessWidget {
  const FilledActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.background = T.green,
    this.hoverBackground = T.greenHover,
    this.foreground = T.white,
    this.fontSize = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
    this.elevated = false,
    this.expand = false,
    this.child,
  });

  /// The dark "Sign in" / "Export Excel (CSV)" variant.
  const FilledActionButton.ink({
    super.key,
    required this.label,
    required this.onPressed,
    this.fontSize = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
    this.expand = false,
    this.child,
  })  : background = T.ink,
        hoverBackground = T.inkHover,
        foreground = T.white,
        elevated = false;

  /// The destructive "+ Report breakdown" variant.
  const FilledActionButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.fontSize = 14,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    this.expand = false,
    this.child,
  })  : background = T.red,
        hoverBackground = T.redHover,
        foreground = T.white,
        elevated = false;

  final String label;
  final VoidCallback? onPressed;
  final Color background;
  final Color hoverBackground;
  final Color foreground;
  final double fontSize;
  final EdgeInsets padding;

  /// Adds the green CTA drop shadow.
  final bool elevated;
  final bool expand;

  /// Replaces the label text — used for the Microsoft button's icon + label row.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final button = _HoverFill(
      base: background,
      hover: hoverBackground,
      borderRadius: T.buttonShape,
      onTap: onPressed,
      shadows: elevated ? T.ctaShadow : null,
      child: Container(
        constraints: const BoxConstraints(minHeight: T.minTouchTarget),
        padding: padding,
        // Align with unit factors keeps the button content-sized in a Row or
        // Wrap, while still centring the label when `expand` forces full width.
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: child ??
              Text(
                label,
                textAlign: TextAlign.center,
                style: AppText.sans(
                  size: fontSize,
                  weight: FontWeight.w700,
                  color: foreground,
                ),
              ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Outlined button. [accent] recolours the border and label on hover — the
/// pattern used by "Edit" (green) and "Mark resolved".
class OutlineActionButton extends StatelessWidget {
  const OutlineActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.foreground = T.body,
    this.borderColor = T.inputBorder,
    this.accent,
    this.hoverFill,
    this.fontSize = 16,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
  });

  final String label;
  final VoidCallback? onPressed;
  final Color foreground;
  final Color borderColor;

  /// Colour the border and text take on hover.
  final Color? accent;

  /// Optional hover background fill.
  final Color? hoverFill;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      onTap: onPressed,
      builder: (context, hovered) {
        final active = hovered && accent != null;
        return Container(
          constraints: const BoxConstraints(minHeight: T.minTouchTarget),
          padding: padding,
          decoration: BoxDecoration(
            color: hovered ? (hoverFill ?? T.card) : T.card,
            borderRadius: T.controlShape,
            border: Border.all(
              color: active ? accent! : borderColor,
              width: 1.5,
            ),
          ),
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              style: AppText.sans(
                size: fontSize,
                weight: FontWeight.w700,
                color: active ? accent! : foreground,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Back affordance above the entry form.
class BackLink extends StatelessWidget {
  const BackLink({super.key, required this.onTap, this.label = 'Back'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: Text(
            '← $label',
            style: AppText.sans(
              size: 14,
              weight: FontWeight.w600,
              color: T.secondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Tracks hover state and hands it to a builder.
class _Hoverable extends StatefulWidget {
  const _Hoverable({required this.builder, required this.onTap});

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: GestureDetector(
          onTap: widget.onTap,
          child: widget.builder(context, enabled && _hovered),
        ),
      ),
    );
  }
}

/// Solid fill that crossfades to [hover] on pointer-over.
class _HoverFill extends StatelessWidget {
  const _HoverFill({
    required this.base,
    required this.hover,
    required this.borderRadius,
    required this.onTap,
    required this.child,
    this.shadows,
  });

  final Color base;
  final Color hover;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;
  final Widget child;
  final List<BoxShadow>? shadows;

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      onTap: onTap,
      builder: (context, hovered) => AnimatedContainer(
        duration: T.hoverLift,
        curve: T.easeOut,
        decoration: BoxDecoration(
          color: hovered ? hover : base,
          borderRadius: borderRadius,
          boxShadow: shadows,
        ),
        child: child,
      ),
    );
  }
}

/// Card-like surface that lifts 2px with a shadow on hover, used by the Home
/// register cards.
class LiftOnHover extends StatefulWidget {
  const LiftOnHover({super.key, required this.child, required this.onTap});

  final Widget Function(BuildContext context, bool hovered) child;
  final VoidCallback onTap;

  @override
  State<LiftOnHover> createState() => _LiftOnHoverState();
}

class _LiftOnHoverState extends State<LiftOnHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: T.hoverLift,
          curve: T.easeOut,
          transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
          child: widget.child(context, _hovered),
        ),
      ),
    );
  }
}
