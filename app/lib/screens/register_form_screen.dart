import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/registers.dart';
import '../data/repositories.dart';
import '../models/entry.dart';
import '../models/register.dart';
import '../models/report.dart';
import '../router.dart';
import '../state/entries.dart';
import '../state/providers.dart';
import '../state/reports.dart';
import '../state/selected_site.dart';
import '../state/session.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/code_square.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';

/// New-entry and edit-entry form. Exactly one of [registerId] / [entryId] is
/// supplied; on edit the register is derived from the entry.
class RegisterFormScreen extends ConsumerStatefulWidget {
  const RegisterFormScreen({super.key, this.registerId, this.entryId});

  final String? registerId;
  final String? entryId;

  @override
  ConsumerState<RegisterFormScreen> createState() => _RegisterFormScreenState();
}

class _RegisterFormScreenState extends ConsumerState<RegisterFormScreen> {
  /// Live values keyed by [FieldDef.key].
  final Map<String, String> _values = <String, String>{};

  /// Controllers for the text-backed field types only.
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  bool _photoAttached = false;
  bool _saving = false;
  bool _initialised = false;

  /// The entry being edited, resolved once from the store.
  RegisterEntry? _editing;

  // --- Unit section — Daily Work Done only ---------------------------------
  //
  // A unit fit is not a register entry (`FittedUnit` has no FK to `entries`,
  // Bus History reads it directly) — this section is a visual convenience
  // that makes a second, independent `fitUnit` call alongside the Work Done
  // entry's own save, not a new field on `work_done_entries`.
  int? _unitTypeId;
  final _unitNoController = TextEditingController();
  final _odometerController = TextEditingController();
  final _unitRemarksController = TextEditingController();

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _unitNoController.dispose();
    _odometerController.dispose();
    _unitRemarksController.dispose();
    super.dispose();
  }

  /// Seeds the form on first build, once entries have loaded.
  ///
  /// New entries default Date to today and — on Daily Work Done — auto-pick the
  /// shift from the clock.
  void _initialise(RegisterDef register, RegisterEntry? existing) {
    if (_initialised) return;
    _initialised = true;
    _editing = existing;

    if (existing != null) {
      _values.addAll(existing.data);
      _values['date'] = existing.date;
    } else {
      _values['date'] = Dates.today();
      if (register.id == 'work') _values['shift'] = Dates.currentShift();
    }

    for (final f in register.fields) {
      if (_isTextBacked(f.type)) {
        _controllers[f.key] =
            TextEditingController(text: _values[f.key] ?? '');
      }
    }
  }

  static bool _isTextBacked(FieldType type) =>
      type == FieldType.text || type == FieldType.area || type == FieldType.number;

  void _set(String key, String value) => _values[key] = value;

  Future<void> _pickDate(String key) async {
    final current = Dates.parse(_values[key]) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 3),
      lastDate: DateTime(current.year + 1),
    );
    if (picked != null) setState(() => _set(key, Dates.iso(picked)));
  }

  Future<void> _pickTime(String key) async {
    final parts = (_values[key] ?? '').split(':');
    final initial = parts.length == 2
        ? TimeOfDay(
            hour: int.tryParse(parts[0]) ?? 0,
            minute: int.tryParse(parts[1]) ?? 0,
          )
        : TimeOfDay.now();

    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    setState(() => _set(key, '$hh:$mm'));
  }

  /// Pulls current text-field values into [_values] before validating.
  void _syncControllers() {
    _controllers.forEach((key, c) => _values[key] = c.text);
  }

  Future<void> _save(RegisterDef register) async {
    if (_saving) return;
    _syncControllers();

    final missing = register.fields
        .where((f) => f.required && (_values[f.key] ?? '').trim().isEmpty)
        .toList();
    if (missing.isNotEmpty) {
      ref
          .read(toastProvider.notifier)
          .show('${missing.map((f) => f.label).join(', ')} required');
      return;
    }

    setState(() => _saving = true);
    final entries = ref.read(entriesProvider.notifier);
    final data = Map<String, String>.of(_values)
      ..removeWhere((_, v) => v.trim().isEmpty);

    try {
      final existing = _editing;
      if (existing != null) {
        await entries.edit(original: existing, data: data);
        ref
            .read(toastProvider.notifier)
            .show('Entry updated in ${register.name} register');
      } else {
        await entries.create(registerId: register.id, data: data);
        ref
            .read(toastProvider.notifier)
            .show('Entry saved to ${register.name} register');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ref.read(toastProvider.notifier).show('Could not save — $e');
      }
      return;
    }

    // A unit was picked in the Unit section — fit it as a second, independent
    // action. A failure here must not look like the Work Done entry above
    // (already saved) also failed.
    final unitTypeId = _unitTypeId;
    if (unitTypeId != null) {
      final vehicles = ref.read(siteVehiclesProvider).valueOrNull ?? const [];
      final vehicleId = vehicles
          .where((v) => v.registrationNo == (_values['bus'] ?? ''))
          .map((v) => v.id)
          .firstOrNull;
      if (vehicleId != null) {
        try {
          await ref.read(reportControllerProvider).fitUnit(
                vehicleId: vehicleId,
                unitTypeId: unitTypeId,
                fittedOn: _values['date'] ?? Dates.today(),
                unitNo: _unitNoController.text.trim(),
                fittedOdometerKm: int.tryParse(_odometerController.text.trim()),
                remarks: _unitRemarksController.text.trim(),
              );
          ref.read(toastProvider.notifier).show('Unit fitted');
        } catch (e) {
          ref
              .read(toastProvider.notifier)
              .show('Entry saved, but the unit could not be fitted — $e');
        }
      }
    }

    if (mounted) _close();
  }

  void _close() {
    // Editing started from Registers; a new entry started from Home (or from
    // Breakdowns for a new breakdown report).
    if (_editing != null) {
      context.go(Routes.registers);
    } else if (widget.registerId == kBreakdownRegisterId) {
      context.go(Routes.breakdowns);
    } else {
      context.go(Routes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(entriesProvider);
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final siteOpsId =
        ref.watch(selectedSiteProvider.select((s) => s.id)) ?? '';
    // Same scope key as [masterDataProvider] — E&M code, else SiteOps UUID.
    final scopeKey = site.isNotEmpty ? site : siteOpsId;
    final masterRaw =
        ref.watch(masterDataProvider).valueOrNull ?? MasterData.empty;
    // Drop a previous depot's bundle while the new site's fetch is in flight.
    final master =
        masterRaw.siteCode == scopeKey ? masterRaw : MasterData.empty;
    final technicianStaff = ref.watch(technicianStaffProvider).valueOrNull ?? const <String>[];
    final supervisorStaff = ref.watch(supervisorStaffProvider).valueOrNull ?? const <String>[];
    final mechanicStaff = ref.watch(mechanicStaffProvider).valueOrNull ?? const <String>[];
    final siteLabel = ref.watch(siteDisplayNameProvider);
    final isMobile = MediaQuery.sizeOf(context).width < T.mobileBreakpoint;

    // Header site switch must drop bus/staff picks from the previous depot.
    void clearSitePicks() {
      setState(() {
        for (final key in <String>[
          'bus',
          'employee',
          'supervisor',
          'mechanic',
        ]) {
          if (_values.containsKey(key)) _values[key] = '';
        }
      });
    }

    ref.listen<String>(sessionProvider.select((s) => s.site), (prev, next) {
      if (prev == null || prev.isEmpty || prev == next) return;
      clearSitePicks();
    });
    ref.listen<String?>(selectedSiteProvider.select((s) => s.id), (prev, next) {
      if (prev == null || prev.isEmpty || prev == next) return;
      clearSitePicks();
    });

    // On an edit route the entry has to load before the form can seed itself.
    RegisterEntry? existing;
    if (widget.entryId != null) {
      if (entriesAsync.isLoading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 64),
          child: Center(child: CircularProgressIndicator(color: T.green)),
        );
      }
      final all = entriesAsync.valueOrNull ?? const <RegisterEntry>[];
      existing = all.where((e) => e.id == widget.entryId).firstOrNull;
      if (existing == null) {
        // Deep link to an entry that is not in the active site's set.
        return const EmptyState(
          message: 'That entry is no longer available at this site.',
        );
      }
    }

    final register = registerById(
      existing?.registerId ?? widget.registerId ?? '',
    );
    if (register == null) {
      return const EmptyState(message: 'Unknown register.');
    }

    _initialise(register, existing);

    return FadeUp(
      key: ValueKey<String>(
        'form-${register.id}-${widget.entryId ?? 'new'}-$scopeKey',
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.maxFormWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              BackLink(onTap: _close),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  CodeSquare(
                    code: register.code,
                    color: register.color,
                    size: 44,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          register.name,
                          style: AppText.sans(
                            size: 21,
                            weight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '$siteLabel ($site) · '
                          '${existing == null ? 'New entry' : 'Editing entry'}',
                          style: AppText.sans(size: 13, color: T.secondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 22,
                ),
                decoration: BoxDecoration(
                  color: T.card,
                  borderRadius: T.cardShape,
                  border: Border.all(color: T.border),
                ),
                child: _FieldGrid(
                  register: register,
                  master: master,
                  technicianStaff: technicianStaff,
                  supervisorStaff: supervisorStaff,
                  mechanicStaff: mechanicStaff,
                  isMobile: isMobile,
                  values: _values,
                  controllers: _controllers,
                  onSet: (k, v) => setState(() => _set(k, v)),
                  onPickDate: _pickDate,
                  onPickTime: _pickTime,
                  photoAttached: _photoAttached,
                  onTogglePhoto: () =>
                      setState(() => _photoAttached = !_photoAttached),
                ),
              ),
              if (register.id == 'work') ...<Widget>[
                const SizedBox(height: 16),
                _UnitSection(
                  unitTypeId: _unitTypeId,
                  unitNoController: _unitNoController,
                  odometerController: _odometerController,
                  remarksController: _unitRemarksController,
                  onUnitTypeChanged: (id) => setState(() => _unitTypeId = id),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  OutlineActionButton(
                    label: 'Cancel',
                    onPressed: _saving ? null : _close,
                    fontSize: 16,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 15,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledActionButton(
                      label: _saving ? 'Saving…' : 'Save entry',
                      onPressed: _saving ? null : () => _save(register),
                      fontSize: 16.5,
                      elevated: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 15,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// Optional unit-fitting block on the Daily Work Done form.
///
/// A visual convenience, not a new field on `work_done_entries` — filling it
/// in makes a second, independent `fitUnit` call when the entry is saved.
/// Leaving Unit unpicked (the default) submits the Work Done entry exactly
/// as before, with nothing added.
class _UnitSection extends ConsumerWidget {
  const _UnitSection({
    required this.unitTypeId,
    required this.unitNoController,
    required this.odometerController,
    required this.remarksController,
    required this.onUnitTypeChanged,
  });

  final int? unitTypeId;
  final TextEditingController unitNoController;
  final TextEditingController odometerController;
  final TextEditingController remarksController;
  final ValueChanged<int?> onUnitTypeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(unitTypesProvider).valueOrNull ?? const <UnitType>[];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Unit', style: AppText.sans(size: 15, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Fitting a component here starts its life the same as Reports → '
            'Units — it reaches the bus history and failure statement when '
            'it comes off. Leave blank if this entry has nothing to do with '
            'a unit.',
            style: AppText.sans(size: 12.5, color: T.secondary, height: 1.4),
          ),
          const SizedBox(height: 14),
          const FieldLabel(label: 'Unit'),
          const SizedBox(height: 6),
          AppSelect(
            value: types
                .where((t) => t.id == unitTypeId)
                .map((t) => t.name)
                .firstOrNull,
            options: types.map((t) => t.name).toList(),
            placeholder: 'Not fitting a unit on this entry',
            onChanged: (name) => onUnitTypeChanged(
              types.where((t) => t.name == name).map((t) => t.id).firstOrNull,
            ),
          ),
          if (unitTypeId != null) ...<Widget>[
            const SizedBox(height: 14),
            const FieldLabel(label: 'Unit No'),
            const SizedBox(height: 6),
            AppTextField(
              controller: unitNoController,
              placeholder: 'The maker’s serial, if it has one',
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Odometer at fitting'),
            const SizedBox(height: 6),
            AppTextField(
              controller: odometerController,
              placeholder: 'Leave blank to use the bus’s last reading',
              numeric: true,
            ),
            const SizedBox(height: 14),
            const FieldLabel(label: 'Remarks'),
            const SizedBox(height: 6),
            AppTextField(controller: remarksController, placeholder: 'Optional'),
          ],
        ],
      ),
    );
  }
}

/// Wrapped two-column field grid. Widths follow [FieldWidth]; on mobile
/// everything collapses to full width except the time triplet, which steps
/// down to half so the three breakdown stamps stay compact.
class _FieldGrid extends StatelessWidget {
  const _FieldGrid({
    required this.register,
    required this.master,
    required this.technicianStaff,
    required this.supervisorStaff,
    required this.mechanicStaff,
    required this.isMobile,
    required this.values,
    required this.controllers,
    required this.onSet,
    required this.onPickDate,
    required this.onPickTime,
    required this.photoAttached,
    required this.onTogglePhoto,
  });

  final RegisterDef register;
  final MasterData master;
  final List<String> technicianStaff;
  final List<String> supervisorStaff;
  final List<String> mechanicStaff;
  final bool isMobile;
  final Map<String, String> values;
  final Map<String, TextEditingController> controllers;
  final void Function(String key, String value) onSet;
  final Future<void> Function(String key) onPickDate;
  final Future<void> Function(String key) onPickTime;
  final bool photoAttached;
  final VoidCallback onTogglePhoto;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        final gap = total * 0.04;

        double widthFor(FieldWidth w) {
          final effective = isMobile
              ? (w == FieldWidth.third ? FieldWidth.half : FieldWidth.full)
              : w;
          switch (effective) {
            case FieldWidth.full:
              return total;
            case FieldWidth.half:
              return (total - gap) / 2;
            case FieldWidth.third:
              return (total - gap * 2) / 3;
          }
        }

        return Wrap(
          spacing: gap,
          runSpacing: 16,
          children: <Widget>[
            for (final f in register.fields)
              SizedBox(
                width: widthFor(f.width),
                child: _Field(
                  registerId: register.id,
                  def: f,
                  master: master,
                  technicianStaff: technicianStaff,
                  supervisorStaff: supervisorStaff,
                  mechanicStaff: mechanicStaff,
                  value: values[f.key] ?? '',
                  controller: controllers[f.key],
                  onSet: onSet,
                  onPickDate: onPickDate,
                  onPickTime: onPickTime,
                ),
              ),
            SizedBox(
              width: total,
              child: PhotoAttachButton(
                attached: photoAttached,
                onToggle: onTogglePhoto,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.registerId,
    required this.def,
    required this.master,
    required this.technicianStaff,
    required this.supervisorStaff,
    required this.mechanicStaff,
    required this.value,
    required this.controller,
    required this.onSet,
    required this.onPickDate,
    required this.onPickTime,
  });

  final String registerId;
  final FieldDef def;
  final MasterData master;
  final List<String> technicianStaff;
  final List<String> supervisorStaff;
  final List<String> mechanicStaff;
  final String value;
  final TextEditingController? controller;
  final void Function(String key, String value) onSet;
  final Future<void> Function(String key) onPickDate;
  final Future<void> Function(String key) onPickTime;

  List<String> get _options {
    if ((registerId == 'work' || registerId == 'coolant') && def.key == 'employee') {
      return technicianStaff.isNotEmpty
          ? technicianStaff
          : master.staff;
    }
    if (def.key == 'supervisor') {
      return supervisorStaff.isNotEmpty
          ? supervisorStaff
          : master.staff;
    }
    if (registerId == 'complaint' && def.key == 'mechanic') {
      return mechanicStaff.isNotEmpty
          ? mechanicStaff
          : master.staff;
    }

    switch (def.optionsFrom) {
      case MasterList.defectSources:
        return master.defectSources;
      case MasterList.defectTypes:
        return master.defectTypes;
      case MasterList.staff:
        return master.staff;
      case null:
        return const <String>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FieldLabel(
          label: def.label,
          required: def.required,
          master: def.isMasterBacked,
        ),
        _control(),
      ],
    );
  }

  Widget _control() {
    switch (def.type) {
      case FieldType.text:
        return AppTextField(
          controller: controller!,
          placeholder: def.placeholder,
          onChanged: (v) => onSet(def.key, v),
        );

      case FieldType.area:
        return AppTextField(
          controller: controller!,
          placeholder: def.placeholder,
          rows: def.rows,
          onChanged: (v) => onSet(def.key, v),
        );

      case FieldType.number:
        return UnitField(
          controller: controller!,
          unit: def.unit,
          onChanged: (v) => onSet(def.key, v),
        );

      case FieldType.bus:
        return AppSelect(
          value: value,
          options: master.vehicles,
          mono: true,
          placeholder: 'Select bus…',
          emptyHint: 'No buses at this site — open Vehicle Master or Sync fleet',
          onChanged: (v) => onSet(def.key, v ?? ''),
        );

      case FieldType.select:
        return AppSelect(
          value: value,
          options: _options,
          emptyHint: _options.isEmpty
              ? 'No people/options for this site'
              : 'Select…',
          onChanged: (v) => onSet(def.key, v ?? ''),
        );

      case FieldType.seg:
        return SegmentedField(
          options: def.segOptions,
          value: value,
          onChanged: (v) => onSet(def.key, v),
        );

      case FieldType.date:
        return PickerField(
          display: value,
          placeholder: 'yyyy-mm-dd',
          onTap: () => onPickDate(def.key),
        );

      case FieldType.time:
        return PickerField(
          display: value,
          placeholder: '--:--',
          onTap: () => onPickTime(def.key),
        );
    }
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
