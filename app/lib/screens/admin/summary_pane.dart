import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/admin_estate.dart';
import '../../state/admin_estate.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/sub_tabs.dart';

/// Estate KPIs — site-wise incident counts for super admins.
class AdminSummaryPane extends ConsumerWidget {
  const AdminSummaryPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(adminSummaryFiltersProvider);
    final async = ref.watch(adminSummaryProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Estate summary', style: AppText.sectionTitle),
        const SizedBox(height: 4),
        Text(
          'Incident counts by site for the selected period.',
          style: AppText.sans(size: 13, color: T.secondary),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final p in AdminSummaryPeriod.values)
              PillChip(
                label: p.label,
                dense: true,
                tone: ChipTone.green,
                selected: filters.period == p,
                onTap: () =>
                    ref.read(adminSummaryFiltersProvider.notifier).setPeriod(p),
              ),
            if (filters.period == AdminSummaryPeriod.custom) ...<Widget>[
              _DateChip(
                label: 'From',
                value: filters.dateFrom,
                onChanged: (v) =>
                    ref.read(adminSummaryFiltersProvider.notifier).setFrom(v),
              ),
              _DateChip(
                label: 'To',
                value: filters.dateTo,
                onChanged: (v) =>
                    ref.read(adminSummaryFiltersProvider.notifier).setTo(v),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: T.green)),
          ),
          error: (e, _) => InlineError(message: e.toString()),
          data: (summary) => _SummaryBody(summary: summary),
        ),
      ],
    );
  }
}

class _SummaryBody extends StatelessWidget {
  const _SummaryBody({required this.summary});

  final AdminSummary summary;

  @override
  Widget build(BuildContext context) {
    final e = summary.estate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '${summary.dateFrom} → ${summary.dateTo}',
          style: AppText.meta,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            _StatCard(label: 'Sites', value: '${e.activeSites}/${e.sites}'),
            _StatCard(label: 'Vehicles', value: '${e.vehicles}'),
            _StatCard(label: 'Users', value: '${e.users}'),
            _StatCard(label: 'Work done', value: '${e.workDone}'),
            _StatCard(label: 'Complaints', value: '${e.driverComplaints}'),
            _StatCard(label: 'Breakdowns', value: '${e.breakdowns}'),
            _StatCard(label: 'Coolant', value: '${e.coolant}'),
            _StatCard(label: 'Inspections', value: '${e.inspections}'),
            _StatCard(label: 'Off road', value: '${e.openOffRoad}'),
          ],
        ),
        const SizedBox(height: 20),
        Text('By site', style: AppText.sans(size: 15, weight: FontWeight.w700)),
        const SizedBox(height: 10),
        if (summary.sites.isEmpty)
          const EmptyState(message: 'No sites onboarded yet.')
        else
          Column(
            children: <Widget>[
              for (final s in summary.sites) ...<Widget>[
                _SiteMetricsCard(site: s),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label.toUpperCase(), style: AppText.sans(size: 10, color: T.muted)),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppText.mono(size: 18, weight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _SiteMetricsCard extends StatelessWidget {
  const _SiteMetricsCard({required this.site});

  final SiteSummaryMetrics site;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(site.siteCode, style: AppText.mono(size: 14, weight: FontWeight.w700)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(site.name, style: AppText.sans(size: 13, color: T.secondary)),
              ),
              if (!site.isActive)
                const TagBadge(
                  label: 'INACTIVE',
                  background: T.inactiveFill,
                  foreground: T.muted,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: <Widget>[
              _kv('Work', site.workDone),
              _kv('Complaints', site.driverComplaints),
              _kv('Breakdowns', site.breakdowns),
              _kv('Coolant', site.coolant),
              _kv('Inspections', site.inspections),
              _kv('Off road', site.openOffRoad),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, int v) => Text(
        '$k $v',
        style: AppText.sans(size: 12.5, color: T.secondary),
      );
}

class _DateChip extends StatelessWidget {
  const _DateChip({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return OutlineActionButton(
      label: value.isEmpty ? label : '$label $value',
      fontSize: 12.5,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onPressed: () async {
        final initial = Dates.parse(value) ?? DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 1)),
        );
        if (picked != null) onChanged(Dates.iso(picked));
      },
    );
  }
}
