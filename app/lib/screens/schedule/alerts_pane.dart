import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/inspection.dart';
import '../../state/schedule.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/sub_tabs.dart';

/// The alert log: what the nightly run found that somebody has to look at.
///
/// Deliberately one list rather than three: a supervisor wants "what is wrong
/// at this site", not to remember which of three screens holds which kind of
/// problem.
class AlertsPane extends ConsumerWidget {
  const AlertsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(alertFilterProvider);
    final async = ref.watch(alertsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          children: <Widget>[
            for (final option in const <(String, String)>[
              ('open', 'Open'),
              ('acknowledged', 'Acknowledged'),
              ('resolved', 'Resolved'),
              ('all', 'All'),
            ])
              PillChip(
                label: option.$2,
                selected: filter == option.$1,
                tone: ChipTone.green,
                fontSize: 12.5,
                onTap: () =>
                    ref.read(alertFilterProvider.notifier).state = option.$1,
              ),
          ],
        ),
        const SizedBox(height: 16),
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => EmptyState(message: e.toString()),
          data: (alerts) {
            if (alerts.isEmpty) {
              return const EmptyState(
                message: 'Nothing outstanding. The nightly run found no '
                    'missed inspections, open breakdowns or overdue services.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final alert in alerts) _AlertCard(alert: alert),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _AlertCard extends ConsumerStatefulWidget {
  const _AlertCard({required this.alert});

  final SiteAlert alert;

  @override
  ConsumerState<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends ConsumerState<_AlertCard> {
  bool _busy = false;

  Future<void> _acknowledge() async {
    setState(() => _busy = true);
    try {
      await ref.read(scheduleControllerProvider).acknowledge(widget.alert);
      ref.read(toastProvider.notifier).show('Acknowledged');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final alert = widget.alert;
    final (bg, fg) = switch (alert.kind) {
      AlertKind.breakdownOpen => (T.redTint, T.redInk),
      AlertKind.missedInspection => (T.amberTint, T.amber),
      AlertKind.serviceOverdue => (T.indigoTint, T.indigo),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TagBadge(
                  label: alert.kind.label,
                  background: bg,
                  foreground: fg,
                ),
                const Spacer(),
                Text(
                  Dates.relativeLabel(alert.raisedOn),
                  style: AppText.meta,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(alert.title, style: AppText.cardTitle),
            const SizedBox(height: 4),
            Text(alert.body, style: AppText.bodyText),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                if (alert.state != AlertState.open)
                  TagBadge(
                    label: alert.state.label,
                    background: T.inactiveFill,
                    foreground: T.secondary,
                  ),
                const Spacer(),
                if (alert.isOpen)
                  TextButton(
                    onPressed: _busy ? null : _acknowledge,
                    child: Text(
                      _busy ? 'Working…' : 'Acknowledge',
                      style: AppText.sans(
                        size: 13,
                        weight: FontWeight.w700,
                        color: T.green,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
