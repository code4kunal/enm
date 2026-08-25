import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/repositories.dart';
import '../models/entry.dart';
import '../models/job_card.dart';
import '../router.dart';
import '../state/entries.dart';
import '../state/providers.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/code_square.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';
import '../widgets/materials_block.dart';

/// Closing out a breakdown — attended time, what was done, parts used.
/// Split from the report itself because none of this is known until the bus
/// is actually fixed; asking for it upfront meant it either sat blank
/// forever or ground staff guessed. This is the one place it's captured.
class ResolveBreakdownScreen extends ConsumerStatefulWidget {
  const ResolveBreakdownScreen({super.key, required this.entryId});

  final String entryId;

  @override
  ConsumerState<ResolveBreakdownScreen> createState() =>
      _ResolveBreakdownScreenState();
}

class _ResolveBreakdownScreenState
    extends ConsumerState<ResolveBreakdownScreen> {
  final _attendedTimeCtl = TextEditingController();
  final _lossCtl = TextEditingController();
  final _attendedDetailsCtl = TextEditingController();
  final _remarksCtl = TextEditingController();
  String _supervisor = '';
  List<MaterialLine> _materials = const <MaterialLine>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _attendedTimeCtl.text = Dates.nowClock();
  }

  @override
  void dispose() {
    _attendedTimeCtl.dispose();
    _lossCtl.dispose();
    _attendedDetailsCtl.dispose();
    _remarksCtl.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final parts = _attendedTimeCtl.text.split(':');
    final initial = parts.length == 2
        ? TimeOfDay(
            hour: int.tryParse(parts[0]) ?? 0,
            minute: int.tryParse(parts[1]) ?? 0,
          )
        : TimeOfDay.now();
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    setState(() {
      _attendedTimeCtl.text =
          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final data = <String, String>{
      if (_attendedTimeCtl.text.trim().isNotEmpty) 't_att': _attendedTimeCtl.text.trim(),
      if (_lossCtl.text.trim().isNotEmpty) 'loss': _lossCtl.text.trim(),
      if (_attendedDetailsCtl.text.trim().isNotEmpty)
        'attended': _attendedDetailsCtl.text.trim(),
      if (_supervisor.isNotEmpty) 'supervisor': _supervisor,
      if (_remarksCtl.text.trim().isNotEmpty) 'remarks': _remarksCtl.text.trim(),
    };
    try {
      await ref
          .read(entriesProvider.notifier)
          .resolveBreakdown(widget.entryId, data: data, materials: _materials);
      if (mounted) {
        ref.read(toastProvider.notifier).show('Breakdown marked resolved');
        context.go(Routes.breakdowns);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ref.read(toastProvider.notifier).show('Could not resolve — $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(entriesProvider).valueOrNull ?? const <RegisterEntry>[];
    final entry = entries.where((e) => e.id == widget.entryId).firstOrNull;
    if (entry == null) {
      return const EmptyState(message: 'That breakdown is no longer available.');
    }

    final master = ref.watch(masterDataProvider).valueOrNull ?? MasterData.empty;
    final supervisorStaff = ref.watch(supervisorStaffProvider).valueOrNull ?? const <String>[];
    final supervisorOptions = supervisorStaff.isNotEmpty ? supervisorStaff : master.staff;

    return FadeUp(
      key: ValueKey<String>('resolve-${widget.entryId}'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: T.maxFormWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              BackLink(onTap: () => context.go(Routes.breakdowns)),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  const CodeSquare(code: 'BD', color: T.red, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Resolve breakdown',
                          style: AppText.sans(size: 21, weight: FontWeight.w700),
                        ),
                        Text(
                          entry.data['complaint'] ?? '',
                          style: AppText.sans(size: 13, color: T.secondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
                decoration: BoxDecoration(
                  color: T.card,
                  borderRadius: T.cardShape,
                  border: Border.all(color: T.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: _labelled(
                            'Bus Attended Time',
                            PickerField(
                              display: _attendedTimeCtl.text,
                              placeholder: '--:--',
                              onTap: _pickTime,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _labelled(
                            'Loss KM',
                            UnitField(controller: _lossCtl, unit: 'km'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _labelled(
                      'Bus Attended Details',
                      AppTextField(
                        controller: _attendedDetailsCtl,
                        placeholder: 'What was done on site',
                        rows: 3,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: _labelled(
                            'Supervisor (Floor)',
                            AppSelect(
                              value: _supervisor.isEmpty ? null : _supervisor,
                              options: supervisorOptions,
                              onChanged: (v) => setState(() => _supervisor = v ?? ''),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _labelled(
                            'Remarks',
                            AppTextField(
                              controller: _remarksCtl,
                              placeholder: 'Optional',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              MaterialsBlock(
                catalog: ref.watch(sapMaterialCatalogProvider).valueOrNull ??
                    const <SapMaterialOption>[],
                onChanged: (lines) => _materials = lines,
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  OutlineActionButton(
                    label: 'Cancel',
                    onPressed: _saving ? null : () => context.go(Routes.breakdowns),
                    fontSize: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledActionButton(
                      label: _saving ? 'Saving…' : 'Mark resolved',
                      onPressed: _saving ? null : _save,
                      fontSize: 16.5,
                      elevated: true,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
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

  Widget _labelled(String label, Widget control) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FieldLabel(label: label),
        control,
      ],
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
