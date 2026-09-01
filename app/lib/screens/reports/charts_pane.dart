import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/entry.dart';
import '../../models/report.dart';
import '../../state/entries.dart';
import '../../state/providers.dart';
import '../../state/reports.dart';
import '../../state/session.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dashed.dart';
import '../../widgets/report_download.dart';
import '../../widgets/sub_tabs.dart';
import '../register_form_screen.dart';

/// Which register a chart's blocks come from, when they come from one at
/// all — the inspection- and checklist-sourced charts (P.M schedule, D.I,
/// the ten-day service, tyre pressure, bus washing) have no register to
/// open, so their cells stay untappable rather than opening an empty list.
String? _registerIdFor(String kind) {
  switch (kind) {
    case 'coolantTopping':
      return 'coolant';
    case 'driverComplaints':
      return 'complaint';
    case 'breakdowns':
      return 'breakdown';
    default:
      return null;
  }
}

/// Annexure-IV: the fleet down the side, the month across the top.
///
/// The grid is the report — a month of one thing for every bus at once is how
/// a gap becomes visible, which no list of entries does. The colours are the
/// depot's own: a shaded block is a service day, a red one a docking or a
/// breakdown.
class ChartsPane extends ConsumerWidget {
  const ChartsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kinds = ref.watch(chartKindsProvider);
    final month = ref.watch(chartMonthProvider);

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
                  .read(chartMonthProvider.notifier)
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
                  .read(chartMonthProvider.notifier)
                  .state = Dates.shiftMonth(month, 1),
            ),
          ],
        ),
        const SizedBox(height: 12),
        kinds.when(
          loading: () => const _Waiting(),
          error: (e, _) => EmptyState(message: e.toString()),
          data: _ChartPicker.new,
        ),
        const SizedBox(height: 14),
        Builder(
          builder: (context) {
            final selectedKind = ref.watch(chartKindProvider);
            // Excel only for the two charts a block's full text is worth
            // reading out of a spreadsheet for — every other chart is a
            // grid of short codes a PDF already shows just as well.
            final hasExcel = selectedKind == 'driverComplaints' ||
                selectedKind == 'breakdowns';
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                ReportDownloadButton(
                  doc: ReportDoc.controlChart,
                  chartKind: selectedKind,
                  fromDate: '$month-01',
                  toDate: Dates.lastOfMonth(month),
                ),
                if (hasExcel)
                  ReportDownloadButton(
                    doc: ReportDoc.controlChart,
                    chartKind: selectedKind,
                    fromDate: '$month-01',
                    toDate: Dates.lastOfMonth(month),
                    format: 'xlsx',
                    label: 'Download Excel',
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        const _ChartGrid(),
        const SizedBox(height: 32),
      ],
    );
  }
}

/// The six charts as chips. An unavailable one stays on the list rather than
/// being hidden — that the depot keeps this chart and the system cannot yet
/// fill it is itself worth seeing.
class _ChartPicker extends ConsumerWidget {
  const _ChartPicker(this.kinds);

  final List<ChartKind> kinds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(chartKindProvider);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final chart in kinds)
          _KindChip(
            label: chart.title,
            selected: chart.kind == selected,
            dimmed: !chart.available,
            onTap: () =>
                ref.read(chartKindProvider.notifier).state = chart.kind,
          ),
      ],
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.label,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: T.cardSmShape,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? T.greenTint : T.card,
          borderRadius: T.cardSmShape,
          border: Border.all(color: selected ? T.green : T.border),
        ),
        child: Text(
          label,
          style: AppText.sans(
            size: 12.5,
            weight: selected ? FontWeight.w700 : FontWeight.w500,
            color: dimmed ? T.muted : (selected ? T.greenInk : T.body),
          ),
        ),
      ),
    );
  }
}

class _ChartGrid extends ConsumerWidget {
  const _ChartGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(controlChartProvider);

