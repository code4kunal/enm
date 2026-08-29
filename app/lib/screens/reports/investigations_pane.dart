import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/report.dart';
import '../../state/reports.dart';
import '../../state/session.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/report_download.dart';
import '../../widgets/sheet.dart';
import '../../widgets/sub_tabs.dart';

/// Annexure-V: every breakdown that day, and why it happened.
///
/// The breakdown half is already recorded, so this shows it read-only and asks
/// only for the two things a person has to supply: what was found, and what was
/// done to stop it recurring. The three lookup columns arrive filled in.
class InvestigationsPane extends ConsumerWidget {
  const InvestigationsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(investigationsProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: e.toString()),
      data: (day) {
        final items = day.items;
        if (items.isEmpty) {
          // A quiet date and a broken screen look identical, so say where the
          // work actually is rather than only that there is none here.
          final nearest = day.nearestDate;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const EmptyState(
                message: 'No breakdowns on this date — nothing to investigate.',
              ),
              if (nearest != null) ...<Widget>[
                const SizedBox(height: 12),
                Center(
                  child: OutlineActionButton(
                    label: 'Go to ${Dates.dayLabel(nearest)}',
                    onPressed: () => ref
                        .read(reportDateProvider.notifier)
                        .state = nearest,
                  ),
                ),
              ],
            ],
          );
        }
        final outstanding = items.where((i) => !i.isComplete).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    outstanding == 0
                        ? '${items.length} breakdown'
                            '${items.length == 1 ? '' : 's'}, all investigated'
                        : '$outstanding of ${items.length} still to explain',
                    style: AppText.sans(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: outstanding == 0 ? T.greenInk : T.amber,
                    ),
                  ),
                ),
                ReportDownloadButton(
                  doc: ReportDoc.investigations,
                  date: ref.watch(reportDateProvider),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final item in items) ...<Widget>[
              _InvestigationCard(item: item),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }
}

class _InvestigationCard extends ConsumerWidget {
  const _InvestigationCard({required this.item});

