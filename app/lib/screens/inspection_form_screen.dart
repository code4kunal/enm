import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/repositories.dart';
import '../models/checklist.dart';
import '../models/site.dart';
import '../router.dart';
import '../state/inspections.dart';
import '../state/providers.dart';
import '../state/session.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/chips.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';
import '../widgets/sub_tabs.dart';

/// Data entry for one inspection.
///
/// The form *is* the site's checklist: a daily inspection and a ten-day service
/// are different jobs with different sheets, so this screen renders whichever
/// list belongs to the work type it was opened for. There is no shared form and
/// nothing invented — a site that has not written its checklist sees that said
/// plainly rather than a blank set of boxes.
class InspectionFormScreen extends ConsumerStatefulWidget {
  const InspectionFormScreen({super.key, required this.workTypeId});

  final int workTypeId;

  @override
  ConsumerState<InspectionFormScreen> createState() =>
      _InspectionFormScreenState();
}

class _InspectionFormScreenState extends ConsumerState<InspectionFormScreen> {
  String _vehicleId = '';
  String _date = Dates.today();
  String _doneBy = '';
  String _supervisor = '';
  bool _saving = false;
  String? _error;

  final TextEditingController _odometer = TextEditingController();
  final TextEditingController _remarks = TextEditingController();

  /// item id -> answer. Everything defaults to OK: a mechanic marks exceptions,
  /// which is how the paper sheet is filled in too.
  final Map<String, CheckResult> _results = <String, CheckResult>{};
  final Map<String, TextEditingController> _notes =
      <String, TextEditingController>{};

