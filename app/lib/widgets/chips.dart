import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Visual register a selected chip uses.
enum ChipTone {
  /// Register + user filters: selected is solid black.
  ink,

  /// Period + site chips: selected is a green-tinted pill.
  green,
}

/// Pill-shaped filter chip. Selected state depends on [tone].
class PillChip extends StatelessWidget {
  const PillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.tone = ChipTone.ink,
    this.mono = false,
    this.dense = false,
    this.radius = T.pillShape,
    this.fontSize,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final ChipTone tone;

  /// Site codes and user IDs render in IBM Plex Mono.
  final bool mono;

  /// Period chips sit a touch tighter than register chips.
  final bool dense;

  /// Pill by default; the login site grid uses the 12px control radius.
  final BorderRadius radius;

  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final Color border;

    if (!selected) {
      bg = T.card;
      fg = T.body;
      border = T.inputBorder;
    } else if (tone == ChipTone.ink) {
      bg = T.ink;
      fg = T.white;
      border = T.ink;
    } else {
      bg = T.greenTint;
      fg = T.greenInk;
      border = T.green;
    }

    final size = fontSize ?? (dense ? 13.0 : 13.5);
    final style = mono
        ? AppText.mono(size: size, weight: FontWeight.w600, color: fg)
        : AppText.sans(size: size, weight: FontWeight.w600, color: fg);

    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        // No `alignment` here: a Container with an alignment expands to fill
        // its loose constraints, which would stretch every chip to the full
        // width of the enclosing Wrap.
        child: Container(
          constraints: const BoxConstraints(minHeight: T.minTouchTarget),
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 13 : 14,
            vertical: dense ? 7 : 8,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
            border: Border.all(color: border, width: 1.5),
          ),
          // Align with unit factors shrink-wraps the child, so the chip stays
          // content-sized in a Wrap but still centres its label when a parent
          // (the login site grid) forces a tight width.
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(label, style: style),
          ),
        ),
      ),
    );
  }
}

/// Small static badge: role tags, INACTIVE, MASTER, site tags.
class TagBadge extends StatelessWidget {
  const TagBadge({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.mono = false,
    this.border,
    this.fontSize = 11.5,
    this.radius = 6,
    this.letterSpacing,
  });

  /// The blue `MASTER` marker on master-backed field labels.
  const TagBadge.master({super.key})
      : label = 'MASTER',
        background = T.blueTint,
        foreground = T.blue,
        mono = false,
        border = null,
        fontSize = 10.5,
        radius = 5,
        letterSpacing = 0.06 * 10.5;

  final String label;
  final Color background;
  final Color foreground;
  final bool mono;
  final Color? border;
  final double fontSize;
  final double radius;
  final double? letterSpacing;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? AppText.mono(
            size: fontSize,
            weight: FontWeight.w700,
            color: foreground,
            letterSpacing: letterSpacing,
          )
        : AppText.sans(
            size: fontSize,
            weight: FontWeight.w700,
            color: foreground,
            letterSpacing: letterSpacing,
          );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: radius >= 6 ? 8 : 6,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        border: border == null ? null : Border.all(color: border!),
      ),
      child: Text(label, style: style),
    );
  }
}

/// OPEN / RESOLVED pill on breakdown cards.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: open ? T.redTint : T.greenTint,
        borderRadius: T.pillShape,
      ),
      child: Text(
        open ? 'OPEN' : 'RESOLVED',
        style: AppText.sans(
          size: 12,
          weight: FontWeight.w700,
          color: open ? T.redInk : T.greenInk,
        ),
      ),
    );
  }
}

/// Red count badge on the Breakdowns tab.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, this.compact = false});

  final int count;

  /// The bottom-nav variant sits tighter than the desktop tab variant.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 7, vertical: 1),
      decoration: const BoxDecoration(color: T.red, borderRadius: T.pillShape),
      child: Text(
        '$count',
        style: AppText.sans(
          size: compact ? 10.5 : 11.5,
          weight: FontWeight.w700,
          color: T.white,
        ),
      ),
    );
  }
}
