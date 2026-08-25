import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/job_card.dart';
import '../state/providers.dart';
import '../state/session.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/sub_tabs.dart';

/// Job cards a mechanic opened by naming materials on an entry or
/// inspection, and the daily SAP recon that catches the two systems
/// disagreeing. Everything's visible on the card itself — no drill-in
/// screen, no second form to open.
class JobCardsScreen extends ConsumerStatefulWidget {
  const JobCardsScreen({super.key});

  @override
  ConsumerState<JobCardsScreen> createState() => _JobCardsScreenState();
}

class _JobCardsScreenState extends ConsumerState<JobCardsScreen> {
  int _pane = 0;
  static const _labels = <String>['Cards', 'Recon'];

  @override
  Widget build(BuildContext context) {
    final siteName = ref.watch(siteDisplayNameProvider);

    return FadeUp(
      key: ValueKey<String>('job-cards-$siteName'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Job cards', style: AppText.sans(size: 20, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Opened automatically when parts are named on a register entry or inspection.',
            style: AppText.sans(size: 13, color: T.secondary),
          ),
          const SizedBox(height: 16),
          SubTabs(
            labels: _labels,
            selectedIndex: _pane,
            onChanged: (i) => setState(() => _pane = i),
          ),
          const SizedBox(height: 16),
          switch (_pane) {
            0 => const _CardsPane(),
            _ => const _ReconPane(),
          },
        ],
      ),
    );
  }
}

class _CardsPane extends ConsumerWidget {
  const _CardsPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(jobCardsProvider);
    final siteName = ref.watch(siteDisplayNameProvider);
    final canRetry = ref.watch(sessionProvider).canActOnJobCards;

    return cards.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: 'Could not load job cards — $e'),
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(message: 'No job cards at $siteName yet.');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final c in items) ...<Widget>[
              _JobCardTile(card: c, canRetry: canRetry),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class _JobCardTile extends ConsumerWidget {
  const _JobCardTile({required this.card, required this.canRetry});

  final JobCard card;
  final bool canRetry;

  Color _statusColor() => switch (card.status) {
        JobCardStatus.posted => T.green,
        JobCardStatus.issued => T.green,
        JobCardStatus.teco => T.secondary,
        JobCardStatus.error => T.red,
        JobCardStatus.draft => T.muted,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = _statusColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: card.status == JobCardStatus.error ? T.redBorderTint : T.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                card.registrationNo.isEmpty ? card.sourceId : card.registrationNo,
                style: AppText.mono(size: 15, weight: FontWeight.w700),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  card.status.label,
                  style: AppText.mono(size: 11, color: color, weight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (card.sapOrderNo != null)
            Text('SAP order ${card.sapOrderNo}', style: AppText.sans(size: 13, color: T.secondary))
          else if (card.sapNotificationNo != null)
            Text(
              'SAP notification ${card.sapNotificationNo} — order pending',
              style: AppText.sans(size: 13, color: T.secondary),
            )
          else
            Text('Not yet posted to SAP', style: AppText.sans(size: 13, color: T.muted)),
          const SizedBox(height: 6),
          Text(
            card.components.map((c) => '${c.sapMaterialNo} × ${c.qtyRequired}').join(', '),
            style: AppText.sans(size: 13, color: T.secondary),
          ),
          if (card.status == JobCardStatus.error) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              card.lastSapError ?? 'SAP post failed',
              style: AppText.sans(size: 12, color: T.red),
            ),
            if (canRetry) ...<Widget>[
              const SizedBox(height: 8),
              OutlineActionButton(
                label: 'Retry',
                fontSize: 13,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                onPressed: () async {
                  try {
                    await ref.read(jobCardRepositoryProvider).retry(card.id);
                    ref.invalidate(jobCardsProvider);
                    ref.read(toastProvider.notifier).show('Retried — check status above');
                  } catch (e) {
                    ref.read(toastProvider.notifier).show('Retry failed — $e');
                  }
                },
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ReconPane extends ConsumerWidget {
  const _ReconPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exceptions = ref.watch(jobCardReconProvider);
    final canAcknowledge = ref.watch(sessionProvider).canActOnJobCards;

    return exceptions.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: 'Could not load recon — $e'),
      data: (items) {
        if (items.isEmpty) {
          return const EmptyState(message: 'No open recon exceptions. ENM and SAP agree.');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final e in items) ...<Widget>[
              _ReconTile(exception: e, canAcknowledge: canAcknowledge),
              const SizedBox(height: 10),
            ],
          ],
        );
      },
    );
  }
}

class _ReconTile extends ConsumerWidget {
  const _ReconTile({required this.exception, required this.canAcknowledge});

  final JobCardReconException exception;
  final bool canAcknowledge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: T.redBorderTint),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  exception.kindLabel,
                  style: AppText.sans(size: 13, weight: FontWeight.w700, color: T.red),
                ),
                const SizedBox(height: 4),
                Text(exception.detail, style: AppText.sans(size: 14)),
                if (exception.sapOrderNo != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    'SAP order ${exception.sapOrderNo}',
                    style: AppText.sans(size: 12, color: T.secondary),
                  ),
                ],
              ],
            ),
          ),
          if (canAcknowledge) ...<Widget>[
            const SizedBox(width: 10),
            OutlineActionButton(
              label: 'Acknowledge',
              fontSize: 13,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              onPressed: () async {
                try {
                  await ref.read(jobCardRepositoryProvider).acknowledgeRecon(exception.id);
                  ref.invalidate(jobCardReconProvider);
                } catch (e) {
                  ref.read(toastProvider.notifier).show('Could not acknowledge — $e');
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}
