import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/repositories.dart';
import '../models/site.dart';
import '../router.dart';
import '../state/entries.dart';
import '../state/providers.dart';
import '../state/session.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';
import '../widgets/sub_tabs.dart';

/// Coolant Topping's day-based entry: one date, one submitting supervisor,
/// every site vehicle answered once, submitted in a single action — replaces
/// filling in a separate form per bus for the common case (corrections still
/// go through Registers → Edit on the per-bus entry).
class CoolantDayScreen extends ConsumerStatefulWidget {
  const CoolantDayScreen({super.key});

  @override
  ConsumerState<CoolantDayScreen> createState() => _CoolantDayScreenState();
}

class _RowControllers {
  _RowControllers()
      : bcs = TextEditingController(),
        tcs = TextEditingController(),
        toppedBy = TextEditingController();

  final TextEditingController bcs;
  final TextEditingController tcs;
  final TextEditingController toppedBy;

  void dispose() {
    bcs.dispose();
    tcs.dispose();
    toppedBy.dispose();
  }
}

class _CoolantDayScreenState extends ConsumerState<CoolantDayScreen> {
  String _date = Dates.today();
  final TextEditingController _supervisor = TextEditingController();
  final Map<String, _RowControllers> _rows = <String, _RowControllers>{};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _supervisor.dispose();
    for (final c in _rows.values) {
      c.dispose();
    }
    super.dispose();
  }

  _RowControllers _controllersFor(String vehicleId) =>
      _rows.putIfAbsent(vehicleId, _RowControllers.new);

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

  Future<void> _save(List<Vehicle> active) async {
    final rows = <Map<String, dynamic>>[
      for (final v in active)
        if (_controllersFor(v.id).bcs.text.trim().isNotEmpty ||
            _controllersFor(v.id).tcs.text.trim().isNotEmpty)
          <String, dynamic>{
            'vehicle_id': v.id,
            if (_controllersFor(v.id).bcs.text.trim().isNotEmpty)
              'bcs_litres': _controllersFor(v.id).bcs.text.trim(),
            if (_controllersFor(v.id).tcs.text.trim().isNotEmpty)
              'tcs_litres': _controllersFor(v.id).tcs.text.trim(),
            if (_controllersFor(v.id).toppedBy.text.trim().isNotEmpty)
              'topped_by': _controllersFor(v.id).toppedBy.text.trim(),
          },
    ];
    if (rows.isEmpty) {
      setState(() => _error = 'Enter a reading for at least one bus.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await ref.read(entriesProvider.notifier).createCoolantDay(
            entryDate: _date,
            supervisor: _supervisor.text.trim(),
            rows: rows,
          );
      ref.read(toastProvider.notifier).show('${created.length} buses recorded');
      if (mounted) context.go(Routes.registers);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final fleetRaw = ref.watch(siteVehiclesProvider).valueOrNull ?? const <Vehicle>[];
    final active = fleetRaw.where((v) => site.isEmpty || (v.siteCode == site && v.isActive)).toList()
      ..sort((a, b) => a.registrationNo.compareTo(b.registrationNo));

    return FadeUp(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.maxFormWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              BackLink(onTap: () => context.go(Routes.registers)),
              const SizedBox(height: 10),
              Text(
                'Coolant Topping — Day Entry',
                style: AppText.sans(size: 22, weight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'One date, every bus, in one submit.',
                style: AppText.sans(size: 13.5, color: T.secondary),
              ),
              const SizedBox(height: 16),
              Panel(
                child: Row(
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
                          const FieldLabel(label: 'Supervisor (Floor)'),
                          const SizedBox(height: 6),
                          AppTextField(controller: _supervisor, placeholder: 'Name'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (active.isEmpty)
                const EmptyState(message: 'No active buses on this site.')
              else
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final v in active) ...<Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            SizedBox(
                              width: 100,
                              child: Text(
                                v.registrationNo,
                                style: AppText.sans(size: 13.5, weight: FontWeight.w700),
                              ),
                            ),
                            Expanded(
                              child: AppTextField(
                                controller: _controllersFor(v.id).bcs,
                                placeholder: 'BCS L',
                                numeric: true,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: AppTextField(
                                controller: _controllersFor(v.id).tcs,
                                placeholder: 'TCS L',
                                numeric: true,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: AppTextField(
                                controller: _controllersFor(v.id).toppedBy,
                                placeholder: 'Topped by',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              if (_error != null) InlineError(message: _error!),
              if (_error != null) const SizedBox(height: 12),
              FilledActionButton(
                label: _saving ? 'Saving…' : 'Save day entry',
                expand: true,
                onPressed: _saving || active.isEmpty ? null : () => _save(active),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
