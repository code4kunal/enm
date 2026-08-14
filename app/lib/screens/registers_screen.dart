import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/registers.dart';
import '../models/entry.dart';
import '../router.dart';
import '../state/entries.dart';
import '../state/session.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/csv_export.dart';
import '../widgets/buttons.dart';
import '../widgets/chips.dart';
import '../widgets/code_square.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/form_controls.dart';
import '../models/checklist.dart';
import '../utils/dates.dart';
import '../state/inspections.dart';
import '../widgets/sub_tabs.dart';

class RegistersScreen extends ConsumerStatefulWidget {
  const RegistersScreen({super.key});

  @override
  ConsumerState<RegistersScreen> createState() => _RegistersScreenState();
}

class _RegistersScreenState extends ConsumerState<RegistersScreen> {
  late final TextEditingController _search = TextEditingController(
    text: ref.read(entryFiltersProvider).query,
  );

  bool _exporting = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    if (_exporting) return;
    final rows = ref.read(filteredEntriesProvider);
    final toast = ref.read(toastProvider.notifier);

    if (rows.isEmpty) {
      toast.show('Nothing to export');
      return;
    }

    setState(() => _exporting = true);
    try {
      final count = await CsvExport.share(rows, ref.read(sessionProvider).site);
      toast.show('Exported $count entries');
    } catch (e) {
      toast.show('Export failed — $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(entryFiltersProvider);
    final controller = ref.read(entryFiltersProvider.notifier);
    final results = ref.watch(filteredEntriesProvider);
    final inspections = ref.watch(filteredInspectionsProvider);
    final showingInspections = filters.registerId == kInspectionsFilter;
    final site = ref.watch(sessionProvider.select((s) => s.site));

    return FadeUp(
      key: const ValueKey<String>('registers'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Search + export. The search field flexes; below ~460px the export
          // button drops to its own line.
          LayoutBuilder(
            builder: (context, constraints) {
              final search = AppTextField(
                controller: _search,
                placeholder: 'Search bus no, defect, employee…',
                onChanged: controller.setQuery,
              );
              final export = FilledActionButton.ink(
                label: _exporting ? 'Exporting…' : 'Export Excel (CSV)',
                onPressed: _exporting ? null : _export,
                fontSize: 14,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              );

              if (constraints.maxWidth < 460) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    search,
                    const SizedBox(height: 10),
                    export,
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: search),
                  const SizedBox(width: 10),
                  export,
                ],
              );
            },
          ),
          const SizedBox(height: 12),

          // Register filter chips.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              PillChip(
                label: 'All registers',
                selected: filters.registerId == 'all',
                onTap: () => controller.setRegister('all'),
              ),
              // Inspections sit beside the registers rather than in them: a
              // checklist sweep is not a defect noticed, and its row says
              // different things. But it is still what the depot did that day.
              PillChip(
                label: 'Inspections',
                selected: filters.registerId == kInspectionsFilter,
                onTap: () => controller.setRegister(kInspectionsFilter),
              ),
              for (final r in kRegisters)
                PillChip(
                  label: r.name,
                  selected: filters.registerId == r.id,
                  onTap: () => controller.setRegister(r.id),
                ),
            ],
          ),
          const SizedBox(height: 10),

          // Period chips.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                'PERIOD',
                style: AppText.sans(
                  size: 12,
                  weight: FontWeight.w700,
                  color: T.muted,
                  letterSpacing: 0.08 * 12,
                ),
              ),
              for (final m in DateMode.values)
                PillChip(
                  label: m.label,
                  dense: true,
                  tone: ChipTone.green,
                  selected: filters.dateMode == m,
                  onTap: () => controller.setDateMode(m),
                ),
              if (filters.dateMode == DateMode.custom) ...<Widget>[
                _DateBound(
                  value: filters.from,
                  label: 'From',
                  onChanged: controller.setFrom,
                ),
                Text('to', style: AppText.sans(size: 13, color: T.muted)),
                _DateBound(
                  value: filters.to,
                  label: 'To',
                  onChanged: controller.setTo,
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),

          if (showingInspections) ...<Widget>[
            Text(
              '${inspections.length} '
              '${inspections.length == 1 ? 'inspection' : 'inspections'} · $site',
              style: AppText.sans(size: 13, color: T.secondary),
            ),
            const SizedBox(height: 10),
            if (inspections.isEmpty)
              const EmptyState(message: 'No matching inspections.')
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final i in inspections) ...<Widget>[
                    _InspectionRow(entry: i),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            const SizedBox(height: 32),
          ] else ...<Widget>[
          Text(
            '${results.length} ${results.length == 1 ? 'entry' : 'entries'} · $site',
            style: AppText.sans(size: 13, color: T.secondary),
          ),
          const SizedBox(height: 10),

          if (results.isEmpty)
            const EmptyState(message: 'No matching entries.')
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final e in results) ...<Widget>[
                  _ResultRow(entry: e),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One inspection, as the register list shows it.
///
/// Reads differently from a register row on purpose: an inspection has no
/// defect and no source, it has a bus, a sweep, and how many lines came back
/// not OK — which is the only part a supervisor scans for.
class _InspectionRow extends StatelessWidget {
  const _InspectionRow({required this.entry});

  final InspectionEntry entry;

  @override
  Widget build(BuildContext context) {
    final failed = entry.failedCount;
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              TagBadge(
                label: entry.workTypeCode,
                background: T.subtleFill,
                foreground: T.secondary,
              ),
              const SizedBox(width: 8),
              Text(entry.registrationNo, style: AppText.mono(size: 13.5)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${Dates.dayLabel(entry.inspectedOn)}'
                  '${entry.doneBy == null || entry.doneBy!.isEmpty ? '' : ' · ${entry.doneBy}'}',
                  style: AppText.meta,
                ),
              ),
              TagBadge(
                label: failed == 0 ? 'ALL OK' : '$failed NOT OK',
                background: failed == 0 ? T.greenTint : T.redTint,
                foreground: failed == 0 ? T.greenInk : T.red,
              ),
            ],
          ),
          if (failed > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              entry.results
                  .where((r) => r.result == CheckResult.notOk)
                  .map((r) => r.label)
                  .join(' · '),
              style: AppText.bodyText,
            ),
          ],
          if ((entry.remarks ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(entry.remarks!, style: AppText.meta),
          ],
        ],
      ),
    );
  }
}

