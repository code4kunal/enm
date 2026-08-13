import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// The `fadeUp` entry animation the prototype plays on every view change:
/// 24px rise + fade, `cubic-bezier(.2,.8,.2,1)`.
///
/// Give it a [key] that changes when the view changes so it replays.
class FadeUp extends StatefulWidget {
  const FadeUp({
    super.key,
    required this.child,
    this.duration = T.viewFade,
    this.offset = 24,
  });

  final Widget child;
  final Duration duration;
  final double offset;

  @override
  State<FadeUp> createState() => _FadeUpState();
}

class _FadeUpState extends State<FadeUp> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward();

  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: T.easeOut,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - _t.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}
