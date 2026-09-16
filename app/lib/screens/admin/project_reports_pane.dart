import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/admin_estate.dart';
import '../../state/admin_estate.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/sub_tabs.dart';

/// Project-wise (site) reports grouped by Bus / Truck operating category.
class AdminProjectReportsPane extends ConsumerWidget {
  const AdminProjectReportsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(adminSummaryFiltersProvider);
    final async = ref.watch(adminSummaryProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Project-wise reports', style: AppText.sectionTitle),
        const SizedBox(height: 4),
        Text(
          'Sites grouped by Bus Services and Truck Services '
          '(from each site’s operating categories).',
          style: AppText.sans(size: 13, color: T.secondary),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final p in AdminSummaryPeriod.values.where(
              (p) => p != AdminSummaryPeriod.custom,
            ))
              PillChip(
                label: p.label,
                dense: true,
                tone: ChipTone.green,
                selected: filters.period == p,
                onTap: () =>
                    ref.read(adminSummaryFiltersProvider.notifier).setPeriod(p),
              ),
          ],
        ),
        const SizedBox(height: 16),
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: T.green)),
          ),
          error: (e, _) => InlineError(message: e.toString()),
          data: (summary) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final key in <String>['bus', 'truck']) ...<Widget>[
                _SegmentBlock(
                  segment: summary.segments[key] ??
                      SegmentSummary(
                        key: key,
                        label: key == 'bus' ? 'Bus Services' : 'Truck Services',
                        totals: const EstateTotals(),
                        sites: const [],
                      ),
                ),
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SegmentBlock extends StatelessWidget {
  const _SegmentBlock({required this.segment});

  final SegmentSummary segment;

  @override
  Widget build(BuildContext context) {
    final t = segment.totals;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(segment.label, style: AppText.sans(size: 16, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
          '${t.sites} sites · Work ${t.workDone} · Complaints ${t.driverComplaints} · '
          'Breakdowns ${t.breakdowns} · Inspections ${t.inspections}',
          style: AppText.sans(size: 12.5, color: T.secondary),
        ),
        const SizedBox(height: 10),
        if (segment.sites.isEmpty)
          const EmptyState(message: 'No sites in this segment.')
        else
          Column(
            children: <Widget>[
              for (final s in segment.sites) ...<Widget>[
                _SiteRow(site: s),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }
}

class _SiteRow extends StatelessWidget {
  const _SiteRow({required this.site});

  final SiteSummaryMetrics site;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${site.siteCode} · ${site.name}',
                  style: AppText.sans(size: 14, weight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Work ${site.workDone} · Complaints ${site.driverComplaints} · '
                  'BD ${site.breakdowns} · Coolant ${site.coolant} · '
                  'Insp ${site.inspections} · Off-road ${site.openOffRoad}',
                  style: AppText.sans(size: 12, color: T.secondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
