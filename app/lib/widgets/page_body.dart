import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The scrolling frame every screen sits in: centred, width-capped, padded.
///
/// This has to wrap each *page*, not the shell. The shell's child is the
/// `ShellRoute`'s Navigator, and a Navigator cannot lay out against an
/// unbounded height — put one inside a scroll view and it collapses to an
/// arbitrary box, so every screen taller than that box overflows instead of
/// scrolling, which is what used to happen here.
class PageBody extends StatelessWidget {
  const PageBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < T.mobileBreakpoint;

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.maxContentWidth),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              // Clear the fixed bottom nav on mobile.
              isMobile ? 96 : 32,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
