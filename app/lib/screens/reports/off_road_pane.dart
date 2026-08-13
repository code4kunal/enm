import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/report.dart';
import '../../models/site.dart';
import '../../state/providers.dart';
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

/// Details of defective buses: what is off the road and why.
///
/// A case rather than a daily row — down on a date, worked on, back on a date —
/// so the list for any morning is a query rather than a re-typing. This is also
/// what the DMR counts as defective in depot and held over three days.
class OffRoadPane extends ConsumerWidget {
  const OffRoadPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(offRoadProvider);
    final date = ref.watch(reportDateProvider);
    final canEdit = ref.watch(sessionProvider).canManageSites;

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: e.toString()),
      data: (cases) {
        final held = cases.where((c) => c.isHeld).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    cases.isEmpty
                        ? 'Every bus on the road.'
                        : '${cases.length} off the road'
                            '${held > 0 ? ' · $held held over 3 days' : ''}',
                    style: AppText.sans(size: 13.5, weight: FontWeight.w600),
                  ),
                ),
                if (canEdit) ...<Widget>[
                  OutlineActionButton(
                    label: 'Add',
                    fontSize: 14,
                    onPressed: () => showOffRoadEditor(context, ref),
                  ),
                  const SizedBox(width: 8),
                ],
                ReportDownloadButton(
                  doc: ReportDoc.offRoad,
                  date: ref.watch(reportDateProvider),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (cases.isEmpty)
              const EmptyState(
                message: 'No bus was off the road on this date.',
              )
            else
              for (final item in cases) ...<Widget>[
                _CaseCard(item: item, today: date, canEdit: canEdit),
                const SizedBox(height: 10),
              ],
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }
}

class _CaseCard extends ConsumerStatefulWidget {
  const _CaseCard({
    required this.item,
    required this.today,
    required this.canEdit,
  });

  final OffRoadCase item;
  final String today;
  final bool canEdit;

  @override
  ConsumerState<_CaseCard> createState() => _CaseCardState();
}

class _CaseCardState extends ConsumerState<_CaseCard> {
  bool _busy = false;

