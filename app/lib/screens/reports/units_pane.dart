import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/report.dart';
import '../../state/reports.dart';
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

/// The Unit Failure Statement: every component that came off in a month.
///
/// A row appears here by being taken off a bus, not by being typed into a
/// report — the statement and the bus history card are the same records read
/// two ways, so they can never disagree.
class UnitsPane extends ConsumerWidget {
  const UnitsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(unitMonthProvider);
    final async = ref.watch(unitFailuresProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            OutlineActionButton(
              label: '‹',
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              onPressed: () => ref
                  .read(unitMonthProvider.notifier)
                  .state = Dates.shiftMonth(month, -1),
            ),
            Expanded(
              child: Center(
                child: Text(
                  Dates.monthLabel('$month-01'),
                  style: AppText.sans(size: 15, weight: FontWeight.w700),
                ),
              ),
            ),
            OutlineActionButton(
              label: '›',
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              onPressed: () => ref
                  .read(unitMonthProvider.notifier)
                  .state = Dates.shiftMonth(month, 1),
            ),
          ],
        ),
        const SizedBox(height: 14),
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => EmptyState(message: e.toString()),
          data: (items) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      items.isEmpty
                          ? 'No unit came off this month.'
                          : '${items.length} unit${items.length == 1 ? '' : 's'} '
                              'replaced',
                      style: AppText.sans(size: 13.5, weight: FontWeight.w600),
                    ),
                  ),
                  ReportDownloadButton(
                    doc: ReportDoc.unitFailures,
                    month: month,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (items.isEmpty)
                const EmptyState(
                  message: 'A unit reaches this statement by being taken off a '
                      'bus. Nothing was, this month.',
                )
              else
                Panel(
                  padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (var i = 0; i < items.length; i++)
                        _FailureRow(number: i + 1, item: items[i]),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _FailureRow extends StatelessWidget {
  const _FailureRow({required this.number, required this.item});

  final int number;
  final FittedUnit item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 26,
                child: Text(
                  '$number',
                  style: AppText.mono(size: 12, color: T.muted),
                ),
              ),
              Text(item.registrationNo, style: AppText.mono(size: 13.5)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.unitName,
                  style: AppText.sans(size: 13.5, weight: FontWeight.w600),
                ),
              ),
              if ((item.unitNo ?? '').isNotEmpty)
                TagBadge(
                  label: item.unitNo!,
                  background: T.subtleFill,
                  foreground: T.secondary,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: <Widget>[
                _Fact(label: 'Fitted', value: Dates.dayLabel(item.fittedOn)),
                _Fact(
                  label: 'Removed',
                  value: item.removedOn == null
                      ? '—'
                      : Dates.dayLabel(item.removedOn!),
                ),
                // A dash, not a nil: an unknown life would otherwise read as a
                // unit that failed the day it went on.
                _Fact(label: 'Kms covered', value: item.kmsDisplay),
              ],
            ),
          ),
          if ((item.removalReason ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(item.removalReason!, style: AppText.bodyText),
            ),
          ],
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

// ─── removing ───────────────────────────────────────────────────────────

Future<void> showRemoveUnitEditor(
  BuildContext context,
  WidgetRef ref,
  FittedUnit unit,
) {
  return showEditorSheet<void>(
    context: context,
    builder: (_) => _RemoveUnitSheet(unit: unit),
  );
}

class _RemoveUnitSheet extends ConsumerStatefulWidget {
  const _RemoveUnitSheet({required this.unit});

  final FittedUnit unit;

  @override
  ConsumerState<_RemoveUnitSheet> createState() => _RemoveUnitSheetState();
}

class _RemoveUnitSheetState extends ConsumerState<_RemoveUnitSheet> {
  String _removedOn = Dates.today();
  final TextEditingController _odometer = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  final TextEditingController _remarks = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _odometer.dispose();
    _reason.dispose();
    _remarks.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(reportControllerProvider).removeUnit(
            widget.unit.id,
            removedOn: _removedOn,
            removedOdometerKm: int.tryParse(_odometer.text.trim()),
            removalReason: _reason.text.trim(),
            remarks: _remarks.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
      ref.read(toastProvider.notifier).show('Unit removed');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.unit;

    return EditorSheet(
      title: unit.unitName,
      subtitle: '${unit.registrationNo} · fitted '
          '${Dates.dayLabel(unit.fittedOn)}',
      action: FilledActionButton(
        label: _busy ? 'Saving…' : 'Record removal',
        expand: true,
        onPressed: _busy ? null : _save,
      ),
      footnote: 'This is what puts the unit on the failure statement.',
      children: <Widget>[
            const FieldLabel(label: 'Date removed', required: true),
            const SizedBox(height: 6),
            OutlineActionButton(
              label: Dates.dayLabel(_removedOn),
              onPressed: () async {
                final current = Dates.parse(_removedOn) ?? DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: current,
                  firstDate: Dates.parse(unit.fittedOn) ?? DateTime(2020),
                  lastDate: DateTime(current.year + 1),
                );
                if (picked != null) {
                  setState(() => _removedOn = Dates.iso(picked));
                }
              },
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Odometer at removal'),
            const SizedBox(height: 6),
            AppTextField(
              controller: _odometer,
              placeholder: 'Leave blank to use the bus’s last reading',
              numeric: true,
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Reason for removal'),
            const SizedBox(height: 6),
            AppTextField(
              controller: _reason,
              placeholder: 'Why it came off',
              rows: 2,
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Remarks'),
            const SizedBox(height: 6),
            AppTextField(controller: _remarks, placeholder: '', rows: 2),
      ],
    );
  }
}
