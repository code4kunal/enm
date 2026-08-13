import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Segmented control for switching between panes inside a screen — the Site
/// section's Fleet / Master data / Docking / Import, and Admin's Sites / Users.
///
/// Distinct from the top-level nav so a user can tell "which screen am I on"
/// from "which pane of it".
class SubTabs extends StatelessWidget {
  const SubTabs({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: T.subtleFill,
          borderRadius: T.controlShape,
          border: Border.all(color: T.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                child: _Tab(
                  label: labels[i],
                  selected: i == selectedIndex,
                  onTap: () => onChanged(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: T.hoverLift,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? T.card : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? T.border : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: AppText.sans(
              size: 14,
              weight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? T.ink : T.secondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Screen header: title, optional subtitle, optional trailing action.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.action,
  });

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(title, style: AppText.sans(size: 20, weight: FontWeight.w700)),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  subtitle!,
                  style: AppText.sans(size: 13.5, color: T.secondary),
                ),
              ],
            ],
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

/// White bordered panel used for every form card and grouped section.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.accent = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
  });

  final Widget child;

  /// Green outline, marking the panel as the thing being edited.
  final bool accent;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardShape,
        border: Border.all(
          color: accent ? T.green : T.border,
          width: accent ? 1.5 : 1,
        ),
      ),
      child: child,
    );
  }
}

/// Inline red form error.
class InlineError extends StatelessWidget {
  const InlineError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        message,
        style: AppText.sans(size: 13, weight: FontWeight.w600, color: T.red),
      ),
    );
  }
}

/// Label + value pair for read-only summary rows.
class StatCell extends StatelessWidget {
  const StatCell({
    super.key,
    required this.label,
    required this.value,
    this.mono = true,
    this.tone,
  });

  final String label;
  final String value;
  final bool mono;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label.toUpperCase(),
          style: AppText.sans(
            size: 11,
            weight: FontWeight.w700,
            color: T.muted,
            letterSpacing: 0.08 * 11,
          ),
        ),
        const SizedBox(height: 4),
        mono
            ? Text(
                value,
                style: AppText.mono(
                  size: 16,
                  weight: FontWeight.w600,
                  color: tone ?? T.ink,
                ),
              )
            : Text(
                value,
                style: AppText.sans(
                  size: 15,
                  weight: FontWeight.w600,
                  color: tone ?? T.ink,
                ),
              ),
      ],
    );
  }
}
