import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/inspection.dart';
import '../state/schedule.dart';
import '../state/session.dart';
import '../state/toast.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/dates.dart';
import '../widgets/buttons.dart';
import '../widgets/chips.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/sub_tabs.dart';
import 'schedule/alerts_pane.dart';
import 'schedule/slot_editor.dart';

/// The inspection calendar and the alert log.
///
/// Laid out as a notebook rather than a table: a month of cells you can scan
/// for how heavy a night is, and one day opened at a time underneath. A depot
/// supervisor reads this at the start of a shift and needs to answer "what is
/// in tonight" in one look.
class ScheduleScreen extends ConsumerStatefulWidget {
  const ScheduleScreen({super.key});

  @override
  ConsumerState<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends ConsumerState<ScheduleScreen> {
  int _pane = 0;
  String _selected = Dates.today();
  bool _generating = false;

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      final result = await ref.read(scheduleControllerProvider).generate();
      ref.read(toastProvider.notifier).show(result.summary);
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session.site.isEmpty) {
      return const EmptyState(message: 'Pick a site first.');
    }

    return FadeUp(
      key: ValueKey<String>('schedule-${session.site}-$_pane'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(
            generating: _generating,
            canGenerate: session.can('em_schedule:write'),
            onGenerate: _generate,
          ),
          const SizedBox(height: 16),
          SubTabs(
            labels: const <String>['Calendar', 'Alerts'],
            selectedIndex: _pane,
            onChanged: (i) => setState(() => _pane = i),
          ),
          const SizedBox(height: 20),
          if (_pane == 0)
            _CalendarPane(
              selected: _selected,
              onSelect: (d) => setState(() => _selected = d),
            )
          else
            const AlertsPane(),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.generating,
    required this.canGenerate,
    required this.onGenerate,
  });

  final bool generating;
  final bool canGenerate;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calendar = ref.watch(calendarProvider).valueOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Schedule', style: AppText.pageTitle),
              const SizedBox(height: 4),
              Text(
                'Generated nightly at 22:00. Missed work moves to the front '
                'of the queue.',
                style: AppText.meta,
              ),
              if (calendar != null) ...<Widget>[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _Stat(label: 'Scheduled', value: calendar.scheduled),
                    _Stat(
                      label: 'Done',
                      value: calendar.done,
                      background: T.greenTint,
                      foreground: T.greenInk,
                    ),
                    if (calendar.missed > 0)
                      _Stat(
                        label: 'Missed',
                        value: calendar.missed,
                        background: T.redTint,
                        foreground: T.redInk,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (canGenerate) ...<Widget>[
          const SizedBox(width: 12),
          OutlineActionButton(
            label: generating ? 'Running…' : 'Run now',
            onPressed: generating ? null : onGenerate,
          ),
        ],
      ],
    );
  }
}

/// A read-only count. Not a [PillChip]: these are not filters and must not
/// look tappable.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.background = T.subtleFill,
    this.foreground = T.body,
  });

  final String label;
  final int value;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: T.pillShape,
        border: Border.all(color: T.border),
      ),
      child: Text(
        '$label · $value',
        style: AppText.sans(
          size: 12.5,
          weight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

class _CalendarPane extends ConsumerWidget {
  const _CalendarPane({required this.selected, required this.onSelect});

  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(calendarProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: e.toString()),
      data: (calendar) {
        if (calendar.days.isEmpty) {
          return const EmptyState(
            message: 'Nothing scheduled yet — run the generator.',
          );
        }
        final day = calendar.dayOf(selected) ?? calendar.days.first;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _MonthGrid(
              calendar: calendar,
              selected: day.date,
              onSelect: onSelect,
            ),
            const SizedBox(height: 20),
            _DayAgenda(day: day),
          ],
        );
      },
    );
  }
}

