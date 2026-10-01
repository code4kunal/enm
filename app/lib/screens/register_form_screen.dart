import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/registers.dart';
import '../data/repositories.dart';
import '../models/entry.dart';
import '../models/register.dart';
import '../models/report.dart';
import '../models/site.dart';
import '../models/spare_part.dart';
import '../models/staff.dart';
import '../models/ticket.dart';
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
import '../widgets/chips.dart';
import '../widgets/code_square.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';
import '../widgets/location_capture.dart';
import '../widgets/location_map.dart';
import '../widgets/sheet.dart';

/// New-entry and edit-entry form. Exactly one of [registerId] / [entryId] is
/// supplied; on edit the register is derived from the entry.
class RegisterFormScreen extends ConsumerStatefulWidget {
  const RegisterFormScreen({
    super.key,
    this.registerId,
    this.entryId,
    this.onClose,
    this.readOnly = false,
  });

  final String? registerId;
  final String? entryId;

  /// Overrides the default close-and-navigate behaviour — set when this
  /// screen is embedded in a modal (a control chart cell's "view this entry"
  /// sheet, say) rather than reached by its own route, so closing pops the
  /// sheet instead of routing the whole app to Registers.
  final VoidCallback? onClose;

  /// Disables every control and hides Save/Unit/TicketLink editing — the
  /// Registers screen's View action, alongside Edit.
  final bool readOnly;

  @override
  ConsumerState<RegisterFormScreen> createState() => _RegisterFormScreenState();
}

class _RegisterFormScreenState extends ConsumerState<RegisterFormScreen> {
  /// Live values keyed by [FieldDef.key].
  final Map<String, String> _values = <String, String>{};

  /// Controllers for the text-backed field types only.
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  /// Newly picked, not-yet-uploaded photos — uploaded on save, once the
  /// entry they attach to exists (or already has an id, when editing).
  final List<_PendingPhoto> _newPhotos = <_PendingPhoto>[];

  /// Existing photo ids the user removed — the removal itself is sent on
  /// save, same as an attach.
  final Set<String> _removedPhotoIds = <String>{};

  bool _saving = false;
  bool _initialised = false;

  /// The entry being edited, resolved once from the store.
  RegisterEntry? _editing;