    return async.when(
      loading: () => const _Waiting(),
      error: (e, _) => EmptyState(message: e.toString()),
      data: (chart) {
        if (!chart.available) {
          return _Unavailable(chart: chart);
        }
        if (chart.rows.isEmpty) {
          return const EmptyState(
            message: 'No buses at this site yet — nothing to chart.',
          );
        }
        final registerId = _registerIdFor(chart.kind);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              chart.filled == 0
                  ? '${chart.title} — nothing recorded this month'
                  : '${chart.title} — ${chart.filled} '
                      'block${chart.filled == 1 ? '' : 's'} filled across '
                      '${chart.rows.length} buses',
              style: AppText.sans(
                size: 13.5,
                weight: FontWeight.w600,
                color: chart.filled == 0 ? T.amber : T.body,
              ),
            ),
            const SizedBox(height: 10),
            Panel(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // A day column no wider than it has to be on a phone, but
                  // one that actually uses a desktop's width instead of
                  // staying phone-sized and forcing "2.5" or "BD2" through
                  // the same aggressive scale-down a 34px block needs — that
                  // scale-down is what reads as garbled at a glance.
                  final dayWidth = ((constraints.maxWidth - _kBusColumn) /
                          chart.dates.length)
                      .clamp(_kDayColumnMin, _kDayColumnMax);
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _HeaderRow(dates: chart.dates, dayWidth: dayWidth),
                        for (final row in chart.rows)
                          _BusRow(
                            row: row,
                            dates: chart.dates,
                            registerId: registerId,
                            dayWidth: dayWidth,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            _Legend(chart: chart),
          ],
        );
      },
    );
  }
}

const double _kBusColumn = 132;
const double _kDayColumnMin = 34;
const double _kDayColumnMax = 56;
const double _kRowHeight = 26;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.dates, required this.dayWidth});

  final List<String> dates;
  final double dayWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.inputBorder)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _kBusColumn,
            height: _kRowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Bus No',
                style: AppText.sans(size: 12, weight: FontWeight.w700),
              ),
            ),
          ),
          for (final date in dates)
            SizedBox(
              width: dayWidth,
              height: _kRowHeight,
              child: Center(
                child: Text(
                  Dates.dayOfMonth(date),
                  style: AppText.mono(size: 11, weight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BusRow extends StatelessWidget {
  const _BusRow({
    required this.row,
    required this.dates,
    required this.dayWidth,
    this.registerId,
  });

  final ChartRow row;
  final List<String> dates;
  final double dayWidth;
  final String? registerId;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _kBusColumn,
            height: _kRowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(row.registrationNo, style: AppText.mono(size: 11.5)),
            ),
          ),
          for (var i = 0; i < row.cells.length; i++)
            _Block(
              cell: row.cells[i],
              registerId: registerId,
              registrationNo: row.registrationNo,
              date: dates[i],
              dayWidth: dayWidth,
            ),
        ],
      ),
    );
  }
}

/// One block. The column is only as wide as the window has room for — up to
/// [_kDayColumnMax], down to [_kDayColumnMin] on a phone — and the value can
/// still be longer than that, a ten-day service code being the usual case,
/// so it shrinks rather than clipping. The whole value is on the tooltip
/// either way.
///
/// Tappable when [registerId] is set: opens Registers filtered to that
/// register, that bus, and that single day. Charts with no register behind
/// them (the inspection- and checklist-sourced ones) pass `null` and stay
/// untappable — there is nothing for a tap to open.
class _Block extends ConsumerWidget {
  const _Block({
    required this.cell,
    required this.registerId,
    required this.registrationNo,
    required this.date,
    required this.dayWidth,
  });

  final ChartCell cell;
  final String? registerId;
  final String registrationNo;
  final String date;
  final double dayWidth;

  static const Map<CellMark, Color> _fill = <CellMark, Color>{
    CellMark.plain: Colors.transparent,
    CellMark.pm: T.amberTint,
    CellMark.breakdown: T.redTint,
  };

  static const Map<CellMark, Color> _ink = <CellMark, Color>{
    CellMark.plain: T.ink,
    CellMark.pm: T.amber,
    CellMark.breakdown: T.red,
  };

