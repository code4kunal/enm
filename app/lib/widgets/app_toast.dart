import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'fade_up.dart';

/// Bottom-centre confirmation pill.
///
/// Sits 84px up on mobile to clear the bottom nav, 24px on desktop.
class AppToast extends ConsumerWidget {
  const AppToast({super.key, required this.isMobile});

  final bool isMobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(toastProvider);
    if (message == null) return const SizedBox.shrink();

    return Positioned(
      left: 16,
      right: 16,
      bottom: isMobile ? 84 : 24,
      child: IgnorePointer(
        child: Center(
          child: FadeUp(
            // Re-keying on the message replays the entry animation for each
            // toast rather than only the first.
            key: ValueKey<String>(message),
            duration: const Duration(milliseconds: 300),
            offset: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
              decoration: const BoxDecoration(
                color: T.ink,
                borderRadius: T.buttonShape,
                boxShadow: T.toastShadow,
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: AppText.sans(
                  size: 14.5,
                  weight: FontWeight.w600,
                  color: T.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
