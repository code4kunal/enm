import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/site.dart';
import '../../state/session.dart';
import '../../state/sites.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sheet.dart';
import '../../widgets/sub_tabs.dart';

/// Checklist variants used for Bus Type / inspection sheets.
const _busTypeOptions = <String>['9M', '12M AC', '12M Non-AC'];

String? _blankToNull(String raw) {
  final t = raw.trim();
  return t.isEmpty ? null : t;
}

int? _ageYearsFrom(String? iso) {
  final d = Dates.parse(iso);
  if (d == null) return null;
  final now = DateTime.now();
  var age = now.year - d.year;
  if (DateTime(now.year, d.month, d.day).isAfter(now)) age -= 1;
  return age < 0 ? 0 : age;
}

/// The site's vehicles. Retired ones stay listed so a manager can reactivate.
class FleetPane extends ConsumerStatefulWidget {
  const FleetPane({super.key});

  @override
  ConsumerState<FleetPane> createState() => _FleetPaneState();
}

class _FleetPaneState extends ConsumerState<FleetPane> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _openEditor({Vehicle? existing}) async {
    await showEditorSheet<void>(
      context: context,
      builder: (_) => _VehicleEditorSheet(existing: existing),
    );
  }

  Future<void> _toggle(Vehicle v) async {
    try {
      await ref.read(vehiclesProvider.notifier).setActive(v.id, !v.isActive);
      if (!mounted) return;
      ref.read(toastProvider.notifier).show(
            v.isActive
                ? '${v.registrationNo} retired from service'
                : '${v.registrationNo} returned to service',
          );
    } on ApiException catch (e) {
      if (mounted) ref.read(toastProvider.notifier).show(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(vehiclesProvider);
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final all = async.valueOrNull ?? const <Vehicle>[];
    final needle = _query.trim().toLowerCase();
    final visible = needle.isEmpty
        ? all
        : all
            .where((v) => v.displayLabel.toLowerCase().contains(needle))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ScreenHeader(
          title: 'Fleet · $site',
          subtitle:
              '${all.where((v) => v.isActive).length} active of ${all.length}. '
              'Only active vehicles appear in the register dropdowns. '
              'Edit a bus to set registration, fitness and insurance dates.',
          action: FilledActionButton(
            label: '+ Add vehicle',
            onPressed: () => _openEditor(),
            fontSize: 14,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
        ),
        const SizedBox(height: 16),
        AppTextField(
          controller: _searchController,
          placeholder: 'Search registration, make or model…',
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 14),
        if (async.isLoading && all.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: T.green)),
          )
        else if (visible.isEmpty)
          EmptyState(
            message: all.isEmpty
                ? 'No vehicles on $site yet. Add one, or import the fleet '
                    'sheet from the Import tab.'
                : 'No vehicle matches "$_query".',
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final v in visible) ...<Widget>[
                _VehicleRow(
                  vehicle: v,
                  onEdit: () => _openEditor(existing: v),
                  onToggle: () => _toggle(v),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }
}

class _VehicleRow extends StatelessWidget {
  const _VehicleRow({
    required this.vehicle,
    required this.onEdit,
    required this.onToggle,
  });

  final Vehicle vehicle;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final age = vehicle.vehicleAgeYears;
    return Opacity(
      opacity: vehicle.isActive ? 1 : 0.62,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.cardSmShape,
          border: Border.all(color: T.border),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    vehicle.registrationNo,
                    style: AppText.mono(size: 15, weight: FontWeight.w600),
                  ),
                  if (vehicle.make.isNotEmpty || vehicle.model.isNotEmpty)
                    Text(
                      '${vehicle.make} ${vehicle.model}'.trim(),
                      style: AppText.sans(size: 13, color: T.secondary),
                    ),
                  if (vehicle.checklistVariant != null &&
                      vehicle.checklistVariant!.isNotEmpty)
                    TagBadge(
                      label: vehicle.busTypeLabel,
                      background: T.greenTint,
                      foreground: T.greenInk,
                    ),
                  if (vehicle.batteryCapacityKwh != null)
                    TagBadge(
                      label:
                          '${vehicle.batteryCapacityKwh!.toStringAsFixed(0)} kWh',
                      background: T.greenTint,
                      foreground: T.greenInk,
                      mono: true,
                    ),
                  if (age != null)
                    TagBadge(
                      label: '$age yr',
                      background: T.inactiveFill,
                      foreground: T.secondary,
                      mono: true,
                    ),
                  if ((vehicle.fitnessRenewalDate ?? '').isNotEmpty)
                    TagBadge(
                      label: 'Fit ${vehicle.fitnessRenewalDate}',
                      background: T.inactiveFill,
                      foreground: T.secondary,
                      mono: true,
                    ),
                  if ((vehicle.insuranceRenewalDate ?? '').isNotEmpty)
                    TagBadge(
                      label: 'Ins ${vehicle.insuranceRenewalDate}',
                      background: T.inactiveFill,
                      foreground: T.secondary,
                      mono: true,
                    ),
                  if (!vehicle.isActive)
                    const TagBadge(
                      label: 'RETIRED',
                      background: T.inactiveFill,
                      foreground: T.muted,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            OutlineActionButton(
              label: 'Edit',
              onPressed: onEdit,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            ),
            const SizedBox(width: 8),
            OutlineActionButton(
              label: vehicle.isActive ? 'Retire' : 'Restore',
              onPressed: onToggle,
              foreground: vehicle.isActive ? T.redInk : T.greenInk,
              borderColor: vehicle.isActive ? T.redBorderTint : T.green,
              fontSize: 12.5,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            ),
          ],
        ),
      ),
    );
  }
}