/// Compact date input for the custom-range bounds.
class _DateBound extends StatelessWidget {
  const _DateBound({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: InkWell(
        onTap: () async {
          final current = DateTime.tryParse(value) ?? DateTime.now();
          final picked = await showDatePicker(
            context: context,
            initialDate: current,
            firstDate: DateTime(current.year - 3),
            lastDate: DateTime(current.year + 1),
            helpText: 'Select $label date',
          );
          if (picked != null) {
            onChanged(
              '${picked.year.toString().padLeft(4, '0')}-'
              '${picked.month.toString().padLeft(2, '0')}-'
              '${picked.day.toString().padLeft(2, '0')}',
            );
          }
        },
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: T.card,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: T.inputBorder, width: 1.5),
          ),
          child: Text(
            value.isEmpty ? label : value,
            style: AppText.mono(
              size: 13.5,
              weight: FontWeight.w600,
              color: value.isEmpty ? T.muted : T.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.entry});

  final RegisterEntry entry;

  @override
  Widget build(BuildContext context) {
    final register = requireRegister(entry.registerId);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    CodeTag(code: register.code, color: register.color),
                    Text(
                      entry.busNumber,
                      style: AppText.mono(size: 14.5, weight: FontWeight.w600),
                    ),
                    Text(
                      '${entry.date} · ${entry.site} · ${entry.enteredBy}',
                      style: AppText.meta,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              OutlineActionButton(
                label: 'Edit',
                onPressed: () => context.go(Routes.editEntry(entry.id)),
                accent: T.green,
                fontSize: 12.5,
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(entrySummary(entry), style: AppText.bodyText),
        ],
      ),
    );
  }
}
