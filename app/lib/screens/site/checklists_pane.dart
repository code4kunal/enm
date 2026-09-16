import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/docking_km.dart';
import '../../models/checklist.dart';
import '../../state/inspections.dart';
import '../../state/session.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sub_tabs.dart';

export '../../data/docking_km.dart';

/// Site master: the checklist behind each inspection.
///
/// A daily inspection and a ten-day service are different jobs, so each carries
/// its own list. Docking (P.M) further splits by bus type × KM range — that
/// editor is one card with dropdowns, not one card per rung.
class ChecklistsPane extends ConsumerWidget {
  const ChecklistsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(checklistsProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => EmptyState(message: e.toString()),
      data: (checklists) {
        if (checklists.isEmpty) {
          return const EmptyState(
            message: 'No inspection types yet. Add one under master data — a '
                'work type marked as an inspection gets a checklist here.',
          );
        }

        final byWorkType = <int, List<Checklist>>{};
        for (final c in checklists) {
          byWorkType.putIfAbsent(c.workTypeId, () => <Checklist>[]).add(c);
        }
        final groups = byWorkType.values.toList()
          ..sort(
            (a, b) => a.first.workTypeCode.compareTo(b.first.workTypeCode),
          );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Each inspection runs its own checklist. Docking sheets are per '
              'bus type and KM range.',
              style: AppText.meta,
            ),
            const SizedBox(height: 16),
            for (final group in groups) ...<Widget>[
              if (group.any((c) => c.isDocking))
                _DockingChecklistEditor(templates: group)
              else
                for (final c in group.where(
                  (t) => t.variant != null || group.length == 1,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ChecklistEditor(checklist: c),
                  ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}

/// Docking (P.M): Bus Type + KM range pickers switch which sheet is edited.
class _DockingChecklistEditor extends ConsumerStatefulWidget {
  const _DockingChecklistEditor({required this.templates});

  final List<Checklist> templates;

  @override
  ConsumerState<_DockingChecklistEditor> createState() =>
      _DockingChecklistEditorState();
}

class _DockingChecklistEditorState
    extends ConsumerState<_DockingChecklistEditor> {
  late String _busType;
  late int _milestoneKm;
  List<_Draft> _drafts = <_Draft>[];
  bool _open = false;
  bool _saving = false;
  Checklist? _loaded;

  @override
  void initState() {
    super.initState();
    final seeded = widget.templates
        .where((t) => t.variant != null && t.milestoneKm != null)
        .toList();
    _busType = seeded.isNotEmpty
        ? seeded.first.variant!
        : kDockingBusTypes.first;
    _milestoneKm = seeded.isNotEmpty
        ? seeded.first.milestoneKm!
        : kDockingMilestoneKm.first;
    _loadSelection();
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  Checklist get _shell => widget.templates.first;

  Checklist? _find(String busType, int km) {
    for (final t in widget.templates) {
      if (t.variant == busType && t.milestoneKm == km) return t;
    }
    return null;
  }

  void _loadSelection() {
    final found = _find(_busType, _milestoneKm);
    _loaded = found;
    for (final d in _drafts) {
      d.dispose();
    }
    _drafts = (found?.items ?? const <ChecklistItem>[])
        .map(_Draft.from)
        .toList();
  }

  bool get _dirty {
    final original = _loaded?.items ?? const <ChecklistItem>[];
    if (original.length != _drafts.length) return true;
    for (var i = 0; i < original.length; i++) {
      if (!_drafts[i].matches(original[i])) return true;
    }
    return false;
  }

  Future<void> _switchTo({String? busType, int? km}) async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard changes?'),
          content: const Text(
            'Switching bus type or KM range drops unsaved edits on this sheet.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    setState(() {
      if (busType != null) _busType = busType;
      if (km != null) _milestoneKm = km;
      _loadSelection();
    });
  }

  Future<void> _save() async {
    final items = <ChecklistItem>[];
    for (final d in _drafts) {
      final label = d.label.text.trim();
      if (label.isEmpty) continue;
      items.add(
        ChecklistItem(
          id: d.id,
          section: d.section.text.trim(),
          label: label,
          responseType: d.responseType,
          isRequired: d.isRequired,
        ),
      );
    }

    final base = _loaded ??
        Checklist(
          siteCode: _shell.siteCode,
          workTypeId: _shell.workTypeId,
          workTypeCode: _shell.workTypeCode,
          workTypeName: _shell.workTypeName,
          name: 'Docking — $_busType @ ${formatDockingKm(_milestoneKm)}',
          variant: _busType,
          milestoneKm: _milestoneKm,
        );

    setState(() => _saving = true);
    try {
      await ref.read(inspectionControllerProvider).saveChecklist(
            base.copyWith(
              name: 'Docking — $_busType @ ${formatDockingKm(_milestoneKm)}',
              variant: _busType,
              milestoneKm: _milestoneKm,
              items: items,
            ),
          );
      ref.read(toastProvider.notifier).show(
            '$_busType · ${formatDockingKm(_milestoneKm)} saved · '
            '${items.length} checks',
          );
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(sessionProvider).can('em_site_config:write');
    final busOptions = <String>{
      ...kDockingBusTypes,
      for (final t in widget.templates)
        if (t.variant != null && t.variant!.isNotEmpty) t.variant!,
    }.toList()
      ..sort();
    final kmOptions = <int>{
      ...kDockingMilestoneKm,
      for (final t in widget.templates)
        if (t.milestoneKm != null) t.milestoneKm!,
    }.toList()
      ..sort();

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              TagBadge(
                label: _shell.workTypeCode,
                background: T.indigoTint,
                foreground: T.indigo,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_shell.workTypeName, style: AppText.cardTitle),
                    const SizedBox(height: 2),
                    Text(
                      'Docking · pick bus type and KM range',
                      style: AppText.sans(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: T.muted,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _open = !_open),
                child: Text(
                  _open ? 'Close' : (canEdit ? 'Edit' : 'View'),
                  style: AppText.sans(
                    size: 13,
                    weight: FontWeight.w700,
                    color: T.green,
                  ),
                ),
              ),
            ],
          ),
          if (_open) ...<Widget>[
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'Bus Type'),
                      const SizedBox(height: 6),
                      AppSelect(
                        value: _busType,
                        options: busOptions,
                        onChanged: (v) {
                          if (v != null) _switchTo(busType: v);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const FieldLabel(label: 'KM range'),
                      const SizedBox(height: 6),
                      AppSelect(
                        value: formatDockingKm(_milestoneKm),
                        options: [
                          for (final km in kmOptions) formatDockingKm(km),
                        ],
                        onChanged: (label) {
                          if (label == null) return;
                          final km = kmOptions.firstWhere(
                            (k) => formatDockingKm(k) == label,
                            orElse: () => _milestoneKm,
                          );
                          _switchTo(km: km);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _drafts.isEmpty
                  ? 'No checks for $_busType @ ${formatDockingKm(_milestoneKm)} yet.'
                  : '${_drafts.length} checks',
              style: AppText.sans(
                size: 12.5,
                weight: FontWeight.w600,
                color: _drafts.isEmpty ? T.amber : T.green,
              ),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _drafts.length; i++) _row(i, canEdit),
            const SizedBox(height: 12),
            if (canEdit)
              Row(
                children: <Widget>[
                  OutlineActionButton(
                    label: 'Add a check',
                    fontSize: 14,
                    onPressed: () => setState(() => _drafts.add(_Draft.blank())),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledActionButton(
                      label: _saving ? 'Saving…' : 'Save checklist',
                      fontSize: 14,
                      expand: true,
                      onPressed: _saving || !_dirty ? null : _save,
                    ),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(int index, bool canEdit) {
    final draft = _drafts[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 130,
                child: AppTextField(
                  controller: draft.section,
                  placeholder: 'Section',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppTextField(
                  controller: draft.label,
                  placeholder: 'What is checked',
                ),
              ),
              if (canEdit)
                IconButton(
                  tooltip: 'Remove',
                  onPressed: () => setState(() {
                    _drafts.removeAt(index).dispose();
                  }),
                  icon: const Icon(Icons.close, size: 18, color: T.muted),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final type in ResponseType.values)
                PillChip(
                  label: type.label,
                  selected: draft.responseType == type,
                  dense: true,
                  fontSize: 11.5,
                  tone: ChipTone.green,
                  onTap: () => setState(() => draft.responseType = type),
                ),
              PillChip(
                label: draft.isRequired ? 'Required' : 'Optional',
                selected: draft.isRequired,
                dense: true,
                fontSize: 11.5,
                onTap: () =>
                    setState(() => draft.isRequired = !draft.isRequired),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChecklistEditor extends ConsumerStatefulWidget {
  const _ChecklistEditor({required this.checklist});

  final Checklist checklist;

  @override
  ConsumerState<_ChecklistEditor> createState() => _ChecklistEditorState();
}

class _ChecklistEditorState extends ConsumerState<_ChecklistEditor> {
  late final List<_Draft> _drafts = widget.checklist.items
      .map((i) => _Draft.from(i))
      .toList();
  bool _open = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  bool get _dirty {
    final original = widget.checklist.items;
    if (original.length != _drafts.length) return true;
    for (var i = 0; i < original.length; i++) {
      if (!_drafts[i].matches(original[i])) return true;
    }
    return false;
  }

  Future<void> _save() async {
    final items = <ChecklistItem>[];
    for (final d in _drafts) {
      final label = d.label.text.trim();
      if (label.isEmpty) continue;
      items.add(
        ChecklistItem(
          id: d.id,
          section: d.section.text.trim(),
          label: label,
          responseType: d.responseType,
          isRequired: d.isRequired,
        ),
      );
    }

    setState(() => _saving = true);
    try {
      await ref.read(inspectionControllerProvider).saveChecklist(
            widget.checklist.copyWith(
              items: items,
              variant: widget.checklist.variant,
            ),
          );
      ref.read(toastProvider.notifier).show(
            '${widget.checklist.workTypeCode}'
            '${widget.checklist.variant == null ? '' : ' · ${widget.checklist.variant}'}'
            ' checklist saved · ${items.length} checks',
          );
    } on Object catch (e) {
      ref.read(toastProvider.notifier).show(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(sessionProvider).can('em_site_config:write');
    final variantLabel = widget.checklist.variant;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              TagBadge(
                label: widget.checklist.workTypeCode,
                background: T.indigoTint,
                foreground: T.indigo,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.checklist.workTypeName +
                          (variantLabel == null || variantLabel.isEmpty
                              ? ''
                              : ' · $variantLabel'),
                      style: AppText.cardTitle,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _drafts.isEmpty
                          ? 'No checks yet'
                          : '${_drafts.length} checks',
                      style: AppText.sans(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: _drafts.isEmpty ? T.amber : T.green,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _open = !_open),
                child: Text(
                  _open ? 'Close' : (canEdit ? 'Edit' : 'View'),
                  style: AppText.sans(
                    size: 13,
                    weight: FontWeight.w700,
                    color: T.green,
                  ),
                ),
              ),
            ],
          ),
          if (_open) ...<Widget>[
            const SizedBox(height: 16),
            if (_drafts.isEmpty)
              Text(
                'Type the checks the depot actually runs, or paste them one '
                'per line from the checklist document.',
                style: AppText.bodyText,
              ),
            for (var i = 0; i < _drafts.length; i++) _row(i, canEdit),
            const SizedBox(height: 12),
            if (canEdit)
              Row(
                children: <Widget>[
                  OutlineActionButton(
                    label: 'Add a check',
                    fontSize: 14,
                    onPressed: () => setState(() => _drafts.add(_Draft.blank())),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledActionButton(
                      label: _saving ? 'Saving…' : 'Save checklist',
                      fontSize: 14,
                      expand: true,
                      onPressed: _saving || !_dirty ? null : _save,
                    ),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(int index, bool canEdit) {
    final draft = _drafts[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 130,
                child: AppTextField(
                  controller: draft.section,
                  placeholder: 'Section',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AppTextField(
                  controller: draft.label,
                  placeholder: 'What is checked',
                ),
              ),
              if (canEdit)
                IconButton(
                  tooltip: 'Remove',
                  onPressed: () => setState(() {
                    _drafts.removeAt(index).dispose();
                  }),
                  icon: const Icon(Icons.close, size: 18, color: T.muted),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final type in ResponseType.values)
                PillChip(
                  label: type.label,
                  selected: draft.responseType == type,
                  dense: true,
                  fontSize: 11.5,
                  tone: ChipTone.green,
                  onTap: () => setState(() => draft.responseType = type),
                ),
              PillChip(
                label: draft.isRequired ? 'Required' : 'Optional',
                selected: draft.isRequired,
                dense: true,
                fontSize: 11.5,
                onTap: () =>
                    setState(() => draft.isRequired = !draft.isRequired),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Draft {
  _Draft({
    required this.id,
    required String section,
    required String label,
    required this.responseType,
    required this.isRequired,
  })  : section = TextEditingController(text: section),
        label = TextEditingController(text: label);

  factory _Draft.from(ChecklistItem item) => _Draft(
        id: item.id,
        section: item.section,
        label: item.label,
        responseType: item.responseType,
        isRequired: item.isRequired,
      );

  factory _Draft.blank() => _Draft(
        id: '',
        section: '',
        label: '',
        responseType: ResponseType.okNotOk,
        isRequired: true,
      );

  final String id;
  final TextEditingController section;
  final TextEditingController label;
  ResponseType responseType;
  bool isRequired;

  bool matches(ChecklistItem item) =>
      section.text.trim() == item.section &&
      label.text.trim() == item.label &&
      responseType == item.responseType &&
      isRequired == item.isRequired;

  void dispose() {
    section.dispose();
    label.dispose();
  }
}
