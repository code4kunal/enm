import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Paints a dashed rounded-rect border. Used by empty states and the photo
/// attach dropzone, both of which the design draws with `border: dashed`.
class DashedBorder extends StatelessWidget {
  const DashedBorder({
    super.key,
    required this.child,
    this.color = T.inputBorder,
    this.radius = 12,
    this.strokeWidth = 1.5,
    this.dash = 6,
    this.gap = 4,
    this.fill,
  });

  final Widget child;
  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRectPainter(
        color: color,
        radius: radius,
        strokeWidth: strokeWidth,
        dash: dash,
        gap: gap,
        fill: fill,
      ),
      child: child,
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  const _DashedRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dash,
    required this.gap,
    required this.fill,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dash;
  final double gap;
  final Color? fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );

    if (fill != null) {
      canvas.drawRRect(rect, Paint()..color = fill!);
    }

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // Walk the rounded-rect outline, alternating dash and gap segments.
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) =>
      old.color != color ||
      old.fill != fill ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.dash != dash ||
      old.gap != gap;
}

/// Dashed-border "nothing here" panel.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DashedBorder(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        alignment: Alignment.center,
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: AppText.sans(size: 14, color: T.muted),
        ),
      ),
    );
  }
}

/// Photo attach toggle on the entry form. Turns green-tinted once attached.
///
/// The prototype only simulates attachment; wire this to `image_picker` when
/// the media service lands — the toggle contract stays the same.
class PhotoAttachButton extends StatefulWidget {
  const PhotoAttachButton({
    super.key,
    required this.attached,
    required this.onToggle,
  });

  final bool attached;
  final VoidCallback onToggle;

  @override
  State<PhotoAttachButton> createState() => _PhotoAttachButtonState();
}

class _PhotoAttachButtonState extends State<PhotoAttachButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final attached = widget.attached;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onToggle,
        child: DashedBorder(
          radius: 10,
          color: _hovered ? T.green : T.dashed,
          fill: attached ? T.greenTint : T.dropzoneFill,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: T.minTouchTarget),
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
            alignment: Alignment.center,
            child: Text(
              attached
                  ? '1 photo attached ✓ (tap to remove)'
                  : '+ Attach photo (optional)',
              textAlign: TextAlign.center,
              style: AppText.sans(
                size: 14.5,
                weight: FontWeight.w600,
                color: attached ? T.greenInk : T.secondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