  /// Opens the entry(s) behind this block as a sheet over the chart —
  /// never a route change, so the chart is exactly where the user left it
  /// once the sheet closes.
  Future<void> _openEntry(WidgetRef ref, BuildContext context) async {
    final id = registerId;
    if (id == null) return;
    final site = ref.read(sessionProvider).site;
    // A direct, day-scoped fetch — not the Registers list's cache, which is
    // capped to a site's 200 most recent entries and can miss an older day
    // a control chart is still showing.
    List<RegisterEntry> dayEntries;
    try {
      dayEntries = await ref.read(entryRepositoryProvider).fetchEntries(
            site: site,
            registerId: id,
            dateFrom: date,
            dateTo: date,
          );
    } catch (e) {
      ref.read(toastProvider.notifier).show('Could not load the entry — $e');
      return;
    }
    final matches = dayEntries
        .where((e) => e.data['bus'] == registrationNo)
        .toList();

    if (matches.isEmpty) {
      ref.read(toastProvider.notifier).show('No entry found for this day');
      return;
    }
    if (!context.mounted) return;
    if (matches.length == 1) {
      await showRegisterEntrySheet(context, entryId: matches.first.id);
      return;
    }
    final picked = await showModalBottomSheet<RegisterEntry>(
      context: context,
      useRootNavigator: true,
      backgroundColor: T.card,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final entry in matches)
              ListTile(
                title: Text(entry.time, style: AppText.mono(size: 13)),
                subtitle: Text(entrySummary(entry)),
                onTap: () => Navigator.of(sheetContext).pop(entry),
              ),
          ],
        ),
      ),
    );
    if (picked != null && context.mounted) {
      await showRegisterEntrySheet(context, entryId: picked.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tappable = registerId != null && !cell.isEmpty;
    // Fixed outer footprint, matching `_HeaderRow`'s date cell exactly — a
    // margin here (rather than this inset padding) would grow each block by
    // half a pixel per side, drifting the grid a column further from its
    // date header with every column to the right.
    final block = SizedBox(
      width: dayWidth,
      height: _kRowHeight,
      child: Padding(
        padding: const EdgeInsets.all(0.5),
        child: Container(
          decoration: BoxDecoration(
            color: _fill[cell.mark] ?? Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: cell.value.isEmpty
              ? null
              : FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      cell.value,
                      maxLines: 1,
                      style: AppText.mono(
                        size: 11,
                        weight: FontWeight.w700,
                        color: _ink[cell.mark] ?? T.ink,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
    final wrapped = tappable
        ? InkWell(
            borderRadius: BorderRadius.circular(3),
            onTap: () => _openEntry(ref, context),
            child: block,
          )
        : block;
    if (cell.isEmpty) return wrapped;
    // The block often shows a shortened code, so the full one has to be
    // reachable — otherwise "10D" is the only record of a ten-day service.
    final full = cell.title.isNotEmpty
        ? cell.title
        : (cell.value.isEmpty ? cell.mark.name : cell.value);
    return Tooltip(message: full, child: wrapped);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.chart});

  final ControlChart chart;

  @override
  Widget build(BuildContext context) {
    final marks = <CellMark>{
      for (final row in chart.rows)
        for (final cell in row.cells)
          if (cell.mark != CellMark.plain) cell.mark,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(chart.legend, style: AppText.meta),
        if (marks.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: <Widget>[
              if (marks.contains(CellMark.pm))
                const _Swatch(mark: CellMark.pm, label: 'PM attended'),
              if (marks.contains(CellMark.breakdown))
                const _Swatch(mark: CellMark.breakdown, label: 'Breakdown'),
            ],
          ),
        ],
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.mark, required this.label});

  final CellMark mark;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: mark == CellMark.pm ? T.amberTint : T.redTint,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: mark == CellMark.pm ? T.amber : T.red),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: AppText.meta),
      ],
    );
  }
}

/// A chart the depot keeps that this system cannot yet fill.
///
/// Shown as the reason rather than as an empty grid: a blank chart and an
/// unanswerable one look identical, and only one of them is a depot problem.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.chart});

  final ControlChart chart;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: T.subtleFill,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(chart.title, style: AppText.cardTitle),
          const SizedBox(height: 6),
          Text(
            chart.unavailableReason,
            style: AppText.sans(size: 13, color: T.body, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
}
