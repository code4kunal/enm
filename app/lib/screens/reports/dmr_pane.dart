import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/report.dart';
import '../../state/reports.dart';
import '../../state/session.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/report_download.dart';
import '../../widgets/sub_tabs.dart';

/// The Daily Maintenance Report for one day.
///
/// Derived lines and entered lines sit in one list in the depot's own order,
/// distinguished by whether they can be typed into. A supervisor reads down the
/// numbered sheet they already know and fills the handful of gaps the registers
/// cannot answer — rather than copying twenty figures across from elsewhere.
class DmrPane extends ConsumerStatefulWidget {
  const DmrPane({super.key});

  @override
  ConsumerState<DmrPane> createState() => _DmrPaneState();
}

class _DmrPaneState extends ConsumerState<DmrPane> {
  final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{};
  final TextEditingController _notes = TextEditingController();
  String _loadedFor = '';
  bool _saving = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  /// Reload the boxes when the day changes, but never while someone is typing
  /// into them.
  void _sync(DmrDay day) {
    final stamp = '${day.siteCode}:${day.reportDate}';
    if (_loadedFor == stamp) return;
    _loadedFor = stamp;
    for (final line in day.entered) {
      final controller =
          _fields.putIfAbsent(line.key, TextEditingController.new);
      controller.text = line.value == null ? '' : line.value!.round().toString();
    }
    _notes.text = day.notes;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final values = <String, int?>{
        for (final e in _fields.entries)
          e.key: e.value.text.trim().isEmpty
              ? null
              : int.tryParse(e.value.text.trim()),
      };
      await ref
          .read(reportControllerProvider)
          .saveEntered(values, notes: _notes.text.trim());
      ref.read(toastProvider.notifier).show('Report saved');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _snapshot() async {
    setState(() => _saving = true);
    try {
      await ref.read(reportControllerProvider).snapshot();
      ref
          .read(toastProvider.notifier)
          .show('Day frozen — the derived lines will not move again');
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dmrDayProvider);
    final canEdit = ref.watch(sessionProvider).can('em_report:write');

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: e.toString()),
      data: (day) {
        if (day.lines.isEmpty) {
          return const EmptyState(message: 'No report for this day yet.');
        }
        _sync(day);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Banner(day: day),
            const SizedBox(height: 14),
            Panel(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final line in day.lines)
                    _Row(
                      line: line,
                      controller: _fields[line.key],
                      enabled: canEdit && !line.derived,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const FieldLabel(label: 'Notes'),
                  const SizedBox(height: 6),
                  AppTextField(
                    controller: _notes,
                    placeholder: 'Anything the report should carry',
                    rows: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                if (canEdit) ...<Widget>[
                  Expanded(
                    child: FilledActionButton(
                      label: _saving ? 'Saving…' : 'Save entered lines',
                      expand: true,
                      onPressed: _saving ? null : _save,
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlineActionButton(
                    label: day.isSnapshot ? 'Re-freeze' : 'Freeze day',
                    onPressed: _saving ? null : _snapshot,
                  ),
                  const SizedBox(width: 10),
                ],
                ReportDownloadButton(
                  doc: ReportDoc.dmrDay,
                  date: day.reportDate,
                ),
              ],
            ),
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.day});

  final DmrDay day;

  @override
  Widget build(BuildContext context) {
    final outstanding = day.unanswered;
    final frozen = day.isSnapshot;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: frozen ? T.subtleFill : T.amberTint,
        borderRadius: T.cardSmShape,
        border: Border.all(color: frozen ? T.border : T.amber),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TagBadge(
            label: frozen ? 'FROZEN' : 'OPEN',
            background: T.card,
            foreground: frozen ? T.secondary : T.amber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              frozen
                  ? 'Reported as it stood at the end of the day. The computed '
                      'lines will not move again.'
                  : outstanding == 0
                      ? 'Computed lines update as the registers are written. '
                          'Freeze the day to fix them as reported.'
                      : '$outstanding line${outstanding == 1 ? '' : 's'} still '
                          'to enter — nothing in the system observes those.',
              style: AppText.sans(
                size: 13,
                color: frozen ? T.body : T.amber,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One numbered line. A derived line shows its figure; an entered line offers a
/// box, so which is which is obvious without a legend.
class _Row extends StatelessWidget {
  const _Row({
    required this.line,
    required this.controller,
    required this.enabled,
  });

  final DmrLine line;
  final TextEditingController? controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 30,
            child: Text(
              '${line.number}',
              style: AppText.mono(size: 12, color: T.muted),
            ),
          ),
          Expanded(
            child: Text(
              line.label,
              style: AppText.sans(
                size: 13.5,
                weight: line.derived ? FontWeight.w400 : FontWeight.w600,
                color: line.derived ? T.body : T.ink,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            child: line.derived
                ? Text(
                    line.display,
                    textAlign: TextAlign.right,
                    style: AppText.mono(
                      size: 14,
                      color: line.isBlank ? T.muted : T.ink,
                    ),
                  )
                : (controller == null
                    ? const SizedBox.shrink()
                    : AppTextField(
                        controller: controller!,
                        placeholder: '—',
                        numeric: true,
                        enabled: enabled,
                      )),
          ),
        ],
      ),
    );
  }
}

/// The month grid: parameters down, one column per day.
///
/// Rendered as a scrolling table rather than a chart because this is the shape
/// the depot sends on, and reading across a row is how a trend gets spotted.
class DmrMonthPane extends ConsumerWidget {
  const DmrMonthPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dmrMonthProvider);
    final month = ref.watch(reportMonthProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            OutlineActionButton(
              label: '‹',
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              onPressed: () => ref
                  .read(reportMonthProvider.notifier)
                  .state = Dates.shiftMonth(month, -1),
            ),
            Expanded(
              child: Center(
                child: Text(
                  Dates.monthLabel('$month-01'),
                  style: AppText.sans(size: 15, weight: FontWeight.w700),
                ),
              ),
            ),
            OutlineActionButton(
              label: '›',
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              onPressed: () => ref
                  .read(reportMonthProvider.notifier)
                  .state = Dates.shiftMonth(month, 1),
            ),
            const SizedBox(width: 10),
            ReportDownloadButton(doc: ReportDoc.dmrMonth, month: month),
            const SizedBox(width: 10),
            ReportDownloadButton(
              doc: ReportDoc.dmrMonth,
              month: month,
              format: 'xlsx',
              label: 'Download Excel',
            ),
          ],
        ),
        const SizedBox(height: 14),
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => EmptyState(message: e.toString()),
          data: (grid) {
            if (grid.dates.isEmpty) {
              return const EmptyState(message: 'Nothing reported this month.');
            }
            return Panel(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _MonthRow(
                      label: 'Parameter',
                      cells: [
                        for (final d in grid.dates) Dates.dayOfMonth(d),
                      ],
                      header: true,
                    ),
                    for (final line in grid.lines)
                      _MonthRow(
                        label: '${line.number}. ${line.label}',
                        derived: line.derived,
                        cells: [
                          for (final v in grid.valuesFor(line.key))
                            v == null
                                ? '—'
                                : (line.isDecimal
                                    ? v.toStringAsFixed(1)
                                    : v.round().toString()),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _MonthRow extends StatelessWidget {
  const _MonthRow({
    required this.label,
    required this.cells,
    this.header = false,
    this.derived = true,
  });

  final String label;
  final List<String> cells;
  final bool header;
  final bool derived;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: header ? T.inputBorder : T.border),
        ),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 290,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.sans(
                  size: 12.5,
                  weight: header || !derived ? FontWeight.w700 : FontWeight.w400,
                  color: header ? T.ink : (derived ? T.body : T.ink),
                ),
              ),
            ),
          ),
          for (final cell in cells)
            SizedBox(
              width: 44,
              child: Text(
                cell,
                textAlign: TextAlign.center,
                style: AppText.mono(
                  size: 11.5,
                  weight: header ? FontWeight.w700 : FontWeight.w600,
                  color: cell == '—' ? T.muted : T.ink,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