/// Add or edit an ENM fleet vehicle — identity plus compliance dates the
/// depot can keep when SiteOps has nothing.
class _VehicleEditorSheet extends ConsumerStatefulWidget {
  const _VehicleEditorSheet({this.existing});

  final Vehicle? existing;

  @override
  ConsumerState<_VehicleEditorSheet> createState() =>
      _VehicleEditorSheetState();
}

class _VehicleEditorSheetState extends ConsumerState<_VehicleEditorSheet> {
  late final TextEditingController _reg = TextEditingController(
    text: widget.existing?.registrationNo ?? '',
  );
  late final TextEditingController _make = TextEditingController(
    text: widget.existing?.make ?? '',
  );
  late final TextEditingController _model = TextEditingController(
    text: widget.existing?.model ?? '',
  );
  late final TextEditingController _kwh = TextEditingController(
    text: widget.existing?.batteryCapacityKwh?.toStringAsFixed(0) ?? '',
  );

  late String _busType = widget.existing?.checklistVariant ?? '';
  late String _registrationDate = widget.existing?.registrationDate ?? '';
  late String _fitnessDate = widget.existing?.fitnessRenewalDate ?? '';
  late String _insuranceDate = widget.existing?.insuranceRenewalDate ?? '';

  String? _error;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _reg.dispose();
    _make.dispose();
    _model.dispose();
    _kwh.dispose();
    super.dispose();
  }

  Future<void> _pickDate(void Function(String) apply, String current) async {
    final initial = Dates.parse(current) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1990),
      lastDate: DateTime(DateTime.now().year + 15),
    );
    if (picked != null) setState(() => apply(Dates.iso(picked)));
  }

  Future<void> _save() async {
    if (_saving) return;
    final reg = _reg.text.trim();
    if (reg.isEmpty) {
      setState(() => _error = 'Registration number is required');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final kwh = double.tryParse(_kwh.text.trim());
      final busType = _blankToNull(_busType);
      final regDate = _blankToNull(_registrationDate);
      final fitDate = _blankToNull(_fitnessDate);
      final insDate = _blankToNull(_insuranceDate);

      if (_isEdit) {
        final existing = widget.existing!;
        await ref.read(vehiclesProvider.notifier).edit(
              Vehicle(
                id: existing.id,
                registrationNo: Vehicle.normalise(reg),
                siteCode: existing.siteCode,
                isActive: existing.isActive,
                make: _make.text.trim(),
                model: _model.text.trim(),
                checklistVariant: busType,
                batteryCapacityKwh: kwh,
                odometerKm: existing.odometerKm,
                odometerUpdatedAt: existing.odometerUpdatedAt,
                lastServiceKm: existing.lastServiceKm,
                lastServiceOn: existing.lastServiceOn,
                lastServiceCode: existing.lastServiceCode,
                registrationDate: regDate,
                fitnessRenewalDate: fitDate,
                insuranceRenewalDate: insDate,
                vehicleAgeYears: _ageYearsFrom(regDate),
              ),
            );
        if (!mounted) return;
        ref.read(toastProvider.notifier).show('${Vehicle.normalise(reg)} updated');
      } else {
        await ref.read(vehiclesProvider.notifier).add(
              registrationNo: reg,
              make: _make.text,
              model: _model.text,
              batteryCapacityKwh: kwh,
              checklistVariant: busType,
              registrationDate: regDate,
              fitnessRenewalDate: fitDate,
              insuranceRenewalDate: insDate,
            );
        if (!mounted) return;
        ref.read(toastProvider.notifier).show('Vehicle added to the fleet');
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final age = _ageYearsFrom(_registrationDate) ??
        widget.existing?.vehicleAgeYears;

    return EditorSheet(
      title: _isEdit
          ? widget.existing!.registrationNo
          : 'Add vehicle',
      subtitle: _isEdit
          ? 'Update fleet identity and compliance dates (SiteOps when synced, '
              'else edit here).'
          : 'New bus on this site — set compliance dates when SiteOps has none.',
      action: FilledActionButton(
        label: _saving ? 'Saving…' : (_isEdit ? 'Save' : 'Add vehicle'),
        expand: true,
        onPressed: _saving ? null : _save,
      ),
      children: <Widget>[
        const FieldLabel(label: 'Registration No', required: true),
        const SizedBox(height: 6),
        AppTextField(
          controller: _reg,
          placeholder: 'MH40LY1894',
          mono: true,
          uppercase: true,
        ),
        const SizedBox(height: 14),
        const FieldLabel(label: 'Bus Type'),
        const SizedBox(height: 6),
        AppSelect(
          value: _busType,
          options: _busTypeOptions,
          placeholder: 'Select bus type…',
          emptyHint: '9M / 12M AC / 12M Non-AC',
          onChanged: (v) => setState(() => _busType = v ?? ''),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 14.0;
            final half = constraints.maxWidth < T.mobileBreakpoint
                ? constraints.maxWidth
                : (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: 14,
              children: <Widget>[
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Make'),
                      const SizedBox(height: 6),
                      AppTextField(
                        controller: _make,
                        placeholder: 'e.g. EKA',
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Model'),
                      const SizedBox(height: 6),
                      AppTextField(
                        controller: _model,
                        placeholder: 'e.g. E9',
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Battery capacity', hint: '— kWh'),
                      const SizedBox(height: 6),
                      UnitField(controller: _kwh, unit: 'kWh'),
                    ],
                  ),
                ),
                SizedBox(
                  width: half,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Vehicle age', hint: '— years'),
                      const SizedBox(height: 6),
                      Container(
                        constraints: const BoxConstraints(
                          minHeight: T.minTouchTarget,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: T.card,
                          borderRadius: T.controlShape,
                          border: Border.all(color: T.inputBorder, width: 1.5),
                        ),
                        child: Text(
                          age == null ? 'From registration date' : '$age years',
                          style: AppText.mono(
                            size: 16,
                            weight: FontWeight.w600,
                            color: age == null ? T.muted : T.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        Text('Compliance', style: AppText.sectionTitle),
        const SizedBox(height: 4),
        Text(
          'Used when SiteOps has no date. Sync from SiteOps overwrites these '
          'when it sends a value.',
          style: AppText.sans(size: 12.5, color: T.secondary),
        ),
        const SizedBox(height: 14),
        const FieldLabel(label: 'Registration date'),
        const SizedBox(height: 6),
        PickerField(
          display: _registrationDate,
          placeholder: 'yyyy-mm-dd',
          onTap: () => _pickDate((v) => _registrationDate = v, _registrationDate),
        ),
        const SizedBox(height: 14),
        const FieldLabel(label: 'Fitness renewal date'),
        const SizedBox(height: 6),
        PickerField(
          display: _fitnessDate,
          placeholder: 'yyyy-mm-dd',
          onTap: () => _pickDate((v) => _fitnessDate = v, _fitnessDate),
        ),
        const SizedBox(height: 14),
        const FieldLabel(label: 'Insurance renewal date'),
        const SizedBox(height: 6),
        PickerField(
          display: _insuranceDate,
          placeholder: 'yyyy-mm-dd',
          onTap: () => _pickDate((v) => _insuranceDate = v, _insuranceDate),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          InlineError(message: _error!),
        ],
      ],
    );
  }
}
