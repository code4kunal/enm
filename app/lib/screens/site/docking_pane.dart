import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/service_due.dart';
import '../../models/site.dart';
import '../../models/site_config.dart';
import '../../state/odometer_sync.dart';
import '../../state/providers.dart';
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
import '../../widgets/sub_tabs.dart';

/// The site's preventive-maintenance plan — the docking schedule.
///
/// Services fall due on whichever comes first, distance or elapsed time, the
/// way paid car servicing works. That makes the odometer the load-bearing
/// number, which is why its freshness is shown at the top rather than buried.
class DockingPane extends ConsumerWidget {
  const DockingPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(siteConfigProvider);
    final draft = ref.watch(siteConfigDraftProvider);
    final site = ref.watch(sessionProvider.select((s) => s.site));
    final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const <Vehicle>[];
    final controller = ref.read(siteConfigDraftProvider.notifier);

    return saved.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(child: CircularProgressIndicator(color: T.green)),
      ),
      error: (e, _) => EmptyState(message: '$e'),
      data: (config) {
        final editing = draft != null;
        final shown = draft ?? config;
        final due = ServiceSchedule.forSite(
          vehicles: vehicles,
          config: shown,
          now: DateTime.now(),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ScreenHeader(
              title: 'Docking schedule · $site',
              subtitle: editing
                  ? 'Unsaved changes.'
                  : 'Preventive-maintenance plans. A service falls due on '
                      'whichever comes first — distance or elapsed time.',
              action: editing
                  ? null
                  : FilledActionButton(
                      label: 'Edit configuration',
                      onPressed: () => controller.begin(config),
                      fontSize: 14,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 11,
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            const _OdometerBar(),
            const SizedBox(height: 16),
            _Summary(config: shown, due: due),
            const SizedBox(height: 16),
            if (shown.validationIssues.isNotEmpty) ...<Widget>[
              _Issues(issues: shown.validationIssues),
              const SizedBox(height: 16),
            ],
            _Plans(config: shown, editing: editing),
            const SizedBox(height: 16),
            if (!editing) ...<Widget>[
              _DueQueue(due: due),
              const SizedBox(height: 16),
            ],
            _Shifts(config: shown),
            const SizedBox(height: 16),
            _Parameters(config: shown, editing: editing),
            if (editing) ...<Widget>[
              const SizedBox(height: 20),
              _SaveBar(config: shown),
            ],
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

/// Odometer freshness and a manual pull. The scheduled sync runs on the site's
/// configured interval; this is the "I need it now" escape hatch.
class _OdometerBar extends ConsumerWidget {
  const _OdometerBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(odometerSyncProvider);
    final config = ref.watch(siteConfigProvider).valueOrNull;
    final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const <Vehicle>[];
    final stale = vehicles.where((v) => v.isActive && !v.hasOdometer).length;

    final lastSynced = sync.lastSyncedAt ?? config?.odometerSync.lastSyncedAt;

    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 12,
        children: <Widget>[
          TagBadge(
            label: sync.running ? 'SYNCING' : 'ODOMETERS',
            background: sync.running ? T.blueTint : T.subtleFill,
            foreground: sync.running ? T.blue : T.secondary,
            border: sync.running ? null : T.border,
          ),
          Text(
            lastSynced == null
                ? 'Never synced'
                : 'Last synced ${_shortStamp(lastSynced)}',
            style: AppText.sans(size: 13.5, color: T.secondary),
          ),
          if (config?.odometerSync.enabled ?? false)
            Text(
              'every ${config!.odometerSync.interval.inMinutes} min',
              style: AppText.mono(size: 13, color: T.muted),
            )
          else
            Text(
              'scheduled sync off',
              style: AppText.sans(size: 13, color: T.amber),
            ),
          if (stale > 0)
            TagBadge(
              label: '$stale WITHOUT A READING',
              background: T.amberTint,
              foreground: T.amber,
            ),
          if (sync.error != null)
            Text(
              sync.error!,
              style: AppText.sans(size: 13, color: T.redInk),
            ),
          OutlineActionButton(
            label: sync.running ? 'Syncing…' : 'Sync now',
            onPressed: sync.running
                ? null
                : ref.read(odometerSyncProvider.notifier).syncNow,
            accent: T.green,
            fontSize: 13,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          ),
        ],
      ),
    );
  }

  static String _shortStamp(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final h = parsed.hour.toString().padLeft(2, '0');
    final m = parsed.minute.toString().padLeft(2, '0');
    return '${Dates.iso(parsed)} $h:$m';
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.config, required this.due});

  final SiteConfig config;
  final List<ServiceDue> due;

  @override
  Widget build(BuildContext context) {
    final overdue = due.where((d) => d.status == DueStatus.overdue).length;
    final soon = due.where((d) => d.status == DueStatus.dueSoon).length;
    final unknown = due.where((d) => d.status == DueStatus.unknown).length;

    return Panel(
      child: Wrap(
        spacing: 32,
        runSpacing: 16,
        children: <Widget>[
          StatCell(
            label: 'Active plans',
            value: '${config.activePlans.length}',
          ),
          StatCell(
            label: 'Overdue',
            value: '$overdue',
            tone: overdue > 0 ? T.red : null,
          ),
          StatCell(
            label: 'Due soon',
            value: '$soon',
            tone: soon > 0 ? T.amber : null,
          ),
          if (unknown > 0)
            StatCell(label: 'No odometer', value: '$unknown', tone: T.muted),
          StatCell(
            label: 'Shortest interval',
            value: config.shortestIntervalKm == 0
                ? '—'
                : '${config.shortestIntervalKm} km',
          ),
          StatCell(
            label: 'Bay slot',
            value: '${config.dockingSlotMinutes} min',
          ),
          StatCell(
            label: 'Services / bay / day',
            value: config.servicesPerBayPerDay.toStringAsFixed(1),
          ),
        ],
      ),
    );
  }
}