  final Investigation item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(sessionProvider).can('em_report:write');

    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(item.registrationNo, style: AppText.mono(size: 14)),
              if (item.breakdownTime != null) ...<Widget>[
                const SizedBox(width: 8),
                Text(item.breakdownTime!, style: AppText.meta),
              ],
              const Spacer(),
              if (item.defectType.isNotEmpty)
                TagBadge(
                  label: item.defectType,
                  background: T.subtleFill,
                  foreground: T.secondary,
                ),
              const SizedBox(width: 6),
              TagBadge(
                label: item.isComplete ? 'EXPLAINED' : 'OPEN',
                background: item.isComplete ? T.greenTint : T.amberTint,
                foreground: item.isComplete ? T.greenInk : T.amber,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(item.breakdownReason, style: AppText.cardTitle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: <Widget>[
              if ((item.location ?? '').isNotEmpty)
                _Fact(label: 'Location', value: item.location!),
              if (item.lossKm != null)
                _Fact(label: 'Loss', value: '${item.lossKm!.toStringAsFixed(1)} km'),
              if (item.lastPmOn != null)
                _Fact(label: 'Last PM', value: Dates.dayLabel(item.lastPmOn!)),
            ],
          ),
          if ((item.relatedComplaints ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            _Prefilled(
              label: 'Driver had already reported',
              value: item.relatedComplaints!,
            ),
          ],
          if ((item.lastPmFindings ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            _Prefilled(
              label: 'Last PM reported',
              value: item.lastPmFindings!,
            ),
          ],
          if ((item.findings ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text('Findings', style: AppText.label),
            const SizedBox(height: 2),
            Text(item.findings!, style: AppText.bodyText),
          ],
          if ((item.investigationAction ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text('Action to prevent recurrence', style: AppText.label),
            const SizedBox(height: 2),
            Text(item.investigationAction!, style: AppText.bodyText),
          ],
          if (canEdit) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => showInvestigationEditor(context, ref, item),
                child: Text(
                  item.isComplete ? 'Edit' : 'Investigate',
                  style: AppText.sans(
                    size: 13,
                    weight: FontWeight.w700,
                    color: T.green,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Something the system worked out, shown as context rather than as a field.
class _Prefilled extends StatelessWidget {
  const _Prefilled({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: T.subtleFill,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            style: AppText.sans(size: 10, color: T.muted),
          ),
          const SizedBox(height: 2),
          Text(value, style: AppText.sans(size: 12.5, height: 1.4)),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label.toUpperCase(), style: AppText.sans(size: 10, color: T.muted)),
        const SizedBox(height: 1),
        Text(value, style: AppText.sans(size: 12.5, weight: FontWeight.w600)),
      ],
    );
  }
}

Future<void> showInvestigationEditor(
  BuildContext context,
  WidgetRef ref,
  Investigation item,
) {
  return showEditorSheet<void>(
    context: context,
    builder: (_) => _InvestigationSheet(item: item),
  );
}

class _InvestigationSheet extends ConsumerStatefulWidget {
  const _InvestigationSheet({required this.item});

  final Investigation item;

  @override
  ConsumerState<_InvestigationSheet> createState() =>
      _InvestigationSheetState();
}

class _InvestigationSheetState extends ConsumerState<_InvestigationSheet> {
  late final TextEditingController _findings =
      TextEditingController(text: widget.item.findings ?? '');
  late final TextEditingController _action =
      TextEditingController(text: widget.item.investigationAction ?? '');
  late final TextEditingController _pm =
      TextEditingController(text: widget.item.lastPmFindings ?? '');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Opening the investigation is what fills in the three lookup columns, so
    // ask for it once and take whatever the server worked out.
    Future<void>.microtask(_prefill);
  }

  Future<void> _prefill() async {
    if (widget.item.lastPmFindings != null) return;
    try {
      final filled = await ref
          .read(reportControllerProvider)
          .openInvestigation(widget.item.entryId);
      if (!mounted) return;
      if (_pm.text.isEmpty) _pm.text = filled.lastPmFindings ?? '';
      setState(() {});
    } on Object {
      // The form still works without the pre-fill; it is a convenience.
    }
  }

  @override
  void dispose() {
    _findings.dispose();
    _action.dispose();
    _pm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(reportControllerProvider).saveInvestigation(
            widget.item.entryId,
            findings: _findings.text.trim(),
            investigationAction: _action.text.trim(),
            lastPmFindings: _pm.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
      ref.read(toastProvider.notifier).show('Investigation saved');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(item.registrationNo, style: AppText.sectionTitle),
            const SizedBox(height: 4),
            Text(
              '${item.breakdownReason} · ${Dates.dayLabel(item.entryDate)}',
              style: AppText.meta,
            ),
            const SizedBox(height: 18),
            if ((item.relatedComplaints ?? '').isNotEmpty) ...<Widget>[
              _Prefilled(
                label: 'Driver had already reported',
                value: item.relatedComplaints!,
              ),
              const SizedBox(height: 14),
            ],
            const FieldLabel(label: 'Last PM reported'),
            const SizedBox(height: 6),
            AppTextField(
              controller: _pm,
              placeholder: 'NO, or what the last PM turned up',
              rows: 2,
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Findings', required: true),
            const SizedBox(height: 6),
            AppTextField(
              controller: _findings,
              placeholder: 'What was actually wrong',
              rows: 3,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            const FieldLabel(
              label: 'Action to prevent recurrence',
              required: true,
            ),
            const SizedBox(height: 6),
            AppTextField(
              controller: _action,
              placeholder: 'What was done so it does not happen again',
              rows: 3,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            FilledActionButton(
              label: _busy ? 'Saving…' : 'Save investigation',
              expand: true,
              onPressed: _busy ? null : _save,
            ),
            const SizedBox(height: 8),
            Text(
              'An investigation counts as done once it has both a finding and '
              'an action.',
              textAlign: TextAlign.center,
              style: AppText.meta,
            ),
          ],
        ),
      ),
    );
  }
}