/// The month view: one cell per day, weighted by how much is booked.
class _MonthGrid extends ConsumerWidget {
  const _MonthGrid({
    required this.calendar,
    required this.selected,
    required this.onSelect,
  });

  final InspectionCalendar calendar;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = ref.watch(calendarWindowProvider);
    final today = Dates.today();

    return Panel(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _PageButton(
                icon: Icons.chevron_left,
                tooltip: 'Earlier',
                onTap: () => ref
                    .read(calendarWindowProvider.notifier)
                    .update((w) => w.shift(-w.days)),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _rangeLabel(calendar),
                    style: AppText.sans(size: 15, weight: FontWeight.w700),
                  ),
                ),
              ),
              _PageButton(
                icon: Icons.chevron_right,
                tooltip: 'Later',
                onTap: () => ref
                    .read(calendarWindowProvider.notifier)
                    .update((w) => w.shift(w.days)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Center(
            child: TextButton(
              onPressed: () => ref
                  .read(calendarWindowProvider.notifier)
                  .update((w) => CalendarWindow.around(today, days: w.days)),
              child: Text(
                'Back to today',
                style: AppText.sans(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: T.green,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const _WeekdayStrip(),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              // Pad the first week so a date lands under its weekday column,
              // the way a wall calendar reads.
              final lead = Dates.weekday(calendar.days.first.date) - 1;
              final cells = <Widget?>[
                for (var i = 0; i < lead; i++) null,
                ...calendar.days.map<Widget?>((d) => _DayCell(
                      day: d,
                      isToday: d.date == today,
                      isSelected: d.date == selected,
                      onTap: () => onSelect(d.date),
                    )),
              ];
              const gap = 6.0;
              final width = (constraints.maxWidth - gap * 6) / 7;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  for (final cell in cells)
                    SizedBox(
                      width: width,
                      height: 62,
                      child: cell ?? const SizedBox.shrink(),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          const Wrap(
            spacing: 14,
            runSpacing: 6,
            children: <Widget>[
              _Legend(color: T.blue, label: 'Scheduled'),
              _Legend(color: T.green, label: 'Done'),
              _Legend(color: T.red, label: 'Missed'),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Showing ${window.days} days',
              style: AppText.meta,
            ),
          ),
        ],
      ),
    );
  }

  static String _rangeLabel(InspectionCalendar calendar) {
    final from = Dates.monthLabel(calendar.fromDate);
    final to = Dates.monthLabel(calendar.toDate);
    return from == to ? from : '$from — $to';
  }
}

class _WeekdayStrip extends StatelessWidget {
  const _WeekdayStrip();

  @override
  Widget build(BuildContext context) {
    const labels = <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 6.0;
        final width = (constraints.maxWidth - gap * 6) / 7;
        return Wrap(
          spacing: gap,
          children: <Widget>[
            for (final l in labels)
              SizedBox(
                width: width,
                child: Center(
                  child: Text(
                    l,
                    style: AppText.sans(
                      size: 11.5,
                      weight: FontWeight.w700,
                      color: T.muted,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isToday,
    required this.isSelected,
    required this.onTap,
  });

  final CalendarDay day;
  final bool isToday;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final missed = day.countOf(SlotStatus.missed);
    final done = day.countOf(SlotStatus.done);
    final scheduled = day.countOf(SlotStatus.scheduled);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: T.cardSmShape,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? T.greenTint
                : (day.isEmpty ? T.subtleFill : T.card),
            borderRadius: T.cardSmShape,
            border: Border.all(
              color: isSelected
                  ? T.green
                  : (isToday ? T.ink : T.border),
              width: isSelected || isToday ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    Dates.dayOfMonth(day.date),
                    style: AppText.mono(
                      size: 12.5,
                      weight: isToday ? FontWeight.w700 : FontWeight.w600,
                      color: day.isEmpty ? T.muted : T.ink,
                    ),
                  ),
                  const Spacer(),
                  // A docking takes a bus off the road for a major service, so
                  // it is worth seeing without opening the day. The status
                  // dots below cannot say it — they count, they do not name.
                  if (day.hasDocking)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: T.amberTint,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        'PM',
                        style: AppText.mono(
                          size: 8.5,
                          weight: FontWeight.w700,
                          color: T.amber,
                        ),
                      ),
                    ),
                ],
              ),
              const Spacer(),
              if (!day.isEmpty)
                Row(
                  children: <Widget>[
                    if (scheduled > 0) _Dot(count: scheduled, color: T.blue),
                    if (done > 0) _Dot(count: done, color: T.green),
                    if (missed > 0) _Dot(count: missed, color: T.red),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A count rendered as a weighted bar rather than a number: at 57 buses a
/// night the exact figure is noise, the shape of the week is the signal.
class _Dot extends StatelessWidget {
  const _Dot({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 3),
      child: Container(
        height: 4,
        width: (count.clamp(1, 12)) * 1.6 + 3,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          height: 4,
          width: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: AppText.meta),
      ],
    );
  }
}

class _PageButton extends StatelessWidget {
  const _PageButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 20, color: T.body),
        splashRadius: 20,
      ),
    );
  }
}

