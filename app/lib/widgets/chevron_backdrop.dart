import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The login screen's animated backdrop: three blurred brand chevrons drifting
/// slowly over the dark ground.
///
/// The chevron matches the prototype's clip-path
/// `polygon(0 0, 55% 0, 100% 50%, 55% 100%, 0 100%, 45% 50%)`.
class ChevronBackdrop extends StatefulWidget {
  const ChevronBackdrop({super.key});

  @override
  State<ChevronBackdrop> createState() => _ChevronBackdropState();
}

class _ChevronBackdropState extends State<ChevronBackdrop>
    with TickerProviderStateMixin {
  // Three independent loops at the prototype's 11s / 13s / 16s periods.
  late final AnimationController _a = _loop(11);
  late final AnimationController _b = _loop(13);
  late final AnimationController _c = _loop(16);

  AnimationController _loop(int seconds) => AnimationController(
        vsync: this,
        duration: Duration(seconds: seconds),
      )..repeat(reverse: true);

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return RepaintBoundary(
      child: ClipRect(
        child: Stack(
          children: <Widget>[
            // drift1: translate(60, -40) + 4deg rotation.
            _Drifter(
              animation: _a,
              from: Offset.zero,
              to: const Offset(60, -40),
              rotationTurns: 4 / 360,
              left: -80,
              top: -60,
              child: const _Chevron(
                size: Size(420, 420),
                color: T.green,
                opacity: 0.14,
              ),
            ),
            // drift2: translate(-70, 50).
            _Drifter(
              animation: _b,
              from: Offset.zero,
              to: const Offset(-70, 50),
              right: -140,
              bottom: -120,
              child: const _Chevron(
                size: Size(520, 520),
                color: T.blue,
                opacity: 0.13,
              ),
            ),
            _Drifter(
              animation: _c,
              from: Offset.zero,
              to: const Offset(-70, 50),
              right: size.width * 0.18,
              top: size.height * 0.08,
              child: const _Chevron(
                size: Size(220, 220),
                color: T.green,
                opacity: 0.08,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Drifter extends StatelessWidget {
  const _Drifter({
    required this.animation,
    required this.from,
    required this.to,
    required this.child,
    this.rotationTurns = 0,
    this.left,
    this.top,
    this.right,
    this.bottom,
  });

  final Animation<double> animation;
  final Offset from;
  final Offset to;
  final double rotationTurns;
  final Widget child;
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      child: AnimatedBuilder(
        animation: curved,
        builder: (context, inner) {
          final t = curved.value;
          return Transform.translate(
            offset: Offset.lerp(from, to, t)!,
            child: Transform.rotate(
              angle: rotationTurns * 2 * math.pi * t,
              child: inner,
            ),
          );
        },
        child: child,
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({
    required this.size,
    required this.color,
    required this.opacity,
  });

  final Size size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: ImageFiltered(
        // Matches the prototype's 6px blur on the shapes.
        imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: CustomPaint(
          size: size,
          painter: _ChevronPainter(color),
        ),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(w * 0.55, 0)
      ..lineTo(w, h * 0.5)
      ..lineTo(w * 0.55, h)
      ..lineTo(0, h)
      ..lineTo(w * 0.45, h * 0.5)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}
