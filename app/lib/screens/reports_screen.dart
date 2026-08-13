import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/reports.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/chips.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/sub_tabs.dart';
import 'reports/charts_pane.dart';
import 'reports/dmr_pane.dart';
import 'reports/history_pane.dart';
import 'reports/investigations_pane.dart';
import 'reports/off_road_pane.dart';
import 'reports/units_pane.dart';

/// The depot's reports, computed from the registers.
///
/// One date across the day panes, because they are read together: what the day
/// looked like, what is still off the road, and which breakdowns have not been
/// explained. The month grid and the control charts are the same registers
/// widened out to a month, and carry their own period.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  int _pane = 0;

  static const _labels = <String>[
    'DMR',
    'Month',
    'Off road',
    'Investigations',
    'Charts',
    'Units',
    'Bus history',
  ];

  /// Panes that pick their own month, so the day picker would only mislead.
  static const _monthly = <int>{1, 4, 5, 6};

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session.site.isEmpty) {
      return const EmptyState(message: 'Pick a site first.');
    }

    return FadeUp(
      key: ValueKey<String>('reports-${session.site}-$_pane'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _Header(),
          const SizedBox(height: 14),
          // The month grid is its own period, so the day picker would only
          // mislead there.
          if (!_monthly.contains(_pane)) const _DatePicker(),
          if (!_monthly.contains(_pane)) const SizedBox(height: 14),
          SubTabs(
            labels: _labels,
            selectedIndex: _pane,
            onChanged: (i) => setState(() => _pane = i),
          ),
          const SizedBox(height: 18),
          switch (_pane) {
            0 => const DmrPane(),
            1 => const DmrMonthPane(),
            2 => const OffRoadPane(),
            3 => const InvestigationsPane(),
            4 => const ChartsPane(),
            5 => const UnitsPane(),
            _ => const HistoryPane(),
          },
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outstanding = ref.watch(outstandingInvestigationsProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Reports', style: AppText.pageTitle),
              const SizedBox(height: 4),
              Text(
                'Computed from the registers. Only what nothing else observes '
                'is typed in.',
                style: AppText.meta,
              ),
            ],
          ),
        ),
        if (outstanding > 0)
          TagBadge(
            label: '$outstanding to explain',
            background: T.amberTint,
            foreground: T.amber,
          ),
      ],
    );
  }
}

/// One day, shared by every pane.
class _DatePicker extends ConsumerWidget {
  const _DatePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = ref.watch(reportDateProvider);
    final today = Dates.today();

    Future<void> pick() async {
      final current = Dates.parse(date) ?? DateTime.now();
      final picked = await showDatePicker(
        context: context,
        initialDate: current,
        firstDate: DateTime(current.year - 2),
        lastDate: DateTime(current.year + 1),
      );
      if (picked != null) {
        ref.read(reportDateProvider.notifier).state = Dates.iso(picked);
      }
    }

    void shift(int by) => ref.read(reportDateProvider.notifier).state =
        Dates.addDays(date, by);

    return Row(
      children: <Widget>[
        OutlineActionButton(
          label: '‹',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          onPressed: () => shift(-1),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlineActionButton(
            label: Dates.relativeLabel(date),
            fontSize: 14,
            onPressed: pick,
          ),
        ),
        const SizedBox(width: 8),
        OutlineActionButton(
          label: '›',
          fontSize: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          // Tomorrow's report does not exist yet.
          onPressed: date.compareTo(today) < 0 ? () => shift(1) : null,
        ),
      ],
    );
  }
}