class _Issues extends StatelessWidget {
  const _Issues({required this.issues});

  final List<String> issues;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: T.redTint,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.redBorderTint),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            issues.length == 1 ? 'One problem' : '${issues.length} problems',
            style: AppText.sans(
              size: 14,
              weight: FontWeight.w700,
              color: T.redInkDeep,
            ),
          ),
          const SizedBox(height: 6),
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '· $issue',
                style:
                    AppText.sans(size: 13.5, color: T.redInkDeep, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }
}

class _Plans extends ConsumerWidget {
  const _Plans({required this.config, required this.editing});

  final SiteConfig config;
  final bool editing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(siteConfigDraftProvider.notifier);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('Service plans', style: AppText.sectionTitle),
              ),
              if (editing)
                OutlineActionButton(
                  label: '+ Add plan',
                  onPressed: () => controller.update(
                    (c) => c.copyWith(
                      servicePlans: <ServicePlan>[
                        ...c.servicePlans,
                        ServicePlan(
                          code: 'S${c.servicePlans.length + 1}',
                          name: 'New service',
                          intervalKm: 10000,
                          intervalDays: 90,
                        ),
                      ],
                    ),
                  ),
                  accent: T.green,
                  fontSize: 13,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (config.servicePlans.isEmpty)
            const EmptyState(
              message: 'No service plans yet. Add them here, or import the '
                  "site's schedule from the Import tab.",
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < config.servicePlans.length; i++) ...<Widget>[
                  _PlanRow(
                    plan: config.servicePlans[i],
                    editing: editing,
                    onChanged: (plan) => controller.update((c) {
                      final next = List<ServicePlan>.of(c.servicePlans);
                      next[i] = plan;
                      return c.copyWith(servicePlans: next);
                    }),
                    onRemove: () => controller.update((c) {
                      final next = List<ServicePlan>.of(c.servicePlans)
                        ..removeAt(i);
                      return c.copyWith(servicePlans: next);
                    }),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.plan,
    required this.editing,
    required this.onChanged,
    required this.onRemove,
  });

  final ServicePlan plan;
  final bool editing;
  final ValueChanged<ServicePlan> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: plan.isActive ? 1 : 0.6,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: T.subtleFill,
          borderRadius: T.controlShape,
          border: Border.all(color: T.border),
        ),
        child: Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 56,
              child: Text(
                plan.code,
                style: AppText.mono(size: 15, weight: FontWeight.w700),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    plan.name,
                    style: AppText.sans(size: 14.5, weight: FontWeight.w600),
                  ),
                  if (plan.notes.isNotEmpty)
                    Text(
                      plan.notes,
                      style: AppText.sans(size: 12.5, color: T.muted),
                    ),
                ],
              ),
            ),
            TagBadge(
              label: plan.intervalLabel,
              background: T.greenTint,
              foreground: T.greenInk,
              mono: true,
            ),
            if (!plan.isActive)
              const TagBadge(
                label: 'PAUSED',
                background: T.inactiveFill,
                foreground: T.muted,
              ),
            if (editing) ...<Widget>[
              OutlineActionButton(
                label: plan.isActive ? 'Pause' : 'Resume',
                onPressed: () => onChanged(plan.copyWith(isActive: !plan.isActive)),
                fontSize: 12,
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              ),
              OutlineActionButton(
                label: 'Remove',
                onPressed: onRemove,
                foreground: T.redInk,
                borderColor: T.redBorderTint,
                fontSize: 12,
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The work queue: which vehicle needs which service, worst first.
class _DueQueue extends ConsumerWidget {
  const _DueQueue({required this.due});

  final List<ServiceDue> due;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final attention = due.where((d) => d.needsAttention).toList();
    final shown = attention.isEmpty ? due.take(8).toList() : attention;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            attention.isEmpty ? 'Next services' : 'Needs attention',
            style: AppText.sectionTitle,
          ),
          const SizedBox(height: 4),
          Text(
            attention.isEmpty
                ? 'Nothing is due yet — the soonest are listed first.'
                : '${attention.length} of ${due.length} vehicle-services are '
                    'due or overdue.',
            style: AppText.sans(size: 13.5, color: T.secondary),
          ),
          const SizedBox(height: 12),
          if (shown.isEmpty)
            const EmptyState(
              message: 'No active vehicles or no service plans to apply.',
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final d in shown) ...<Widget>[
                  _DueRow(due: d),
                  const SizedBox(height: 8),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _DueRow extends ConsumerWidget {
  const _DueRow({required this.due});

  final ServiceDue due;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tone = switch (due.status) {
      DueStatus.overdue => (bg: T.redTint, fg: T.redInk, border: T.redBorderTint),
      DueStatus.dueSoon => (bg: T.amberTint, fg: T.amber, border: T.amber),
      DueStatus.unknown => (bg: T.inactiveFill, fg: T.muted, border: T.border),
      DueStatus.ok => (bg: T.greenTint, fg: T.greenInk, border: T.border),
    };

    Future<void> markServiced() async {
      try {
        await ref.read(vehiclesProvider.notifier).markServiced(
              vehicleId: due.vehicle.id,
              planCode: due.plan.code,
              odometerKm: due.vehicle.odometerKm,
            );
        if (!context.mounted) return;
        ref.read(toastProvider.notifier).show(
              '${due.plan.name} recorded for ${due.vehicle.registrationNo}',
            );
      } on ApiException catch (e) {
        ref.read(toastProvider.notifier).show(e.message);
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: T.controlShape,
        border: Border.all(color: tone.border),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 128,
            child: Text(
              due.vehicle.registrationNo,
              style: AppText.mono(size: 14.5, weight: FontWeight.w600),
            ),
          ),
          TagBadge(
            label: due.status.label,
            background: tone.bg,
            foreground: tone.fg,
          ),
          Text(
            '${due.plan.code} · ${due.plan.name}',
            style: AppText.sans(size: 13.5, color: T.body),
          ),
          Text(
            due.summary,
            style: AppText.mono(size: 13, color: T.secondary),
          ),
          Text(
            'odo ${due.vehicle.odometerKm} km',
            style: AppText.mono(size: 12.5, color: T.muted),
          ),
          if (due.needsAttention)
            OutlineActionButton(
              label: 'Mark serviced',
              onPressed: markServiced,
              accent: T.green,
              fontSize: 12.5,
              padding:
                  const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            ),
        ],
      ),
    );
  }
}

