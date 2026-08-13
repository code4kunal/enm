import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/inspection.dart';
import '../../models/site.dart';
import '../../state/providers.dart';
import '../../state/schedule.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sheet.dart';

/// Opens the editor for one booking: move it, mark it, annotate it, drop it.
Future<void> showSlotEditor(
  BuildContext context,
  WidgetRef ref,
  InspectionSlot slot,
) {
  return showEditorSheet<void>(
    context: context,
    builder: (_) => _SlotEditorSheet(slot: slot),
  );
}

/// Books a bus in by hand on a chosen night.
Future<void> showSlotCreator(
  BuildContext context,
  WidgetRef ref,
  String date,
) {
  return showEditorSheet<void>(
    context: context,
    builder: (_) => _SlotCreatorSheet(date: date),
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: T.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(title, style: AppText.sectionTitle),
            const SizedBox(height: 4),
            Text(subtitle, style: AppText.meta),
            const SizedBox(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}

class _SlotEditorSheet extends ConsumerStatefulWidget {
  const _SlotEditorSheet({required this.slot});

  final InspectionSlot slot;

  @override
  ConsumerState<_SlotEditorSheet> createState() => _SlotEditorSheetState();
}

class _SlotEditorSheetState extends ConsumerState<_SlotEditorSheet> {
  late String _date = widget.slot.scheduledOn;
  late final TextEditingController _notes =
      TextEditingController(text: widget.slot.notes);
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
      ref.read(toastProvider.notifier).show(done);
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickDate() async {
    final current = Dates.parse(_date) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 1),
      lastDate: DateTime(current.year + 2),
    );
    if (picked != null) setState(() => _date = Dates.iso(picked));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(scheduleControllerProvider);
    final slot = widget.slot;
    final moved = _date != slot.scheduledOn;
    final annotated = _notes.text != slot.notes;

    return _Sheet(
      title: slot.registrationNo,
      subtitle: '${slot.workTypeCode} · ${slot.workTypeName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const FieldLabel(label: 'Scheduled for'),
          const SizedBox(height: 6),
          OutlineActionButton(
            label: Dates.dayLabel(_date),
            onPressed: _busy ? null : _pickDate,
          ),
          if (moved) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Moving this pins it — the nightly run will leave it where you '
              'put it.',
              style: AppText.meta,
            ),
          ],
          const SizedBox(height: 16),
          const FieldLabel(label: 'Note'),
          const SizedBox(height: 6),
          AppTextField(
            controller: _notes,
            placeholder: 'Why this was moved, or what it needs',
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          FilledActionButton(
            label: 'Save',
            expand: true,
            onPressed: _busy || !(moved || annotated)
                ? null
                : () => _run(() async {
                      if (moved) await controller.move(slot, _date);
                      if (annotated) {
                        await controller.annotate(slot, _notes.text.trim());
                      }
                    }, 'Booking updated'),
          ),
          const SizedBox(height: 10),
          if (slot.status != SlotStatus.done)
            OutlineActionButton(
              label: 'Mark done',
              onPressed: _busy
                  ? null
                  : () => _run(
                        () => controller.setStatus(slot, SlotStatus.done),
                        '${slot.registrationNo} marked done',
                      ),
            ),
          const SizedBox(height: 10),
          OutlineActionButton(
            label: 'Remove from the calendar',
            foreground: T.red,
            borderColor: T.redBorderTint,
            onPressed: _busy
                ? null
                : () => _run(
                      () => controller.remove(slot),
                      'Booking removed',
                    ),
          ),
        ],
      ),
    );
  }
}

class _SlotCreatorSheet extends ConsumerStatefulWidget {
  const _SlotCreatorSheet({required this.date});

  final String date;

  @override
  ConsumerState<_SlotCreatorSheet> createState() => _SlotCreatorSheetState();
}

class _SlotCreatorSheetState extends ConsumerState<_SlotCreatorSheet> {
  String? _vehicleId;
  int? _workTypeId;
  final TextEditingController _notes = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final vehicleId = _vehicleId;
    final workTypeId = _workTypeId;
    if (vehicleId == null || workTypeId == null) return;

    setState(() => _busy = true);
    try {
      await ref.read(scheduleControllerProvider).book(
            vehicleId: vehicleId,
            workTypeId: workTypeId,
            date: widget.date,
            notes: _notes.text.trim(),
          );
      if (mounted) Navigator.of(context).pop();
      ref.read(toastProvider.notifier).show('Booked');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fleet = ref.watch(siteVehiclesProvider).valueOrNull ?? const <Vehicle>[];
    final plans =
        ref.watch(inspectionPlansProvider).valueOrNull ?? const <InspectionPlan>[];
    final active = fleet.where((v) => v.isActive).toList();

    return _Sheet(
      title: 'Book an inspection',
      subtitle: Dates.dayLabel(widget.date),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const FieldLabel(label: 'Vehicle'),
          const SizedBox(height: 6),
          AppSelect(
            value: _vehicleId == null
                ? ''
                : active
                    .firstWhere((v) => v.id == _vehicleId,
                        orElse: () => active.first)
                    .registrationNo,
            options: active.map((v) => v.registrationNo).toList(),
            placeholder: 'Pick a bus',
            onChanged: (reg) => setState(() {
              _vehicleId = active
                  .firstWhere((v) => v.registrationNo == reg,
                      orElse: () => active.first)
                  .id;
            }),
          ),
          const SizedBox(height: 16),
          const FieldLabel(label: 'Inspection'),
          const SizedBox(height: 6),
          AppSelect(
            value: _workTypeId == null
                ? ''
                : plans
                    .firstWhere((p) => p.workTypeId == _workTypeId,
                        orElse: () => plans.first)
                    .workTypeCode,
            options: plans.map((p) => p.workTypeCode).toList(),
            placeholder: 'Pick an inspection',
            onChanged: (code) => setState(() {
              _workTypeId = plans
                  .firstWhere((p) => p.workTypeCode == code,
                      orElse: () => plans.first)
                  .workTypeId;
            }),
          ),
          const SizedBox(height: 16),
          const FieldLabel(label: 'Note'),
          const SizedBox(height: 6),
          AppTextField(controller: _notes, placeholder: 'Optional'),
          const SizedBox(height: 20),
          FilledActionButton(
            label: 'Book it',
            expand: true,
            onPressed:
                _busy || _vehicleId == null || _workTypeId == null ? null : _save,
          ),
        ],
      ),
    );
  }
}