  // --- Unit section — Daily Work Done only ---------------------------------
  //
  // A unit fit is not a register entry (`FittedUnit` has no FK to `entries`
  // for how a *stay* is read back — Bus History and the statement still read
  // by vehicle + unit_type + date, unchanged). It does carry an optional
  // `entry_id` back-reference now, purely so this list can find "what did
  // this entry touch" without guessing from a shared vehicle+date that a
  // second shift's entry could also match. A day's work can touch more than
  // one component (a battery and a motor, say), so this is a list, not a
  // single pick.
  final List<_UnitDraft> _unitDrafts = <_UnitDraft>[_UnitDraft()];

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final draft in _unitDrafts) {
      draft.dispose();
    }
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

  bool get _hasPhoto => _newPhotos.isNotEmpty || _remainingExistingPhotos.isNotEmpty;

  List<EntryPhoto> get _remainingExistingPhotos => (_editing?.photos ?? const <EntryPhoto>[])
      .where((p) => !_removedPhotoIds.contains(p.id))
      .toList();

  void _onAttachPhoto(String filename, List<int> bytes) => setState(() {
        _newPhotos.add(_PendingPhoto(filename: filename, bytes: bytes));
      });

  /// Single-photo registers only: [PhotoAttachButton] toggles a single
  /// on/off state, so "remove" always means "clear whichever one photo is
  /// currently shown" — an existing one if there's no unsaved pick, else
  /// the unsaved pick itself.
  void _onRemovePhoto() => setState(() {
        if (_newPhotos.isNotEmpty) {
          _newPhotos.removeLast();
        } else {
          final existing = _remainingExistingPhotos;
          if (existing.isNotEmpty) _removedPhotoIds.add(existing.first.id);
        }
      });

  void _onRemoveExistingPhoto(String photoId) =>
      setState(() => _removedPhotoIds.add(photoId));

  void _onRemoveNewPhoto(int index) => setState(() => _newPhotos.removeAt(index));

  /// The single setter every field/picker routes through. Also keeps the
  /// matching [TextEditingController] (if any -- `_isTextBacked` fields
  /// only) in sync: `_syncControllers()` overwrites `_values` from the
  /// controller's own text on save, so a text-backed field set only in
  /// `_values` (e.g. by the ticket-pick auto-fill) would otherwise render
  /// correctly but get silently wiped back to blank on submit.
  ///
  /// Only writes the controller when the text actually differs: an
  /// in-progress edit's own `onChanged` already routes through here with
  /// the controller's current text, and `TextEditingController.text =`
  /// unconditionally resets the caret to the end -- writing back the same
  /// string on every keystroke would throw the caret to the end of the
  /// field mid-edit.
  void _set(String key, String value) {
    _values[key] = value;
    final controller = _controllers[key];
    if (controller != null && controller.text != value) {
      controller.text = value;
    }
  }

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

    if (_values['completesTicket'] == 'true' &&
        (_values['completionTime'] ?? '').isEmpty) {
      ref.read(toastProvider.notifier).show('Resolved-at time required');
      return;
    }

    setState(() => _saving = true);
    final entries = ref.read(entriesProvider.notifier);
    final data = Map<String, String>.of(_values)
      ..removeWhere((_, v) => v.trim().isEmpty);

    RegisterEntry saved;
    try {
      final existing = _editing;
      if (existing != null) {
        saved = await entries.edit(original: existing, data: data);
        ref
            .read(toastProvider.notifier)
            .show('Entry updated in ${register.name} register');
      } else {
        saved = await entries.create(registerId: register.id, data: data);
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

    // A photo pick/remove is a second, independent action on the now-saved
    // entry — same reasoning as the unit fit below: its failure must not
    // read as the entry save (already done) having failed.
    for (final photo in _newPhotos) {
      try {
        await entries.attachPhoto(
          entryId: saved.id,
          filename: photo.filename,
          bytes: photo.bytes,
        );
      } catch (_) {
        ref
            .read(toastProvider.notifier)
            .show('Entry saved, but a photo could not be attached');
      }
    }
    for (final photoId in _removedPhotoIds) {
      try {
        await entries.removePhoto(saved.id, photoId);
      } catch (_) {
        ref
            .read(toastProvider.notifier)
            .show('Entry saved, but a photo could not be removed');
      }
    }

    // One or more units were picked in the Unit section — fit each as a
    // second, independent action. A failure here must not look like the
    // Work Done entry above (already saved) also failed.
    final picked = _unitDrafts.where((d) => d.unitTypeId != null).toList();
    if (picked.isNotEmpty) {
      // `.future` rather than a cached `.valueOrNull` — this screen never
      // otherwise watches the provider, so on a session's first Work Done
      // save it would still be loading and every pick would silently no-op.
      List<Vehicle> vehicles;
      try {
        vehicles = await ref.read(siteVehiclesProvider.future);
      } catch (_) {
        vehicles = const [];
      }
      final vehicleId = vehicles
          .where((v) => v.registrationNo == (_values['bus'] ?? ''))
          .map((v) => v.id)
          .firstOrNull;
      if (vehicleId == null) {
        ref.read(toastProvider.notifier).show(
              'Entry saved, but the unit(s) could not be fitted — bus not found',
            );
      } else {
        var fitted = 0;
        var failed = 0;
        for (final draft in picked) {
          try {
            await ref.read(reportControllerProvider).fitUnit(
                  vehicleId: vehicleId,
                  unitTypeId: draft.unitTypeId!,
                  fittedOn: _values['date'] ?? Dates.today(),
                  entryId: saved.id,
                  unitNo: draft.unitNoController.text.trim(),
                  fittedOdometerKm:
                      int.tryParse(draft.odometerController.text.trim()),
                  remarks: draft.remarksController.text.trim(),
                );
            fitted++;
          } catch (_) {
            failed++;
          }
        }
        final message = failed == 0
            ? '$fitted unit${fitted == 1 ? '' : 's'} fitted'
            : 'Entry saved, but $failed of ${picked.length} '
                'unit${picked.length == 1 ? '' : 's'} could not be fitted';
        ref.read(toastProvider.notifier).show(message);
      }
    }

    if (mounted) _close();
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
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
    final fleet =
        ref.watch(siteVehiclesProvider).valueOrNull ?? const <Vehicle>[];
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
                          '$siteLabel ($site)'
                          '${(existing?.displayId ?? '').isNotEmpty ? ' · ${existing!.displayId}' : ''} · '
                          '${widget.readOnly ? 'Viewing entry' : (existing == null ? 'New entry' : 'Editing entry')}',
                          style: AppText.sans(size: 13, color: T.secondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (!widget.readOnly && register.id == 'work') ...<Widget>[
                _TicketLinkSection(
                  values: _values,
                  onSet: (k, v) => setState(() => _set(k, v)),
                  onPickTime: _pickTime,
                ),
                const SizedBox(height: 16),
              ],
              if (register.id == 'breakdown' || register.id == 'complaint') ...<Widget>[
                if (widget.readOnly)
                  ReadOnlyLocation(
                    latitude: double.tryParse(_values['latitude'] ?? ''),
                    longitude: double.tryParse(_values['longitude'] ?? ''),
                    source: _values['locationSource'],
                  )
                else
                  LocationCaptureField(
                    service: ref.watch(locationServiceProvider),
                    initialLatitude: double.tryParse(_values['latitude'] ?? ''),
                    initialLongitude:
                        double.tryParse(_values['longitude'] ?? ''),
                    onCaptured: (lat, lng, source) => setState(() {
                      _set('latitude', lat.toString());
                      _set('longitude', lng.toString());
                      _set('locationSource', source);
                    }),
                  ),
                const SizedBox(height: 16),
              ],
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
                  fleet: fleet,
                  technicianStaff: technicianStaff,
                  supervisorStaff: supervisorStaff,
                  mechanicStaff: mechanicStaff,
                  isMobile: isMobile,
                  values: _values,
                  controllers: _controllers,
                  onSet: (k, v) => setState(() => _set(k, v)),
                  onPickDate: _pickDate,
                  onPickTime: _pickTime,
                  photoAttached: _hasPhoto,
                  onAttachPhoto: _onAttachPhoto,
                  onRemovePhoto: _onRemovePhoto,
                  existingPhotos: _remainingExistingPhotos,
                  newPhotoCount: _newPhotos.length,
                  onRemoveExistingPhoto: _onRemoveExistingPhoto,
                  onRemoveNewPhoto: _onRemoveNewPhoto,
                  readOnly: widget.readOnly,
                ),
              ),
              if (!widget.readOnly && register.id == 'work') ...<Widget>[
                const SizedBox(height: 16),
                _UnitSection(
                  entryId: existing?.id,
                  drafts: _unitDrafts,
                  onAdd: () => setState(() => _unitDrafts.add(_UnitDraft())),
                  onRemove: (draft) => setState(() {
                    _unitDrafts.remove(draft);
                    draft.dispose();
                  }),
                  onChanged: () => setState(() {}),
                ),
              ],
              if (register.id == 'work') ...<Widget>[
                const SizedBox(height: 16),
                _SparePartsSection(
                  values: _values,
                  onSet: (k, v) => setState(() => _set(k, v)),
                  readOnly: widget.readOnly,
                ),
              ],
              const SizedBox(height: 16),
              if (!widget.readOnly)
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
                )
              else
                OutlineActionButton(
                  label: 'Close',
                  onPressed: _close,
                  fontSize: 16,
                ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// One newly picked, not-yet-uploaded photo.
class _PendingPhoto {
  const _PendingPhoto({required this.filename, required this.bytes});
  final String filename;
  final List<int> bytes;
}

/// One unfit-yet component pick in the Unit section. Its own controllers, so
/// removing one row never disturbs another's text.
class _UnitDraft {
  _UnitDraft()
      : unitNoController = TextEditingController(),
        odometerController = TextEditingController(),
        remarksController = TextEditingController();

  int? unitTypeId;
  final TextEditingController unitNoController;
  final TextEditingController odometerController;
  final TextEditingController remarksController;

  void dispose() {
    unitNoController.dispose();
    odometerController.dispose();
    remarksController.dispose();
  }
}

/// Optional unit-fitting block on the Daily Work Done form.
///
/// A day's work can touch more than one component (a battery and a motor,
/// say), so this is a list of picks — each filled-in row makes its own,
/// independent `fitUnit` call when the entry is saved. Leaving every row
/// unpicked (the default) submits the Work Done entry exactly as before,
/// with nothing added.
class _UnitSection extends ConsumerWidget {
  const _UnitSection({
    required this.entryId,
    required this.drafts,
    required this.onAdd,
    required this.onRemove,
    required this.onChanged,
  });

  /// Set only when editing an existing entry — used to show what is already
  /// fit to it, read-only; removing one still goes through Bus History.
  final String? entryId;
  final List<_UnitDraft> drafts;
  final VoidCallback onAdd;
  final ValueChanged<_UnitDraft> onRemove;

  /// Called after any in-place change to a draft — the drafts don't carry
  /// their own `setState`, so the form decides when a rebuild is worth it.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final types = ref.watch(unitTypesProvider).valueOrNull ?? const <UnitType>[];
    final entryId = this.entryId;
    final existing = entryId == null
        ? const <FittedUnit>[]
        : ref.watch(unitsByEntriesProvider(entryId)).valueOrNull ??
            const <FittedUnit>[];

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
            'it comes off. A day can touch more than one; add as many picks '
            'as this entry needs, or leave them blank.',
            style: AppText.sans(size: 12.5, color: T.secondary, height: 1.4),
          ),
          if (existing.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              'ALREADY FIT TO THIS ENTRY',
              style: AppText.sans(size: 10, color: T.muted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final unit in existing)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: const BoxDecoration(
                      color: T.subtleFill,
                      borderRadius: T.cardSmShape,
                    ),
                    child: Text(
                      (unit.unitNo ?? '').isEmpty
                          ? unit.unitName
                          : '${unit.unitName} · ${unit.unitNo}',
                      style: AppText.sans(size: 12, weight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ],
          for (var i = 0; i < drafts.length; i++) ...<Widget>[
            const SizedBox(height: 14),
            if (i > 0) const Divider(height: 1, color: T.border),
            if (i > 0) const SizedBox(height: 14),
            Row(
              children: <Widget>[
                const Expanded(child: FieldLabel(label: 'Unit')),
                if (drafts.length > 1)
                  InkWell(
                    onTap: () => onRemove(drafts[i]),
                    child: Text(
                      'Remove',
                      style: AppText.sans(
                        size: 12,
                        weight: FontWeight.w600,
                        color: T.red,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            AppSelect(
              value: types
                  .where((t) => t.id == drafts[i].unitTypeId)
                  .map((t) => t.name)
                  .firstOrNull,
              options: types.map((t) => t.name).toList(),
              placeholder: 'Not fitting a unit here',
              onChanged: (name) {
                drafts[i].unitTypeId = types
                    .where((t) => t.name == name)
                    .map((t) => t.id)
                    .firstOrNull;
                onChanged();
              },
            ),
            if (drafts[i].unitTypeId != null) ...<Widget>[
              const SizedBox(height: 14),
              const FieldLabel(label: 'Unit No'),
              const SizedBox(height: 6),
              AppTextField(
                controller: drafts[i].unitNoController,
                placeholder: 'The maker’s serial, if it has one',
              ),
              const SizedBox(height: 14),
              const FieldLabel(label: 'Odometer at fitting'),
              const SizedBox(height: 6),
              AppTextField(
                controller: drafts[i].odometerController,
                placeholder: 'Leave blank to use the bus’s last reading',
                numeric: true,
              ),
              const SizedBox(height: 14),
              const FieldLabel(label: 'Remarks'),
              const SizedBox(height: 6),
              AppTextField(
                controller: drafts[i].remarksController,
                placeholder: 'Optional',
              ),
            ],
          ],
          const SizedBox(height: 14),
          OutlineActionButton(label: '+ Add another unit', onPressed: onAdd),
        ],
      ),
    );
  }
}

/// Work Done's link to a ticket (breakdown/coolant/complaint/PM), its
/// attending-mechanics multi-select, and — only once a ticket is picked —
/// the "mark ticket complete" flag and its time.
///
/// A ticket is not a [FieldDef]: picking one needs a live, register-filtered
/// search against `/tickets/search`, which the static master-list-driven
/// [FieldType.select] machinery in `_Field` has no way to express. This
/// mirrors [_UnitSection]'s precedent of a bespoke, non-FieldDef block
/// bolted onto the Work Done form specifically.
class _TicketLinkSection extends ConsumerStatefulWidget {
  const _TicketLinkSection({
    required this.values,
    required this.onSet,
    required this.onPickTime,
  });

  final Map<String, String> values;
  final void Function(String key, String value) onSet;
  final Future<void> Function(String key) onPickTime;

  @override
  ConsumerState<_TicketLinkSection> createState() => _TicketLinkSectionState();
}

class _TicketLinkSectionState extends ConsumerState<_TicketLinkSection> {
  String _query = '';
  String _pickedTitle = '';

  /// The picked ticket's own context, for the read-only block below the
  /// search field — set once, on pick, so it survives even if a later
  /// search clears [results] (the picker itself disappears once linked).
  TicketSearchResult? _picked;
  final TextEditingController _queryController = TextEditingController();

  /// Keys the *current* pick's auto-fill actually wrote. Re-picking a
  /// different ticket that has no value for one of these clears it first,
  /// instead of leaving the previous ticket's value misattributed to the
  /// new one -- a pick is fully authoritative, blank included.
  final Set<String> _autoFilledKeys = <String>{};

  // Floats the results list instead of rendering it inline -- an empty
  // query matches every open ticket at the site (search_tickets's own `q`
  // handling), so an unfocused, unfiltered field would otherwise show the
  // site's entire open-ticket list on every render of this form.
  final LayerLink _link = LayerLink();
  final FocusNode _focus = FocusNode();
  final OverlayPortalController _portal = OverlayPortalController();
  final GlobalKey _fieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _queryController.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _open();
    } else {
      // Let an option's onTapDown land before we tear the overlay down.
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted || _focus.hasFocus) return;
        _close();
      });
    }
  }

  void _open() {
    if (!_portal.isShowing) _portal.show();
    setState(() {});
  }

  void _close() {
    if (_portal.isShowing) _portal.hide();
  }

  Size _fieldSize() {
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size ?? const Size(240, T.minTouchTarget);
  }

  /// The entry's own echo of every selected attendee's name (`user_id|name`,
  /// records joined by `;;` -- see field_map.dart's `attendees` handling),
  /// keyed by id. staffDirectoryProvider is active-rows-only, so this is the
  /// only source left for someone who's since been deactivated.
  Map<String, String> _echoedAttendeeNames() {
    final raw = widget.values['attendeeLabels'];
    if (raw == null || raw.isEmpty) return const <String, String>{};
    final out = <String, String>{};
    for (final record in raw.split(';;')) {
      final fields = record.split('|');
      if (fields.length != 2) continue;
      out[fields[0]] = fields[1];
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final staff = ref.watch(staffDirectoryProvider).valueOrNull ?? const <StaffMember>[];
    final nameById = <String, String>{
      ..._echoedAttendeeNames(),
      for (final s in staff) s.id: s.name,
    };
    // No register-filter dropdown any more -- free text matches both the
    // source entry's own text and its display id (see search_tickets's `q`
    // handling), so typing "BD-2026-" or "DC-2026-" narrows exactly as well
    // as picking a register used to, without the extra step.
    final searchKey = (site: site, register: null, q: _query, status: 'open');
    final results = ref.watch(ticketSearchProvider(searchKey)).valueOrNull ??
        const <TicketSearchResult>[];

    final selectedIds = widget.values['attendeeUserIds']
            ?.split(',')
            .where((s) => s.isNotEmpty)
            .toSet() ??
        <String>{};
    final hasTicket = (widget.values['ticketId'] ?? '').isNotEmpty;

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
          Text('Link to', style: AppText.sans(size: 15, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Optional — attach this session to the breakdown, coolant, '
            'complaint, or PM ticket it was worked against.',
            style: AppText.sans(size: 12.5, color: T.secondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (hasTicket) ...<Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                TagBadge(
                  label: _pickedTitle.isEmpty ? 'Linked ticket' : _pickedTitle,
                  background: T.subtleFill,
                  foreground: T.secondary,
                ),
                InkWell(
                  onTap: () => setState(() {
                    widget.onSet('ticketId', '');
                    widget.onSet('completesTicket', '');
                    widget.onSet('completionTime', '');
                    _pickedTitle = '';
                    _picked = null;
                  }),
                  child: Text(
                    'Remove',
                    style: AppText.sans(size: 12, weight: FontWeight.w600, color: T.red),
                  ),
                ),
              ],
            ),
            if (_picked != null) ...<Widget>[
              const SizedBox(height: 12),
              _LinkedTicketContext(ticket: _picked!),
            ],
          ] else ...<Widget>[
            CompositedTransformTarget(
              link: _link,
              child: FocusRing(
                child: Container(
                  key: _fieldKey,
                  constraints: const BoxConstraints(minHeight: T.minTouchTarget),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: T.card,
                    borderRadius: T.controlShape,
                    border: Border.all(color: T.inputBorder, width: 1.5),
                  ),
                  child: OverlayPortal(
                    controller: _portal,
                    overlayChildBuilder: (context) {
                      final size = _fieldSize();
                      return CompositedTransformFollower(
                        link: _link,
                        showWhenUnlinked: false,
                        offset: Offset(0, size.height + 4),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 6,
                            color: T.card,
                            borderRadius: T.controlShape,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: 240,
                                minWidth: size.width.clamp(200, 480),
                                maxWidth: size.width.clamp(200, 480),
                              ),
                              child: results.isEmpty
                                  ? Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                        'No matches',
                                        style: AppText.sans(
                                          size: 14,
                                          color: T.muted,
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      padding: EdgeInsets.zero,
                                      shrinkWrap: true,
                                      itemCount: results.length,
                                      itemBuilder: (_, i) {
                                        final r = results[i];
                                        return InkWell(
                                          onTapDown: (_) {
                                            widget.onSet('ticketId', r.ticketId);
                                            // Carry the linked ticket's own
                                            // data forward so the mechanic
                                            // doesn't re-type what's
                                            // already on the record it's
                                            // linked to. A pick is fully
                                            // authoritative for these
                                            // three fields: a value
                                            // overwrites, and a blank
                                            // clears -- but only a field
                                            // *this* section auto-filled;
                                            // a mechanic's own typing is
                                            // never touched. This widget
                                            // only renders inside the
                                            // Work Done form, so the
                                            // target keys are fixed.
                                            for (final MapEntry<String,
                                                    String?> field
                                                in <String, String?>{
                                              'bus': r.busNo,
                                              'defects': r.defectText,
                                              'defectType': r.defectType,
                                            }.entries) {
                                              final value = field.value ?? '';
                                              if (value.isNotEmpty) {
                                                widget.onSet(field.key, value);
                                                _autoFilledKeys.add(field.key);
                                              } else if (_autoFilledKeys
                                                  .contains(field.key)) {
                                                widget.onSet(field.key, '');
                                                _autoFilledKeys
                                                    .remove(field.key);
                                              }
                                            }
                                            setState(() {
                                              _pickedTitle = r.title;
                                              _picked = r;
                                              _query = '';
                                              _queryController.clear();
                                            });
                                            _focus.unfocus();
                                            _close();
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 14,
                                              vertical: 12,
                                            ),
                                            child: Text(
                                              r.title,
                                              style: AppText.sans(size: 13.5),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: TextField(
                      controller: _queryController,
                      focusNode: _focus,
                      style: AppText.input,
                      onTap: _open,
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Search by title or ID (e.g. BD-2026-000123)…',
                        hintStyle: AppText.sans(size: 16, color: T.muted),
                      ),
                      onChanged: (v) {
                        _open();
                        setState(() => _query = v);
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const FieldLabel(label: 'Attending mechanic(s)'),
          const SizedBox(height: 6),
          AppMultiSelect(
            values: selectedIds.toList(),
            options: staff.map((s) => s.id).toList(),
            optionLabel: (id) => nameById[id] ?? id,
            placeholder: 'Search mechanics…',
            emptyHint: 'No staff loaded',
            onChanged: (ids) => widget.onSet('attendeeUserIds', ids.join(',')),
          ),
          if (hasTicket) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Checkbox(
                  value: widget.values['completesTicket'] == 'true',
                  onChanged: (checked) => setState(
                    () => widget.onSet('completesTicket', (checked ?? false).toString()),
                  ),
                ),
                Text('Mark ticket resolved', style: AppText.sans(size: 13.5)),
              ],
            ),
            if (widget.values['completesTicket'] == 'true') ...<Widget>[
              const SizedBox(height: 8),
              const FieldLabel(label: 'Resolved at', required: true),
              const SizedBox(height: 6),
              PickerField(
                display: widget.values['completionTime'] ?? '',
                placeholder: '--:--',
                onTap: () => widget.onPickTime('completionTime'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The linked ticket's own fields, read-only — bus, driver, route, and the
/// original complaint/defect text. Shown once a ticket is picked so the
/// mechanic never re-types what's already on the linked record.
class _LinkedTicketContext extends StatelessWidget {
  const _LinkedTicketContext({required this.ticket});

  final TicketSearchResult ticket;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String?)>[
      ('Bus', ticket.busNo),
      ('Driver', ticket.driverName),
      ('Route', ticket.route),
      ('Reported', ticket.defectText),
    ].where((r) => (r.$2 ?? '').isNotEmpty).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: T.subtleFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: RichText(
                text: TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: '$label: ',
                      style: AppText.sans(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: T.secondary,
                      ),
                    ),
                    TextSpan(
                      text: value,
                      style: AppText.sans(size: 12.5, color: T.ink),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Work Done's spare parts multi-select — typeahead search against the
/// site's catalogue, a chip list of what's picked, and an inline "add as
/// new part" affordance when the typed text matches nothing. Structurally
/// mirrors [_TicketLinkSection]'s attendee picker.
class _SparePartsSection extends ConsumerStatefulWidget {
  const _SparePartsSection({
    required this.values,
    required this.onSet,
    this.readOnly = false,
  });

  final Map<String, String> values;
  final void Function(String key, String value) onSet;
  final bool readOnly;

  @override
  ConsumerState<_SparePartsSection> createState() => _SparePartsSectionState();
}

class _SparePartsSectionState extends ConsumerState<_SparePartsSection> {
  String _query = '';
  final TextEditingController _queryController = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _addNew(String partNo) async {
    final site = ref.read(sessionProvider.select((s) => s.site));
    if (site.isEmpty || _adding) return;
    setState(() => _adding = true);
    try {
      final created = await ref.read(masterDataRepositoryProvider).createSparePart(
            siteCode: site,
            partNo: partNo,
            name: partNo,
          );
      ref.invalidate(sparePartDirectoryProvider);
      final selected = _selectedIds();
      widget.onSet('sparePartIds', <String>{...selected, created.id}.join(','));
      setState(() {
        _query = '';
        _queryController.clear();
      });
    } on ApiException catch (e) {
      ref.read(toastProvider.notifier).show(e.message);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Set<String> _selectedIds() => widget.values['sparePartIds']
          ?.split(',')
          .where((s) => s.isNotEmpty)
          .toSet() ??
      <String>{};

  /// The entry's own echo of every selected part's label (`part_id|part_no|
  /// name`, records joined by `;;` -- see field_map.dart's `spare_parts`
  /// handling), keyed by id. The directory is active-rows-only, so this is
  /// the only source left for a part that's since been deactivated.
  Map<String, SparePart> _echoedLabels() {
    final raw = widget.values['sparePartLabels'];
    if (raw == null || raw.isEmpty) return const <String, SparePart>{};
    final out = <String, SparePart>{};
    for (final record in raw.split(';;')) {
      final fields = record.split('|');
      if (fields.length != 3) continue;
      out[fields[0]] = SparePart(id: fields[0], partNo: fields[1], name: fields[2]);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final parts = ref.watch(sparePartDirectoryProvider).valueOrNull ?? const <SparePart>[];
    final selectedIds = _selectedIds();
    final echoed = _echoedLabels();
    final byId = <String, SparePart>{...echoed, for (final p in parts) p.id: p};
    final selectedParts = [
      for (final id in selectedIds)
        if (byId[id] != null) byId[id]!,
    ];
    final needle = _query.trim().toLowerCase();
    final matches = needle.isEmpty
        ? const <SparePart>[]
        : parts
            .where((p) =>
                !selectedIds.contains(p.id) &&
                (p.partNo.toLowerCase().contains(needle) ||
                    p.name.toLowerCase().contains(needle)))
            .toList();
    final exactMatch = parts.any((p) => p.partNo.toLowerCase() == needle);

    if (widget.readOnly) {
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
            const FieldLabel(label: 'Spare Parts Used'),
            const SizedBox(height: 6),
            if (selectedParts.isEmpty)
              Text('None', style: AppText.sans(size: 13.5, color: T.muted))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final p in selectedParts)
                    TagBadge(
                      label: '${p.partNo} · ${p.name}',
                      background: T.subtleFill,
                      foreground: T.secondary,
                    ),
                ],
              ),
          ],
        ),
      );
    }

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
          const FieldLabel(label: 'Spare Parts Used'),
          const SizedBox(height: 6),
          if (selectedParts.isNotEmpty) ...<Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final p in selectedParts)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TagBadge(
                        label: '${p.partNo} · ${p.name}',
                        background: T.subtleFill,
                        foreground: T.secondary,
                      ),
                      InkWell(
                        onTap: () {
                          final next = Set<String>.of(selectedIds)..remove(p.id);
                          widget.onSet('sparePartIds', next.join(','));
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            '✕',
                            style: AppText.sans(size: 12, color: T.red),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          AppTextField(
            controller: _queryController,
            placeholder: 'Search part number or name…',
            onChanged: (v) => setState(() => _query = v),
          ),
          if (matches.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            for (final p in matches)
              InkWell(
                onTap: () {
                  final next = Set<String>.of(selectedIds)..add(p.id);
                  widget.onSet('sparePartIds', next.join(','));
                  setState(() {
                    _query = '';
                    _queryController.clear();
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('${p.partNo} · ${p.name}', style: AppText.sans(size: 13.5)),
                ),
              ),
          ] else if (needle.isNotEmpty && !exactMatch) ...<Widget>[
            const SizedBox(height: 8),
            InkWell(
              onTap: _adding ? null : () => _addNew(_queryController.text.trim()),
              child: Text(
                _adding ? 'Adding…' : 'Add "$_query" as new part',
                style: AppText.sans(size: 13.5, weight: FontWeight.w600, color: T.blue),
              ),
            ),
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
    required this.fleet,
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
    required this.onAttachPhoto,
    required this.onRemovePhoto,
    required this.existingPhotos,
    required this.newPhotoCount,
    required this.onRemoveExistingPhoto,
    required this.onRemoveNewPhoto,
    required this.readOnly,
  });

  final RegisterDef register;
  final MasterData master;
  final List<Vehicle> fleet;
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
  final void Function(String filename, List<int> bytes) onAttachPhoto;
  final VoidCallback onRemovePhoto;

  /// Only used by the three multi-photo registers (Breakdown, Driver
  /// Complaint, Work Done) — every other register keeps using
  /// [PhotoAttachButton] via [photoAttached]/[onAttachPhoto]/[onRemovePhoto]
  /// above, unchanged.
  final List<EntryPhoto> existingPhotos;
  final int newPhotoCount;
  final void Function(String photoId) onRemoveExistingPhoto;
  final void Function(int index) onRemoveNewPhoto;
  final bool readOnly;

  static const _galleryRegisters = <String>{'breakdown', 'complaint', 'work'};

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
                  fleet: fleet,
                  technicianStaff: technicianStaff,
                  supervisorStaff: supervisorStaff,
                  mechanicStaff: mechanicStaff,
                  value: values[f.key] ?? '',
                  controller: controllers[f.key],
                  onSet: onSet,
                  onPickDate: onPickDate,
                  onPickTime: onPickTime,
                  readOnly: readOnly,
                ),
              ),
            SizedBox(
              width: total,
              child: _buildPhotoPicker(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPhotoPicker() {
    final picker = _galleryRegisters.contains(register.id)
        ? PhotoGalleryPicker(
            existingPhotos: existingPhotos,
            pendingCount: newPhotoCount,
            onAdd: onAttachPhoto,
            onRemoveExisting: onRemoveExistingPhoto,
            onRemoveNew: onRemoveNewPhoto,
          )
        : PhotoAttachButton(
            attached: photoAttached,
            onAttach: onAttachPhoto,
            onRemove: onRemovePhoto,
          );
    if (!readOnly) return picker;
    return AbsorbPointer(child: Opacity(opacity: 0.7, child: picker));
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.registerId,
    required this.def,
    required this.master,
    required this.fleet,
    required this.technicianStaff,
    required this.supervisorStaff,
    required this.mechanicStaff,
    required this.value,
    required this.controller,
    required this.onSet,
    required this.onPickDate,
    required this.onPickTime,
    required this.readOnly,
  });

  final String registerId;
  final FieldDef def;
  final MasterData master;
  final List<Vehicle> fleet;
  final List<String> technicianStaff;
  final List<String> supervisorStaff;
  final List<String> mechanicStaff;
  final String value;
  final TextEditingController? controller;
  final void Function(String key, String value) onSet;
  final Future<void> Function(String key) onPickDate;
  final Future<void> Function(String key) onPickTime;
  final bool readOnly;

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
      case MasterList.drivers:
        return master.drivers;
      case null:
        return const <String>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    final control = Column(
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
    return readOnly
        ? AbsorbPointer(child: Opacity(opacity: 0.7, child: control))
        : control;
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
        final busType = fleet
            .where((v) => v.registrationNo == value)
            .map((v) => v.busTypeLabel)
            .firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppSelect(
              value: value,
              options: master.vehicles,
              mono: true,
              placeholder: 'Select bus…',
              emptyHint:
                  'No buses at this site — open Vehicle Master or Sync fleet',
              onChanged: (v) => onSet(def.key, v ?? ''),
            ),
            if (value.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Bus Type: ${busType ?? '—'}',
                style: AppText.sans(
                  size: 13.5,
                  weight: FontWeight.w600,
                  color: T.secondary,
                ),
              ),
            ],
          ],
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

/// Opens one entry's edit form as a bottom sheet, overlaying whatever screen
/// asked for it — a control chart cell, say — instead of routing away to
/// Registers. Closing it (Cancel, Save, or the back link) just pops the
/// sheet; the caller's screen is exactly as it was.
Future<void> showRegisterEntrySheet(
  BuildContext context, {
  required String entryId,
}) {
  return showEditorSheet<void>(
    context: context,
    builder: (sheetContext) => SingleChildScrollView(
      child: RegisterFormScreen(
        entryId: entryId,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}