  Future<void> _close() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(reportControllerProvider)
          .closeOffRoad(widget.item, widget.today);
      ref
          .read(toastProvider.notifier)
          .show('${widget.item.registrationNo} back on the road');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final overdue = item.overdueAgainst(widget.today);

    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(item.registrationNo, style: AppText.mono(size: 14)),
              const SizedBox(width: 8),
              if (item.model.isNotEmpty)
                Text(item.model, style: AppText.meta),
              const Spacer(),
              TagBadge(
                label: item.category.label,
                background: T.subtleFill,
                foreground: T.secondary,
              ),
              const SizedBox(width: 6),
              TagBadge(
                label: '${item.daysDown}d',
                background: item.isHeld ? T.redTint : T.subtleFill,
                foreground: item.isHeld ? T.redInk : T.secondary,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(item.issue, style: AppText.cardTitle),
          if ((item.actionTaken ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(item.actionTaken!, style: AppText.bodyText),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: <Widget>[
              _Fact(label: 'Down since', value: Dates.dayLabel(item.offRoadSince)),
              if (item.expectedReadyOn != null)
                _Fact(
                  label: overdue ? 'Was due' : 'Expected back',
                  value: Dates.dayLabel(item.expectedReadyOn!),
                  tone: overdue ? T.redInk : null,
                ),
              if ((item.spareParts ?? '').isNotEmpty)
                _Fact(label: 'Awaiting part', value: item.spareParts!),
              if (item.awaitingVendor)
                const _Fact(label: 'Blocked on', value: 'Vendor'),
            ],
          ),
          if ((item.remarks ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(item.remarks!, style: AppText.meta),
          ],
          if (widget.canEdit) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => showOffRoadEditor(context, ref, existing: item),
                  child: Text(
                    'Update',
                    style: AppText.sans(
                      size: 13,
                      weight: FontWeight.w700,
                      color: T.body,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : _close,
                  child: Text(
                    _busy ? 'Working…' : 'Back on road',
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
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label.toUpperCase(), style: AppText.sans(size: 10, color: T.muted)),
        const SizedBox(height: 1),
        Text(
          value,
          style: AppText.sans(
            size: 12.5,
            weight: FontWeight.w600,
            color: tone ?? T.ink,
          ),
        ),
      ],
    );
  }
}

/// Put a bus off the road, or update the case it already has.
Future<void> showOffRoadEditor(
  BuildContext context,
  WidgetRef ref, {
  OffRoadCase? existing,
}) {
  return showEditorSheet<void>(
    context: context,
    builder: (_) => _OffRoadSheet(existing: existing),
  );
}

class _OffRoadSheet extends ConsumerStatefulWidget {
  const _OffRoadSheet({this.existing});

  final OffRoadCase? existing;

  @override
  ConsumerState<_OffRoadSheet> createState() => _OffRoadSheetState();
}

class _OffRoadSheetState extends ConsumerState<_OffRoadSheet> {
  late String _vehicleId = widget.existing?.vehicleId ?? '';
  late DefectCategory _category =
      widget.existing?.category ?? DefectCategory.mechanical;
  late String _since = widget.existing?.offRoadSince ?? Dates.today();
  late final TextEditingController _issue =
      TextEditingController(text: widget.existing?.issue ?? '');
  late final TextEditingController _action =
      TextEditingController(text: widget.existing?.actionTaken ?? '');
  late final TextEditingController _days = TextEditingController(
    text: widget.existing?.expectedDays?.toString() ?? '',
  );
  late final TextEditingController _parts =
      TextEditingController(text: widget.existing?.spareParts ?? '');
  late final TextEditingController _remarks =
      TextEditingController(text: widget.existing?.remarks ?? '');
  late bool _vendor = widget.existing?.awaitingVendor ?? false;
  bool _busy = false;

  @override
  void dispose() {
    _issue.dispose();
    _action.dispose();
    _days.dispose();
    _parts.dispose();
    _remarks.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_vehicleId.isEmpty || _issue.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(reportControllerProvider).putOffRoad(
            vehicleId: _vehicleId,
            issue: _issue.text.trim(),
            category: _category,
            offRoadSince: _since,
            actionTaken: _action.text.trim(),
            expectedDays: int.tryParse(_days.text.trim()),
            spareParts: _parts.text.trim(),
            remarks: _remarks.text.trim(),
            awaitingVendor: _vendor,
          );
      if (mounted) Navigator.of(context).pop();
      ref.read(toastProvider.notifier).show('Off-road list updated');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fleet =
        ref.watch(siteVehiclesProvider).valueOrNull ?? const <Vehicle>[];
    final active = fleet.where((v) => v.isActive).toList();
    final existing = widget.existing;

    return EditorSheet(
      title: existing == null
          ? 'Put a bus off the road'
          : existing.registrationNo,
      subtitle: 'One open case per bus — two faults is still one bus down.',
      action: FilledActionButton(
        label: _busy ? 'Saving…' : 'Save',
        expand: true,
        onPressed: _busy ||
                (_vehicleId.isEmpty && existing == null) ||
                _issue.text.trim().isEmpty
            ? null
            : _save,
      ),
      children: <Widget>[
            if (existing == null) ...<Widget>[
              const FieldLabel(label: 'Bus No', required: true),
              const SizedBox(height: 6),
              AppSelect(
                value: _registrationOf(active),
                options: active.map((v) => v.registrationNo).toList(),
                placeholder: 'Pick a bus',
                mono: true,
                onChanged: (reg) => setState(() {
                  _vehicleId = active
                      .firstWhere((v) => v.registrationNo == reg,
                          orElse: () => active.first)
                      .id;
                }),
              ),
              const SizedBox(height: 14),
            ],
            const FieldLabel(label: 'Issue', required: true),
            const SizedBox(height: 6),
            AppTextField(
              controller: _issue,
              placeholder: 'What is wrong with it',
              rows: 2,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Category'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final c in DefectCategory.values)
                  PillChip(
                    label: c.label,
                    selected: _category == c,
                    dense: true,
                    fontSize: 12,
                    tone: ChipTone.green,
                    onTap: () => setState(() => _category = c),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Down since'),
                      const SizedBox(height: 6),
                      OutlineActionButton(
                        label: Dates.dayLabel(_since),
                        fontSize: 14,
                        onPressed: _pickSince,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Expected days', hint: 'to fix'),
                      const SizedBox(height: 6),
                      AppTextField(
                        controller: _days,
                        placeholder: 'e.g. 5',
                        numeric: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Action taken'),
            const SizedBox(height: 6),
            AppTextField(
              controller: _action,
              placeholder: 'What has been done so far',
              rows: 2,
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Spare parts required'),
            const SizedBox(height: 6),
            AppTextField(controller: _parts, placeholder: 'Or leave blank'),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Remarks'),
            const SizedBox(height: 6),
            AppTextField(controller: _remarks, placeholder: 'Optional'),
            const SizedBox(height: 12),
            PillChip(
              label: _vendor
                  ? 'Blocked on a vendor'
                  : 'Not blocked on a vendor',
              selected: _vendor,
              dense: true,
              fontSize: 12.5,
              onTap: () => setState(() => _vendor = !_vendor),
            ),
      ],
    );
  }

  String _registrationOf(List<Vehicle> fleet) {
    for (final v in fleet) {
      if (v.id == _vehicleId) return v.registrationNo;
    }
    return '';
  }

  Future<void> _pickSince() async {
    final current = Dates.parse(_since) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 1),
      lastDate: DateTime(current.year + 1),
    );
    if (picked != null) setState(() => _since = Dates.iso(picked));
  }
}
