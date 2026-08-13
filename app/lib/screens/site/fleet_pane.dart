import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/site.dart';
import '../../state/session.dart';
import '../../state/sites.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sub_tabs.dart';

/// The site's vehicles. Retired ones stay listed so a manager can reactivate.
class FleetPane extends ConsumerStatefulWidget {
  const FleetPane({super.key});

  @override
  ConsumerState<FleetPane> createState() => _FleetPaneState();
}

class _FleetPaneState extends ConsumerState<FleetPane> {
  final _regController = TextEditingController();
  final _makeController = TextEditingController();
  final _modelController = TextEditingController();
  final _kwhController = TextEditingController();
  final _searchController = TextEditingController();

  bool _adding = false;
  bool _saving = false;
  String? _error;
  String _query = '';

  @override
  void dispose() {
    _regController.dispose();
    _makeController.dispose();
    _modelController.dispose();
    _kwhController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _openAdd() {
    _regController.clear();
    _makeController.clear();
    _modelController.clear();
    _kwhController.clear();
    setState(() {
      _adding = true;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(vehiclesProvider.notifier).add(
            registrationNo: _regController.text,
            make: _makeController.text,
            model: _modelController.text,
            batteryCapacityKwh: double.tryParse(_kwhController.text),
          );
      if (!mounted) return;
      setState(() => _adding = false);
      ref.read(toastProvider.notifier).show('Vehicle added to the fleet');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
              'Only active vehicles appear in the register dropdowns.',
          action: FilledActionButton(
            label: '+ Add vehicle',
            onPressed: _openAdd,
            fontSize: 14,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
        ),
        if (_adding) ...<Widget>[
          const SizedBox(height: 16),
          Panel(
            accent: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('New vehicle', style: AppText.sectionTitle),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final gap = constraints.maxWidth * 0.04;
                    final half = constraints.maxWidth < T.mobileBreakpoint
                        ? constraints.maxWidth
                        : (constraints.maxWidth - gap) / 2;
                    return Wrap(
                      spacing: gap,
                      runSpacing: 16,
                      children: <Widget>[
                        SizedBox(
                          width: half,
                          child: _field(
                            const FieldLabel(
                              label: 'Registration No',
                              required: true,
                            ),
                            AppTextField(
                              controller: _regController,
                              placeholder: 'MH40LY1894',
                              mono: true,
                              uppercase: true,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: half,
                          child: _field(
                            const FieldLabel(
                              label: 'Battery capacity',
                              hint: '— kWh',
                            ),
                            UnitField(
                              controller: _kwhController,
                              unit: 'kWh',
                            ),
                          ),
                        ),
                        SizedBox(
                          width: half,
                          child: _field(
                            const FieldLabel(label: 'Make'),
                            AppTextField(
                              controller: _makeController,
                              placeholder: 'e.g. EKA',
                            ),
                          ),
                        ),
                        SizedBox(
                          width: half,
                          child: _field(
                            const FieldLabel(label: 'Model'),
                            AppTextField(
                              controller: _modelController,
                              placeholder: 'e.g. E9',
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (_error != null) InlineError(message: _error!),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    OutlineActionButton(
                      label: 'Cancel',
                      onPressed: _saving
                          ? null
                          : () => setState(() => _adding = false),
                      fontSize: 15,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 13,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledActionButton(
                        label: _saving ? 'Saving…' : 'Add vehicle',
                        onPressed: _saving ? null : _save,
                        fontSize: 15.5,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
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
                _VehicleRow(vehicle: v, onToggle: () => _toggle(v)),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }

  Widget _field(Widget label, Widget control) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[label, control],
      );
}

class _VehicleRow extends StatelessWidget {
  const _VehicleRow({required this.vehicle, required this.onToggle});

  final Vehicle vehicle;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
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
                  if (vehicle.batteryCapacityKwh != null)
                    TagBadge(
                      label:
                          '${vehicle.batteryCapacityKwh!.toStringAsFixed(0)} kWh',
                      background: T.greenTint,
                      foreground: T.greenInk,
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
