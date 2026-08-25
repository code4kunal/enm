import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/registers.dart';
import '../models/entry.dart';
import '../router.dart';
import '../state/entries.dart';
import '../state/providers.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/chips.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';

class BreakdownsScreen extends ConsumerWidget {
  const BreakdownsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final breakdowns = ref.watch(breakdownsProvider);
    final siteName = ref.watch(siteDisplayNameProvider);

    return FadeUp(
      key: ValueKey<String>('breakdowns-$siteName'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              Text(
                'Breakdown tracker',
                style: AppText.sans(size: 20, weight: FontWeight.w700),
              ),
              FilledActionButton.danger(
                label: '+ Report breakdown',
                onPressed: () =>
                    context.go(Routes.newEntry(kBreakdownRegisterId)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (breakdowns.isEmpty)
            EmptyState(message: 'No breakdowns recorded at $siteName.')
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final b in breakdowns) ...<Widget>[
                  _BreakdownCard(entry: b),
                  const SizedBox(height: 10),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _BreakdownCard extends ConsumerWidget {
  const _BreakdownCard({required this.entry});

  final RegisterEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = entry.isOpen;
    final d = entry.data;
    final busName = ref.watch(vehicleNameProvider(entry.busNumber));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(14),
        // Open breakdowns carry a red-tinted border.
        border: Border.all(color: open ? T.redBorderTint : T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      busName,
                      style: AppText.mono(size: 15.5, weight: FontWeight.w600),
                    ),
                    StatusPill(open: open),
                    Text(
                      '${entry.date} · ${(d['loc'] ?? '').isEmpty ? '—' : d['loc']}',
                      style: AppText.meta,
                    ),
                  ],
                ),
              ),
              if (open) ...<Widget>[
                const SizedBox(width: 10),
                OutlineActionButton(
                  label: 'Mark resolved',
                  onPressed: () =>
                      context.go(Routes.resolveBreakdown(entry.id)),
                  foreground: T.green,
                  borderColor: T.green,
                  accent: T.green,
                  hoverFill: T.greenTint,
                  fontSize: 13,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(d['complaint'] ?? '', style: AppText.sans(size: 14, color: T.body)),
          const SizedBox(height: 10),
          // Metrics row — mono values, wrapping on narrow screens.
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: <Widget>[
              _Metric(label: 'B/Down', value: d['t_bd'] ?? '—'),
              _Metric(label: 'Attended', value: d['t_att'] ?? '—'),
              _Metric(
                label: 'Time taken',
                value: Dates.elapsed(d['t_bd'], d['t_att']),
              ),
              _Metric(label: 'Loss KM', value: '${d['loss'] ?? '0'} km'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: AppText.sans(size: 12.5, color: T.secondary),
        children: <InlineSpan>[
          TextSpan(text: '$label '),
          TextSpan(
            text: value,
            style: AppText.mono(
              size: 12.5,
              weight: FontWeight.w600,
              color: T.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
