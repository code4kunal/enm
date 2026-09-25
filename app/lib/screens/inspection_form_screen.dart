import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/docking_km.dart';
import '../data/repositories.dart';
import '../models/checklist.dart';
import '../models/site.dart';
import '../router.dart';
import '../state/inspections.dart';
import '../state/providers.dart';
import '../state/schedule.dart';
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
  List<String> _doneBy = <String>[];
  String _supervisor = '';
  bool _saving = false;
  String? _error;

  /// Multiple Bus Inspection — one shared checklist/date/supervisor answered
  /// once and submitted for every selected bus. Not offered for docking:
  /// each bus can be on a different KM rung, which this form has no way to
  /// pick per-vehicle without turning this into a different screen.
  bool _multiMode = false;
  List<String> _multiRegistrations = <String>[];

  /// Docking (P.M) KM sheet — null until the mechanic picks one (or a booking
  /// pre-fills it).
  int? _milestoneKm;

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

  void _clearAnswers() {
    for (final c in _notes.values) {
      c.dispose();
    }
    _notes.clear();
    _results.clear();
  }

  TextEditingController _noteFor(String itemId) =>
      _notes.putIfAbsent(itemId, TextEditingController.new);

  int? _bookedKm(String vehicleId, calendar) {
    if (vehicleId.isEmpty || calendar == null) return null;
    for (final day in calendar.days) {
      for (final slot in day.slots) {
        if (slot.vehicleId == vehicleId &&
            slot.workTypeId == widget.workTypeId &&
            slot.status.isOpen &&
            slot.servicePlanKm != null) {
          return slot.servicePlanKm;
        }
      }
    }
    return null;
  }

  Future<void> _save(Checklist checklist, {required bool isDocking}) async {
    if (_vehicleId.isEmpty) {
      setState(() => _error = 'Pick the bus this was done on.');
      return;
    }
    if (isDocking && _milestoneKm == null) {
      setState(() => _error = 'Pick the KM range for this docking.');
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
            doneBy: _doneBy.isEmpty ? null : _doneBy.join(', '),
            supervisor: _supervisor,
            odometerKm: int.tryParse(_odometer.text.trim()),
            remarks: _remarks.text.trim(),
            milestoneKm: isDocking ? _milestoneKm : null,
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

  Future<void> _saveBatch(Checklist checklist, List<Vehicle> fleet) async {
    final vehicleIds = <String>[
      for (final reg in _multiRegistrations)
        fleet.firstWhere((v) => v.registrationNo == reg).id,
    ];
    if (vehicleIds.isEmpty) {
      setState(() => _error = 'Pick at least one bus.');
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
      final entries = await ref.read(inspectionControllerProvider).recordBatch(
            workTypeId: checklist.workTypeId,
            inspectedOn: _date,
            entryTime: Dates.nowClock(),
            supervisor: _supervisor,
            items: <InspectionBatchItem>[
              for (final vehicleId in vehicleIds)
                InspectionBatchItem(vehicleId: vehicleId, results: results),
            ],
          );
      final failed = entries.where((e) => !e.isClean).length;
      ref.read(toastProvider.notifier).show(
            failed == 0
                ? '${entries.length} buses recorded'
                : '${entries.length} buses recorded — $failed to follow up',
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
    final masterRaw = ref.watch(masterDataProvider).valueOrNull;
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final master = (masterRaw != null && masterRaw.siteCode == site)
        ? masterRaw
        : null;
    final fleetRaw =
        ref.watch(siteVehiclesProvider).valueOrNull ?? const <Vehicle>[];
    // siteVehiclesProvider always refetches for session.site; still filter in
    // case a previous AsyncData briefly lingers across a switch.
    final fleet =
        fleetRaw.where((v) => site.isEmpty || v.siteCode == site).toList();
    final active = fleet.where((v) => v.isActive).toList();

    final mechanics = ref.watch(mechanicStaffProvider).valueOrNull ?? const <String>[];
    final supervisors = ref.watch(supervisorStaffProvider).valueOrNull ?? const <String>[];
    final mechanicOptions = mechanics.isNotEmpty ? mechanics : (master?.staff ?? const <String>[]);
    final supervisorOptions = supervisors.isNotEmpty ? supervisors : (master?.staff ?? const <String>[]);

    ref.listen<String>(sessionProvider.select((s) => s.site), (prev, next) {
      if (prev == null || prev.isEmpty || prev == next) return;
      setState(() {
        _vehicleId = '';
        _doneBy = <String>[];
        _supervisor = '';
        _milestoneKm = null;
        _multiRegistrations = <String>[];
        _clearAnswers();
      });
    });

    final checklistsAsync = ref.watch(checklistsProvider);
    final allChecklists = checklistsAsync.valueOrNull ?? const <Checklist>[];
    final forWorkType =
        allChecklists.where((c) => c.workTypeId == widget.workTypeId).toList();

    // Prefer an explicit P.M / docking template; fall back to the home-card
    // representative so we still show the KM picker while templates load.
    final typeHint = ref
        .watch(inspectionTypesProvider)
        .where((c) => c.workTypeId == widget.workTypeId)
        .firstOrNull;
    final codeUpper = (forWorkType.isNotEmpty
            ? forWorkType.first.workTypeCode
            : (typeHint?.workTypeCode ?? ''))
        .toUpperCase();
    final isDocking = forWorkType.any((c) => c.isDocking) ||
        codeUpper == 'P.M' ||
        codeUpper == 'PM' ||
        (typeHint?.isDocking ?? false);

    // Wait for templates before deciding the sheet is missing — otherwise a
    // slow checklists fetch briefly hides the KM picker and looks broken.
    if (checklistsAsync.isLoading && forWorkType.isEmpty) {
      return const EmptyState(message: 'Loading the checklist…');
    }

    // The checklist follows the bus (and for docking, the selected KM rung).
    final variant = fleet
        .where((v) => v.id == _vehicleId)
        .map((v) => v.checklistVariant)
        .firstOrNull;
    final calendar = ref.watch(calendarProvider).valueOrNull;

    // Always offer the full docking ladder; prefer sheets that exist for this
    // bus type when the catalogue is synced.
    final kmOptions = <int>{
      for (final c in forWorkType)
        if (c.milestoneKm != null &&
            (variant == null ||
                variant.isEmpty ||
                c.variant == variant ||
                c.variant == null))
          c.milestoneKm!,
    }.toList()
      ..sort();
    final kmLadder =
        kmOptions.isNotEmpty ? kmOptions : List<int>.from(kDockingMilestoneKm);

    final checklist = ref.watch(
      checklistForProvider(
        (
          workTypeId: widget.workTypeId,
          variant: variant,
          milestoneKm: isDocking ? _milestoneKm : null,
        ),
      ),
    );

    if (checklist == null && !isDocking) {
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
              _Heading(
                checklist: checklist,
                workTypeFallback: forWorkType.isNotEmpty
                    ? forWorkType.first
                    : null,
              ),
              const SizedBox(height: 16),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (!isDocking) ...<Widget>[
                      SubTabs(
                        labels: const <String>['Single bus', 'Multiple buses'],
                        selectedIndex: _multiMode ? 1 : 0,
                        onChanged: (i) => setState(() {
                          _multiMode = i == 1;
                          if (_multiMode) {
                            _vehicleId = '';
                          } else {
                            _multiRegistrations = <String>[];
                          }
                          _clearAnswers();
                        }),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_multiMode) ...<Widget>[
                      const FieldLabel(label: 'Buses', required: true),
                      const SizedBox(height: 6),
                      AppMultiSelect(
                        values: _multiRegistrations,
                        options: active.map((v) => v.registrationNo).toList(),
                        placeholder: 'Select buses…',
                        emptyHint: 'No active buses',
                        onChanged: (v) => setState(() => _multiRegistrations = v),
                      ),
                      const SizedBox(height: 16),
                    ] else ...<Widget>[
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
                          _clearAnswers();
                          // Prefill from an open docking booking when present.
                          _milestoneKm = isDocking
                              ? _bookedKm(_vehicleId, calendar)
                              : null;
                        }),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (!_multiMode && _vehicleId.isNotEmpty) ...<Widget>[
                      Text(
                        'Bus Type: ${fleet.where((v) => v.id == _vehicleId).map((v) => v.busTypeLabel).firstOrNull ?? '—'}',
                        style: AppText.sans(
                          size: 13.5,
                          weight: FontWeight.w600,
                          color: T.secondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (isDocking) ...<Widget>[
                      const FieldLabel(label: 'KM range', required: true),
                      const SizedBox(height: 6),
                      AppSelect(
                        value: _milestoneKm == null
                            ? ''
                            : formatDockingKm(_milestoneKm!),
                        options: [
                          for (final km in kmLadder) formatDockingKm(km),
                        ],
                        placeholder: 'Select docking KM…',
                        emptyHint: 'No KM sheets — Sync catalogue on Site → Checklists',
                        onChanged: (label) => setState(() {
                          _clearAnswers();
                          if (label == null || label.isEmpty) {
                            _milestoneKm = null;
                            return;
                          }
                          _milestoneKm = kmLadder.firstWhere(
                            (k) => formatDockingKm(k) == label,
                            orElse: () => kmLadder.first,
                          );
                        }),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _milestoneKm == null
                            ? 'Pick the KM rung to load that docking checklist.'
                            : (checklist == null || checklist.isEmpty)
                                ? 'No sheet for ${formatDockingKm(_milestoneKm!)}'
                                    '${variant == null || variant.isEmpty ? '' : ' · $variant'}'
                                    ' — Sync catalogue or edit Site → Checklists.'
                                : 'Checklist loaded: ${formatDockingKm(_milestoneKm!)}'
                                    '${variant == null || variant.isEmpty ? '' : ' · $variant'}'
                                    ' · ${checklist.items.length} checks',
                        style: AppText.sans(size: 12.5, color: T.secondary),
                      ),
                      const SizedBox(height: 16),
                    ],
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
                              const FieldLabel(
                                label: 'Done by',
                                master: true,
                                hint: '— one or more',
                              ),
                              const SizedBox(height: 6),
                              AppMultiSelect(
                                values: _doneBy,
                                options: mechanicOptions,
                                placeholder: 'Select technician(s)…',
                                emptyHint: 'No technicians loaded',
                                onChanged: (v) => setState(() => _doneBy = v),
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
                                label: 'Supervisor',
                                master: true,
                              ),
                              const SizedBox(height: 6),
                              AppSelect(
                                value: _supervisor,
                                options: supervisorOptions,
                                placeholder: 'Select…',
                                emptyHint: 'No supervisors loaded',
                                onChanged: (v) =>
                                    setState(() => _supervisor = v ?? ''),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const FieldLabel(label: 'Remarks'),
                    const SizedBox(height: 6),
                    AppTextField(
                      controller: _remarks,
                      placeholder: 'Optional',
                      rows: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (isDocking && _milestoneKm == null)
                const EmptyState(
                  message: 'Select a KM range above to load the docking checklist.',
                )
              else if (checklist == null || checklist.isEmpty)
                EmptyState(
                  message: isDocking
                      ? 'No checklist for this bus type at '
                          '${formatDockingKm(_milestoneKm!)}. '
                          'Sync the catalogue or edit Site → Checklists.'
                      : 'This site has not written a checklist for this '
                          'inspection yet.',
                )
              else ...<Widget>[
                ..._sections(checklist),
                const SizedBox(height: 16),
                if (_error != null) InlineError(message: _error!),
                FilledActionButton(
                  label: _saving
                      ? 'Saving…'
                      : _multiMode
                          ? 'Save for ${_multiRegistrations.length} buses'
                          : 'Save inspection',
                  expand: true,
                  onPressed: _saving
                      ? null
                      : _multiMode
                          ? () => _saveBatch(checklist, fleet)
                          : () => _save(checklist, isDocking: isDocking),
                ),
                const SizedBox(height: 40),
              ],
              if (_error != null &&
                  (checklist == null ||
                      checklist.isEmpty ||
                      (isDocking && _milestoneKm == null))) ...<Widget>[
                const SizedBox(height: 12),
                InlineError(message: _error!),
              ],
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
          if (isReading ||
              result == CheckResult.notOk ||
              result == CheckResult.ok) ...<Widget>[
            const SizedBox(height: 6),
            AppTextField(
              controller: _noteFor(item.id),
              placeholder: isReading
                  ? 'Reading'
                  : (result == CheckResult.notOk
                      ? 'What is wrong'
                      : 'Additional remarks (optional)'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({this.checklist, this.workTypeFallback});

  final Checklist? checklist;
  final Checklist? workTypeFallback;

  static String _fmtKm(int km) => formatDockingKm(km);

  @override
  Widget build(BuildContext context) {
    final c = checklist ?? workTypeFallback;
    final code = c?.workTypeCode ?? 'P.M';
    final name = c?.workTypeName ?? 'Preventive maintenance docking';
    final meta = checklist == null
        ? 'Pick bus and KM range to load the sheet'
        : (checklist!.isEmpty
            ? 'No checks on this sheet yet'
            : '${checklist!.items.length} checks · '
                '${checklist!.required.length} required'
                '${checklist!.variant == null ? '' : ' · ${checklist!.variant}'}'
                '${checklist!.milestoneKm == null ? '' : ' · ${_fmtKm(checklist!.milestoneKm!)}'}');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TagBadge(
          label: code,
          background: T.indigoTint,
          foreground: T.indigo,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(name, style: AppText.pageTitle),
              const SizedBox(height: 2),
              Text(meta, style: AppText.meta),
            ],
          ),
        ),
      ],
    );
  }
}