  @override
  void dispose() {
    _odometer.dispose();
    _remarks.dispose();
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _noteFor(String itemId) =>
      _notes.putIfAbsent(itemId, TextEditingController.new);

  Future<void> _save(Checklist checklist) async {
    if (_vehicleId.isEmpty) {
      setState(() => _error = 'Pick the bus this was done on.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final results = <InspectionResult>[
      for (final item in checklist.items)
        InspectionResult(
          itemId: item.id,
          result: _results[item.id] ?? CheckResult.ok,
          value: item.responseType == ResponseType.okNotOk
              ? null
              : _noteFor(item.id).text.trim(),
          remark: item.responseType == ResponseType.okNotOk
              ? _noteFor(item.id).text.trim()
              : null,
        ),
    ];

    try {
      final entry = await ref.read(inspectionControllerProvider).record(
            vehicleId: _vehicleId,
            workTypeId: checklist.workTypeId,
            inspectedOn: _date,
            entryTime: Dates.nowClock(),
            doneBy: _doneBy,
            supervisor: _supervisor,
            odometerKm: int.tryParse(_odometer.text.trim()),
            remarks: _remarks.text.trim(),
            results: results,
          );
      ref.read(toastProvider.notifier).show(
            entry.isClean
                ? '${entry.registrationNo} · ${entry.workTypeCode} recorded'
                : '${entry.registrationNo} recorded — '
                    '${entry.failedCount} to follow up',
          );
      if (mounted) context.go(Routes.home);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final checklist = ref.watch(checklistProvider(widget.workTypeId));
    final master = ref.watch(masterDataProvider).valueOrNull;
    final fleet = ref.watch(siteVehiclesProvider).valueOrNull ?? const <Vehicle>[];
    final active = fleet.where((v) => v.isActive).toList();

    if (checklist == null) {
      return const EmptyState(message: 'Loading the checklist…');
    }

    return FadeUp(
      key: ValueKey<String>('inspection-${widget.workTypeId}'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.maxFormWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              BackLink(onTap: () => context.go(Routes.home)),
              const SizedBox(height: 10),
              _Heading(checklist: checklist),
              const SizedBox(height: 16),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
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
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              const FieldLabel(label: 'Date', required: true),
                              const SizedBox(height: 6),
                              OutlineActionButton(
                                label: Dates.dayLabel(_date),
                                fontSize: 14,
                                onPressed: _pickDate,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              const FieldLabel(
                                label: 'Odometer',
                                hint: 'km',
                              ),
                              const SizedBox(height: 6),
                              AppTextField(
                                controller: _odometer,
                                placeholder: 'e.g. 121000',
                                numeric: true,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              const FieldLabel(label: 'Done by', master: true),
                              const SizedBox(height: 6),
                              AppSelect(
                                value: _doneBy,
                                options: master?.staff ?? const <String>[],
                                placeholder: 'Pick a mechanic',
                                onChanged: (v) =>
                                    setState(() => _doneBy = v ?? ''),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              const FieldLabel(
                                label: 'Supervisor (Floor)',
                                master: true,
                              ),
                              const SizedBox(height: 6),
                              AppSelect(
                                value: _supervisor,
                                options: master?.staff ?? const <String>[],
                                placeholder: 'Pick a supervisor',
                                onChanged: (v) =>
                                    setState(() => _supervisor = v ?? ''),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (checklist.isEmpty)
                _NoChecklistYet(checklist: checklist)
              else
                ..._sections(checklist),
              const SizedBox(height: 16),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const FieldLabel(label: 'Remarks'),
                    const SizedBox(height: 6),
                    AppTextField(
                      controller: _remarks,
                      placeholder: 'Anything the next shift should know',
                      rows: 3,
                    ),
                  ],
                ),
              ),
              if (_error != null) InlineError(message: _error!),
              const SizedBox(height: 20),
              FilledActionButton(
                label: _saving ? 'Saving…' : 'Record inspection',
                expand: true,
                onPressed: _saving || checklist.isEmpty
                    ? null
                    : () => _save(checklist),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  String _registrationOf(List<Vehicle> fleet) {
    for (final v in fleet) {
      if (v.id == _vehicleId) return v.registrationNo;
    }
    return '';
  }

  Future<void> _pickDate() async {
    final current = Dates.parse(_date) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 1),
      lastDate: DateTime(current.year + 1),
    );
    if (picked != null) setState(() => _date = Dates.iso(picked));
  }

  List<Widget> _sections(Checklist checklist) {
    final out = <Widget>[];
    checklist.bySection.forEach((section, items) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  section.isEmpty ? 'Checks' : section,
                  style: AppText.sectionTitle,
                ),
                const SizedBox(height: 12),
                for (final item in items) _line(item),
              ],
            ),
          ),
        ),
      );
    });
    return out;
  }

  Widget _line(ChecklistItem item) {
    final result = _results[item.id] ?? CheckResult.ok;
    final isReading = item.responseType != ResponseType.okNotOk;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  item.label + (item.isRequired ? '' : '  (optional)'),
                  style: AppText.sans(size: 14, weight: FontWeight.w600),
                ),
              ),
              if (!isReading)
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    for (final option in CheckResult.values)
                      PillChip(
                        label: option.label,
                        selected: result == option,
                        dense: true,
                        fontSize: 12,
                        tone: option == CheckResult.notOk
                            ? ChipTone.ink
                            : ChipTone.green,
                        onTap: () =>
                            setState(() => _results[item.id] = option),
                      ),
                  ],
                ),
            ],
          ),
          // A failed line needs a reason; a reading needs its number.
          if (isReading || result == CheckResult.notOk) ...<Widget>[
            const SizedBox(height: 6),
            AppTextField(
              controller: _noteFor(item.id),
              placeholder: isReading ? 'Reading' : 'What is wrong',
            ),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.checklist});

  final Checklist checklist;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TagBadge(
          label: checklist.workTypeCode,
          background: T.indigoTint,
          foreground: T.indigo,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(checklist.workTypeName, style: AppText.pageTitle),
              const SizedBox(height: 2),
              Text(
                checklist.isEmpty
                    ? 'No checklist written for this site yet'
                    : '${checklist.items.length} checks · '
                        '${checklist.required.length} required',
                style: AppText.meta,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NoChecklistYet extends ConsumerWidget {
  const _NoChecklistYet({required this.checklist});

  final Checklist checklist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(sessionProvider).canManageSites;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'This site has no ${checklist.workTypeName.toLowerCase()} '
            'checklist yet',
            style: AppText.cardTitle,
          ),
          const SizedBox(height: 6),
          Text(
            canEdit
                ? 'Add the checks under Site → Master data → Checklists. Nothing '
                    'is filled in for you — the list has to be the depot\'s own.'
                : 'Ask a manager to add it under Site → Master data.',
            style: AppText.bodyText,
          ),
        ],
      ),
    );
  }
}
