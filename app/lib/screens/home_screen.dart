import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/registers.dart';
import '../models/entry.dart';
import '../models/register.dart';
import '../router.dart';
import '../state/entries.dart';
import '../models/checklist.dart';
import '../state/inspections.dart';
import '../state/session.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/code_square.dart';
import '../widgets/dashed.dart';
import '../widgets/chips.dart';
import '../widgets/fade_up.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final site = session.site;
    final siteName = ref.watch(activeSiteProvider)?.name ?? site;
    final todayEntries = ref.watch(todayEntriesProvider);
    final openBreakdowns = ref.watch(openBreakdownsProvider).length;
    final firstName = (session.user?.name ?? '').split(' ').first;

    return FadeUp(
      key: ValueKey<String>('home-$site'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (openBreakdowns > 0) ...<Widget>[
            _OpenBreakdownBanner(count: openBreakdowns, site: siteName),
            const SizedBox(height: 18),
          ],
          _Greeting(name: firstName, site: siteName),
          const SizedBox(height: 18),
          _RegisterCardGrid(todayEntries: todayEntries),
          const SizedBox(height: 22),
          const _InspectionCardGrid(),
          const SizedBox(height: 28),
          Text("Today's entries · $siteName", style: AppText.sectionTitle),
          const SizedBox(height: 12),
          if (todayEntries.isEmpty)
            EmptyState(
              message: 'No entries yet today at $siteName. '
                  'Start with any register above.',
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final e in todayEntries) ...<Widget>[
                  _TodayRow(entry: e),
                  const SizedBox(height: 8),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _OpenBreakdownBanner extends StatelessWidget {
  const _OpenBreakdownBanner({required this.count, required this.site});

  final int count;
  final String site;

  @override
  Widget build(BuildContext context) {
    final plural = count > 1 ? 's' : '';
    return InkWell(
      onTap: () => context.go(Routes.breakdowns),
      borderRadius: T.cardSmShape,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: T.redTint,
          borderRadius: T.cardSmShape,
          border: Border.all(color: T.redBorderTint),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: T.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$count open breakdown$plural at $site — tap to view',
                style: AppText.sans(
                  size: 14.5,
                  weight: FontWeight.w600,
                  color: T.redInkDeep,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.name, required this.site});

  final String name;
  final String site;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            Text(Dates.greeting(name), style: AppText.pageTitle),
            RichText(
              text: TextSpan(
                style: AppText.sans(size: 13.5, color: T.secondary),
                children: <InlineSpan>[
                  TextSpan(text: '${Dates.longToday()} · '),
                  TextSpan(
                    text: site,
                    style: AppText.mono(size: 13.5, color: T.secondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Pick a register to make an entry — same columns as your physical '
          'register.',
          style: AppText.sans(size: 14, color: T.secondary),
        ),
      ],
    );
  }
}

/// Responsive `auto-fill, minmax(190px, 1fr)` grid of register cards.
class _RegisterCardGrid extends StatelessWidget {
  const _RegisterCardGrid({required this.todayEntries});

  final List<RegisterEntry> todayEntries;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        const minItem = 190.0;
        final width = constraints.maxWidth;
        // How many 190px columns fit, accounting for the gaps between them.
        final columns =
            ((width + gap) / (minItem + gap)).floor().clamp(1, kRegisters.length);
        final itemWidth = (width - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final r in kRegisters)
              SizedBox(
                width: itemWidth,
                child: _RegisterCard(
                  register: r,
                  todayCount:
                      todayEntries.where((e) => e.registerId == r.id).length,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RegisterCard extends StatelessWidget {
  const _RegisterCard({required this.register, required this.todayCount});

  final RegisterDef register;
  final int todayCount;

  @override
  Widget build(BuildContext context) {
    return LiftOnHover(
      onTap: () => context.go(Routes.newEntry(register.id)),
      child: (context, hovered) => AnimatedContainer(
        duration: T.hoverLift,
        curve: T.easeOut,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.cardShape,
          border: Border.all(
            color: hovered ? T.cardHoverBorder : T.border,
          ),
          boxShadow: hovered ? T.cardHoverShadow : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                CodeSquare(code: register.code, color: register.color),
                Text(
                  todayCount > 0 ? '$todayCount today' : '—',
                  style: AppText.sans(
                    size: 12,
                    weight: FontWeight.w600,
                    color: T.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(register.name, style: AppText.cardTitle),
            const SizedBox(height: 6),
            Text(
              '+ New entry',
              style: AppText.sans(
                size: 12.5,
                weight: FontWeight.w700,
                color: T.green,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the "Today's entries" feed.
class _TodayRow extends StatelessWidget {
  const _TodayRow({required this.entry});

  final RegisterEntry entry;

  @override
  Widget build(BuildContext context) {
    final register = requireRegister(entry.registerId);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          CodeSquare(code: register.code, color: register.color, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: 10,
                  children: <Widget>[
                    Text(
                      entry.busNumber,
                      style: AppText.mono(size: 14, weight: FontWeight.w600),
                    ),
                    Text(
                      '${entry.time} · ${entry.enteredBy}',
                      style: AppText.sans(size: 12, color: T.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entrySummary(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.sans(size: 13.5, color: T.body),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// Data entry for the inspections, alongside the five registers.
///
/// Separate cards because they are separate jobs: a daily inspection and a
/// ten-day service run different checklists, so each opens its own form. Driven
/// by the site's work-type master, so a depot that adds an inspection type gets
/// a card without a code change.
class _InspectionCardGrid extends ConsumerWidget {
  const _InspectionCardGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checklists = ref.watch(inspectionTypesProvider);
    if (checklists.isEmpty) return const SizedBox.shrink();

    final done = ref.watch(todaysInspectionsProvider).valueOrNull ??
        const <InspectionEntry>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Inspections', style: AppText.sectionTitle),
        const SizedBox(height: 4),
        Text(
          'Each runs its own checklist.',
          style: AppText.meta,
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 12.0;
            const minItem = 190.0;
            final width = constraints.maxWidth;
            final columns = ((width + gap) / (minItem + gap))
                .floor()
                .clamp(1, checklists.length);
            final itemWidth = (width - gap * (columns - 1)) / columns;

            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final c in checklists)
                  SizedBox(
                    width: itemWidth,
                    child: _InspectionCard(
                      checklist: c,
                      todayCount: done
                          .where((d) => d.workTypeId == c.workTypeId)
                          .length,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _InspectionCard extends StatelessWidget {
  const _InspectionCard({required this.checklist, required this.todayCount});

  final Checklist checklist;
  final int todayCount;

  @override
  Widget build(BuildContext context) {
    return LiftOnHover(
      onTap: () => context.go(Routes.newInspection(checklist.workTypeId)),
      child: (context, hovered) => Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: T.cardShape,
              border: Border.all(
                color: hovered ? T.cardHoverBorder : T.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    TagBadge(
                      label: checklist.workTypeCode,
                      background: T.indigoTint,
                      foreground: T.indigo,
                    ),
                    const Spacer(),
                    Text(
                      todayCount == 0 ? '—' : '$todayCount',
                      style: AppText.mono(size: 13, color: T.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  checklist.workTypeName,
                  style: AppText.cardTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Consumer(
                  builder: (context, ref, _) {
                    // A work type can keep a list per bus model. The count on
                    // its own would describe only one of them, so say how many
                    // there are and let the bus pick.
                    final variants =
                        ref.watch(variantCountProvider(checklist.workTypeId));
                    final label = checklist.isEmpty
                        ? 'Checklist not written yet'
                        : variants > 1
                            ? '$variants checklists by bus model'
                            : '${checklist.items.length} checks';
                    return Text(
                      label,
                      style: AppText.sans(
                        size: 13,
                        weight: FontWeight.w600,
                        color: checklist.isEmpty ? T.amber : T.green,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
    );
  }
}
