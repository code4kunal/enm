import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The coloured rounded square carrying a register's two-letter code.
///
/// Three sizes are in use: 44 on the form header, 40 on Home's register cards,
/// 34 on entry rows.
class CodeSquare extends StatelessWidget {
  const CodeSquare({
    super.key,
    required this.code,
    required this.color,
    this.size = 40,
  });

  final String code;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Radius and type scale track the square size across the three variants.
    final radius = size >= 44
        ? 12.0
        : size >= 40
            ? 11.0
            : 9.0;
    final fontSize = size >= 44
        ? 15.0
        : size >= 40
            ? 13.5
            : 11.5;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        code,
        style: AppText.mono(
          size: fontSize,
          weight: FontWeight.w700,
          color: T.white,
        ),
      ),
    );
  }
}

/// Compact solid-colour register tag used on the Registers result rows.
class CodeTag extends StatelessWidget {
  const CodeTag({super.key, required this.code, required this.color});

  final String code;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        code,
        style: AppText.mono(
          size: 11.5,
          weight: FontWeight.w700,
          color: T.white,
        ),
      ),
    );
  }
}

/// Circular avatar showing user initials. Greys out when [active] is false.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.initials,
    this.size = 38,
    this.active = true,
  });

  final String initials;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? T.ink : T.border,
        shape: BoxShape.circle,
      ),
      child: Text(
        initials,
        style: AppText.sans(
          size: 13,
          weight: FontWeight.w700,
          color: active ? T.white : T.muted,
        ),
      ),
    );
  }
}
