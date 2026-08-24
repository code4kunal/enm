import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/report.dart';
import '../../models/site.dart';
import '../../state/providers.dart';
import '../../state/reports.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/dates.dart';
import '../../widgets/buttons.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/report_download.dart';
import '../../widgets/sub_tabs.dart';
import 'units_pane.dart';

/// One bus's history card: every unit down the side, thirteen months across.
///
/// Every unit is a row whether or not it was ever touched, because the empty
/// rows are as much of the record as the filled ones — a card is read to find
/// what has *not* been changed as often as what has.
class HistoryPane extends ConsumerWidget {
  const HistoryPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleet = (ref.watch(siteVehiclesProvider).valueOrNull ?? <Vehicle>[])
        .where((v) => v.isActive)
        .toList();
    final vehicleId = ref.watch(historyVehicleProvider);
    final month = ref.watch(historyMonthProvider);
    final search = ref.watch(historySearchProvider);
    final needle = search.trim().toLowerCase();
    final matches = needle.isEmpty
        ? fleet
        : fleet
            .where((v) => v.registrationNo.toLowerCase().contains(needle))
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: TextField(
                onChanged: (v) =>
                    ref.read(historySearchProvider.notifier).state = v,
                style: AppText.mono(size: 16, weight: FontWeight.w600),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Search a bus…',
                  prefixIcon: Icon(Icons.search, color: T.secondary, size: 20),
                  filled: true,
                  fillColor: T.card,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: T.controlShape,
                    borderSide: BorderSide(color: T.inputBorder, width: 1.5),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: T.controlShape,
                    borderSide: BorderSide(color: T.inputBorder, width: 1.5),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: AppSelect(
                value: matches
                    .where((v) => v.id == vehicleId)
                    .map((v) => v.registrationNo)
                    .firstOrNull,
                options: matches.map((v) => v.registrationNo).toList(),
                placeholder: '${matches.length} bus${matches.length == 1 ? '' : 'es'}',
                mono: true,
                onChanged: (reg) => ref
                    .read(historyVehicleProvider.notifier)
                    .state = matches.firstWhere((v) => v.registrationNo == reg).id,
              ),
            ),
            const SizedBox(width: 10),
            OutlineActionButton(
              label: '‹',
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              onPressed: () => ref
                  .read(historyMonthProvider.notifier)
                  .state = Dates.shiftMonth(month, -1),
            ),
            const SizedBox(width: 6),
            Text(
              Dates.monthLabel('$month-01'),
              style: AppText.sans(size: 14, weight: FontWeight.w700),
            ),
            const SizedBox(width: 6),
            OutlineActionButton(
              label: '›',
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              onPressed: () => ref
                  .read(historyMonthProvider.notifier)
                  .state = Dates.shiftMonth(month, 1),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (vehicleId.isEmpty)
          const EmptyState(
            message: 'Pick a bus — a history card is one bus at a time.',
          )
        else
          const _Card(),
        const SizedBox(height: 32),
      ],
    );
  }
}

class _Card extends ConsumerWidget {
  const _Card();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(busHistoryProvider);
    final canEdit = ref.watch(sessionProvider).canManageSites;

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: e.toString()),
      data: (card) {
        if (card.rows.isEmpty) {
          return const EmptyState(
            message: 'No units are being tracked yet. The site masters hold '
                'that list.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    card.events == 0
                        ? '${card.registrationNo} — nothing changed in these '
                            '${card.months.length} months'
                        : '${card.registrationNo} — ${card.events} '
                            'change${card.events == 1 ? '' : 's'} across '
                            '${card.rows.length} units',
                    style: AppText.sans(
                      size: 13.5,
                      weight: FontWeight.w600,
                      color: card.events == 0 ? T.muted : T.body,
                    ),
                  ),
                ),
                if (canEdit) ...<Widget>[
                  const _RemoveButton(),
                  const SizedBox(width: 8),
                ],
                ReportDownloadButton(
                  doc: ReportDoc.busHistory,
                  vehicleId: card.vehicleId,
                  month: ref.watch(historyMonthProvider),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Panel(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _HeaderRow(months: card.months),
                    for (final row in card.rows) _UnitRow(row: row),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'A block is the day the unit went on or came off. A green name '
              'is a unit currently fitted.',
              style: AppText.meta,
            ),
          ],
        );
      },
    );
  }
}