class _Shifts extends StatelessWidget {
  const _Shifts({required this.config});

  final SiteConfig config;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Shift windows', style: AppText.sectionTitle),
          const SizedBox(height: 4),
          Text(
            'Site local time. The entry form auto-picks the shift from these.',
            style: AppText.sans(size: 13.5, color: T.secondary),
          ),
          const SizedBox(height: 14),
          if (config.shifts.isEmpty)
            const EmptyState(message: 'No shift windows configured.')
          else
            Wrap(
              spacing: 28,
              runSpacing: 14,
              children: <Widget>[
                for (final s in config.shifts)
                  StatCell(
                    label: 'Shift ${s.shift}'
                        '${s.wrapsMidnight ? ' (overnight)' : ''}',
                    value: '${s.start} – ${s.end}',
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Parameters extends ConsumerWidget {
  const _Parameters({required this.config, required this.editing});

  final SiteConfig config;
  final bool editing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(siteConfigDraftProvider.notifier);

    final rows = <({
      String label,
      String unit,
      int value,
      SiteConfig Function(SiteConfig, int) set
    })>[
      (
        label: 'Reminder lead',
        unit: 'km',
        value: config.reminderLeadKm,
        set: (c, v) => c.copyWith(reminderLeadKm: v)
      ),
      (
        label: 'Reminder lead',
        unit: 'days',
        value: config.reminderLeadDays,
        set: (c, v) => c.copyWith(reminderLeadDays: v)
      ),
      (
        label: 'Bay slot',
        unit: 'min',
        value: config.dockingSlotMinutes,
        set: (c, v) => c.copyWith(dockingSlotMinutes: v)
      ),
      (
        label: 'Max vehicles in service',
        unit: 'count',
        value: config.maxVehiclesInService,
        set: (c, v) => c.copyWith(maxVehiclesInService: v)
      ),
      (
        label: 'Odometer sync',
        unit: 'min',
        value: config.odometerSync.intervalMinutes,
        set: (c, v) =>
            c.copyWith(odometerSync: c.odometerSync.copyWith(intervalMinutes: v))
      ),
    ];

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Parameters', style: AppText.sectionTitle),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final gap = constraints.maxWidth * 0.04;
              final columns = constraints.maxWidth < 520 ? 1 : 3;
              final width =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: 14,
                children: <Widget>[
                  for (final row in rows)
                    SizedBox(
                      width: width,
                      child: editing
                          ? _NumberField(
                              label: '${row.label} (${row.unit})',
                              value: row.value,
                              onChanged: (v) =>
                                  controller.update((c) => row.set(c, v)),
                            )
                          : StatCell(
                              label: '${row.label} (${row.unit})',
                              value: '${row.value}',
                            ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Integer field that keeps its own controller so typing does not fight the
/// draft's rebuilds.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller =
      TextEditingController(text: '${widget.value}');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FieldLabel(label: widget.label),
        AppTextField(
          controller: _controller,
          mono: true,
          numeric: true,
          onChanged: (v) => widget.onChanged(int.tryParse(v) ?? 0),
        ),
      ],
    );
  }
}

class _SaveBar extends ConsumerStatefulWidget {
  const _SaveBar({required this.config});

  final SiteConfig config;

  @override
  ConsumerState<_SaveBar> createState() => _SaveBarState();
}

class _SaveBarState extends ConsumerState<_SaveBar> {
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(siteConfigDraftProvider.notifier).save();
      if (!mounted) return;
      ref.read(toastProvider.notifier).show('Docking schedule saved');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = !widget.config.isValid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_error != null) InlineError(message: _error!),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            OutlineActionButton(
              label: 'Discard',
              onPressed: _saving
                  ? null
                  : ref.read(siteConfigDraftProvider.notifier).discard,
              fontSize: 15,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledActionButton(
                label: _saving
                    ? 'Saving…'
                    : blocked
                        ? 'Fix the problems above'
                        : 'Save schedule',
                onPressed: (_saving || blocked) ? null : _save,
                fontSize: 15.5,
                elevated: !blocked,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