/// One night, opened. Grouped by inspection type because that is how the work
/// is actually allocated on the floor.
class _DayAgenda extends ConsumerWidget {
  const _DayAgenda({required this.day});

  final CalendarDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(sessionProvider).can('em_schedule:write');
    final groups = day.byWorkType;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      Dates.relativeLabel(day.date),
                      style: AppText.sectionTitle,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${day.count} booked · ${Dates.dayLabel(day.date)}',
                      style: AppText.meta,
                    ),
                  ],
                ),
              ),
              if (canEdit)
                OutlineActionButton(
                  label: 'Add',
                  onPressed: () => showSlotCreator(context, ref, day.date),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (day.isEmpty)
            const EmptyState(message: 'Nothing booked for this day.')
          else
            for (final entry in groups.entries) ...<Widget>[
              _GroupHeading(
                code: entry.key,
                name: entry.value.first.workTypeName,
                count: entry.value.length,
              ),
              const SizedBox(height: 8),
              for (final slot in entry.value)
                _SlotRow(slot: slot, canEdit: canEdit),
              const SizedBox(height: 14),
            ],
        ],
      ),
    );
  }
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({
    required this.code,
    required this.name,
    required this.count,
  });

  final String code;
  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        TagBadge(label: code, background: T.indigoTint, foreground: T.indigo),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            name,
            style: AppText.sans(size: 13.5, weight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text('$count', style: AppText.meta),
      ],
    );
  }
}

class _SlotRow extends ConsumerWidget {
  const _SlotRow({required this.slot, required this.canEdit});

  final InspectionSlot slot;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (bg, fg) = switch (slot.status) {
      SlotStatus.done => (T.greenTint, T.greenInk),
      SlotStatus.missed => (T.redTint, T.redInk),
      SlotStatus.cancelled => (T.inactiveFill, T.muted),
      SlotStatus.scheduled => (T.subtleFill, T.body),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canEdit ? () => showSlotEditor(context, ref, slot) : null,
          borderRadius: T.cardSmShape,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: T.cardSmShape,
              border: Border.all(color: T.border),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        slot.registrationNo,
                        style: AppText.mono(size: 13.5),
                      ),
                      if (slot.notes.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(slot.notes, style: AppText.meta),
                      ],
                    ],
                  ),
                ),
                if (slot.isPinned)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: 'Moved by hand — the generator leaves it alone',
                      child: Icon(Icons.push_pin_outlined,
                          size: 14, color: T.muted),
                    ),
                  ),
                Text(
                  slot.status.label,
                  style: AppText.sans(
                    size: 12,
                    weight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                if (canEdit) ...<Widget>[
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right, size: 16, color: T.muted),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