/// Takes a unit off the bus whose card is open.
class _RemoveButton extends ConsumerWidget {
  const _RemoveButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fitted = ref.watch(fittedUnitsProvider).valueOrNull ?? <FittedUnit>[];
    if (fitted.isEmpty) return const SizedBox.shrink();

    return OutlineActionButton(
      label: 'Remove a unit',
      onPressed: () async {
        final picked = await showModalBottomSheet<FittedUnit>(
          context: context,
          useRootNavigator: true,
          backgroundColor: T.card,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: T.rCard),
          ),
          builder: (_) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 14),
                Text('What came off?', style: AppText.sectionTitle),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      for (final unit in fitted)
                        ListTile(
                          title: Text(
                            unit.unitName,
                            style: AppText.sans(size: 14),
                          ),
                          subtitle: Text(
                            'fitted ${Dates.dayLabel(unit.fittedOn)}',
                            style: AppText.meta,
                          ),
                          onTap: () => Navigator.of(context).pop(unit),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
        if (picked != null && context.mounted) {
          await showRemoveUnitEditor(context, ref, picked);
        }
      },
    );
  }
}

const double _kUnitColumn = 190;
const double _kMonthColumn = 44;
const double _kRowHeight = 26;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.months});

  final List<String> months;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.inputBorder)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _kUnitColumn,
            height: _kRowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Name of unit',
                style: AppText.sans(size: 12, weight: FontWeight.w700),
              ),
            ),
          ),
          for (final month in months)
            SizedBox(
              width: _kMonthColumn,
              height: _kRowHeight,
              child: Center(
                child: Text(
                  // "Aug 2026" is too wide for the column; the month alone is
                  // what the paper card carries.
                  Dates.monthLabel('$month-01').split(' ').first,
                  style: AppText.sans(size: 11, weight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({required this.row});

  final HistoryRow row;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _kUnitColumn,
            height: _kRowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                row.unitName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.sans(
                  size: 12.5,
                  weight: row.fittedNow ? FontWeight.w700 : FontWeight.w400,
                  color: row.fittedNow ? T.greenInk : T.body,
                ),
              ),
            ),
          ),
          for (final cell in row.cells) _Block(event: cell),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.event});

  final HistoryEvent? event;

  @override
  Widget build(BuildContext context) {
    final event = this.event;
    final block = Container(
      width: _kMonthColumn,
      height: _kRowHeight,
      margin: const EdgeInsets.all(0.5),
      decoration: BoxDecoration(
        color: switch (event?.kind) {
          'fitted' => T.greenTint,
          'removed' => T.redTint,
          'replaced' => T.amberTint,
          _ => Colors.transparent,
        },
        borderRadius: BorderRadius.circular(3),
      ),
      alignment: Alignment.center,
      child: event == null
          ? null
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  event.label,
                  maxLines: 1,
                  style: AppText.mono(
                    size: 11,
                    weight: FontWeight.w700,
                    color: switch (event.kind) {
                      'fitted' => T.greenInk,
                      'removed' => T.red,
                      _ => T.amber,
                    },
                  ),
                ),
              ),
            ),
    );
    if (event == null) return block;

    // The block holds a day number; everything else about the change — why it
    // came off, what it did — belongs on the hover rather than in 44 pixels.
    final detail = <String>[
      event.kind,
      if (event.unitNo.isNotEmpty) 'unit ${event.unitNo}',
      if (event.kmsCovered != null) '${event.kmsCovered} km',
      if (event.reason.isNotEmpty) event.reason,
    ].join(' · ');
    return Tooltip(message: detail, child: block);
  }
}
