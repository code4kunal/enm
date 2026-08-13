import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/site_import.dart';
import '../../state/imports.dart';
import '../../state/session.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sub_tabs.dart';

/// Per-site spreadsheet ingestion.
///
/// Import formats vary site to site, so a *profile* stores one site's mapping
/// from its own sheet to a fixed target. The flow is profile → file → mapping →
/// preview → commit, and nothing is written until the last step.
class ImportPane extends ConsumerWidget {
  const ImportPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(importControllerProvider);
    final site = ref.watch(sessionProvider.select((s) => s.site));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ScreenHeader(
          title: 'Import data · $site',
          subtitle: 'Map this site\'s spreadsheet onto the register and master '
              'data it belongs in. Mappings are saved and replayable.',
          action: session.stage == ImportStage.profile
              ? null
              : OutlineActionButton(
                  label: 'Start over',
                  onPressed:
                      ref.read(importControllerProvider.notifier).reset,
                  fontSize: 13,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                ),
        ),
        const SizedBox(height: 16),
        _Steps(stage: session.stage),
        const SizedBox(height: 16),
        if (session.error != null) ...<Widget>[
          _ErrorPanel(message: session.error!),
          const SizedBox(height: 16),
        ],
        switch (session.stage) {
          ImportStage.profile => const _ProfileStep(),
          ImportStage.mapping => const _MappingStep(),
          ImportStage.preview => const _PreviewStep(),
          ImportStage.done => const _DoneStep(),
        },
        const SizedBox(height: 16),
        const _RunHistory(),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.stage});

  final ImportStage stage;

  @override
  Widget build(BuildContext context) {
    const labels = <String>['Profile', 'Map columns', 'Preview', 'Done'];
    final index = ImportStage.values.indexOf(stage);

    return Row(
      children: <Widget>[
        for (var i = 0; i < labels.length; i++) ...<Widget>[
          if (i > 0)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: i <= index ? T.green : T.border,
              ),
            ),
          _StepDot(label: labels[i], index: i, current: index),
        ],
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.label,
    required this.index,
    required this.current,
  });

  final String label;
  final int index;
  final int current;

  @override
  Widget build(BuildContext context) {
    final done = index < current;
    final active = index == current;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done || active ? T.green : T.card,
            shape: BoxShape.circle,
            border: Border.all(
              color: done || active ? T.green : T.inputBorder,
              width: 1.5,
            ),
          ),
          child: Text(
            done ? '✓' : '${index + 1}',
            style: AppText.sans(
              size: 12,
              weight: FontWeight.w700,
              color: done || active ? T.white : T.muted,
            ),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          label,
          style: AppText.sans(
            size: 13,
            weight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? T.ink : T.muted,
          ),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: T.redTint,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.redBorderTint),
      ),
      child: Text(
        message,
        style: AppText.sans(
          size: 14,
          weight: FontWeight.w600,
          color: T.redInkDeep,
          height: 1.4,
        ),
      ),
    );
  }
}

// ─── Step 1: pick or create a profile ─────────────────────────────────────

class _ProfileStep extends ConsumerStatefulWidget {
  const _ProfileStep();

  @override
  ConsumerState<_ProfileStep> createState() => _ProfileStepState();
}

class _ProfileStepState extends ConsumerState<_ProfileStep> {
  final _nameController = TextEditingController();
  ImportTarget _target = ImportTarget.vehicles;
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickFile(ImportProfile profile) async {
    final controller = ref.read(importControllerProvider.notifier);
    controller.chooseProfile(profile);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['csv', 'xlsx', 'xls'],
      // The web picker only hands back bytes when asked.
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      ref.read(toastProvider.notifier).show('Could not read that file');
      return;
    }
    await controller.attachFile(file.name, bytes);
  }

  @override
  Widget build(BuildContext context) {
    final profiles =
        ref.watch(importProfilesProvider).valueOrNull ?? const <ImportProfile>[];
    final controller = ref.read(importControllerProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (profiles.isNotEmpty) ...<Widget>[
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Saved profiles', style: AppText.sectionTitle),
                const SizedBox(height: 4),
                Text(
                  'Reuse a mapping you have already configured for this site.',
                  style: AppText.sans(size: 13.5, color: T.secondary),
                ),
                const SizedBox(height: 14),
                for (final p in profiles) ...<Widget>[
                  _ProfileRow(
                    profile: p,
                    onUse: () => _pickFile(p),
                    onDelete: () => controller.deleteProfile(p.id),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Panel(
          accent: _creating,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('New import', style: AppText.sectionTitle),
                  ),
                  if (!_creating)
                    FilledActionButton(
                      label: '+ New profile',
                      onPressed: () => setState(() => _creating = true),
                      fontSize: 14,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                ],
              ),
              if (_creating) ...<Widget>[
                const SizedBox(height: 16),
                const FieldLabel(label: 'What are you importing?', required: true),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final t in ImportTarget.values)
                      PillChip(
                        label: t.label,
                        selected: _target == t,
                        tone: ChipTone.green,
                        onTap: () => setState(() => _target = t),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _target.description,
                  style: AppText.sans(size: 13, color: T.muted),
                ),
                const SizedBox(height: 16),
                const FieldLabel(label: 'Profile name', required: true),
                AppTextField(
                  controller: _nameController,
                  placeholder: 'e.g. MBMT monthly coolant register',
                ),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    OutlineActionButton(
                      label: 'Cancel',
                      onPressed: () => setState(() => _creating = false),
                      fontSize: 15,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 13,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledActionButton(
                        label: 'Choose file…',
                        onPressed: () {
                          final name = _nameController.text.trim();
                          if (name.isEmpty) {
                            ref
                                .read(toastProvider.notifier)
                                .show('Give the profile a name');
                            return;
                          }
                          _pickFile(controller.newProfile(_target, name));
                        },
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
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.onUse,
    required this.onDelete,
  });

  final ImportProfile profile;
  final VoidCallback onUse;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: T.subtleFill,
        borderRadius: T.controlShape,
        border: Border.all(color: T.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  profile.name,
                  style: AppText.sans(size: 15, weight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    TagBadge(
                      label: profile.target.label,
                      background: T.blueTint,
                      foreground: T.blue,
                    ),
                    Text(
                      profile.lastRunAt == null
                          ? 'Never run'
                          : 'Last run ${profile.lastRunAt}',
                      style: AppText.sans(size: 12.5, color: T.muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          OutlineActionButton(
            label: 'Use',
            onPressed: onUse,
            accent: T.green,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          ),
          const SizedBox(width: 8),
          OutlineActionButton(
            label: 'Delete',
            onPressed: onDelete,
            foreground: T.redInk,
            borderColor: T.redBorderTint,
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          ),
        ],
      ),
    );
  }
}

// ─── Step 2: bind source columns to target fields ─────────────────────────

class _MappingStep extends ConsumerWidget {
  const _MappingStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(importControllerProvider);
    final controller = ref.read(importControllerProvider.notifier);
    final profile = session.profile;
    final inspection = session.inspection;
    if (profile == null || inspection == null) return const SizedBox.shrink();

    final fields = session.targetFields;
    final missing = profile.missingRequired(fields);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: <Widget>[
                  StatCell(
                    label: 'File',
                    value: inspection.fileName,
                    mono: false,
                  ),
                  StatCell(label: 'Rows', value: '${inspection.totalRows}'),
                  StatCell(
                    label: 'Columns',
                    value: '${inspection.columns.length}',
                  ),
                  StatCell(
                    label: 'Target',
                    value: profile.target.label,
                    mono: false,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Map columns', style: AppText.sectionTitle),
              const SizedBox(height: 4),
              Text(
                'Columns whose names matched were bound automatically — check '
                'them. Required fields are marked.',
                style: AppText.sans(size: 13.5, color: T.secondary),
              ),
              const SizedBox(height: 16),
              for (final field in fields) ...<Widget>[
                _MappingRow(
                  field: field,
                  mapping: profile.mappingFor(field.key),
                  columns: inspection.columns,
                  sample: inspection.sampleRows,
                  onBind: (col) => controller.bind(field.key, col),
                  onConstant: (v) => controller.bindConstant(field.key, v),
                ),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (missing.isNotEmpty)
          _ErrorPanel(
            message: 'Still unmapped: '
                '${missing.map((f) => f.label).join(', ')}',
          ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            OutlineActionButton(
              label: 'Save profile',
              onPressed: session.busy ? null : controller.saveProfile,
              fontSize: 15,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledActionButton(
                label: session.busy ? 'Checking…' : 'Preview import',
                onPressed: (session.busy || missing.isNotEmpty)
                    ? null
                    : controller.runPreview,
                fontSize: 15.5,
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

class _MappingRow extends StatelessWidget {
  const _MappingRow({
    required this.field,
    required this.mapping,
    required this.columns,
    required this.sample,
    required this.onBind,
    required this.onConstant,
  });

  final TargetField field;
  final ColumnMapping? mapping;
  final List<String> columns;
  final List<Map<String, String>> sample;
  final ValueChanged<String?> onBind;
  final ValueChanged<String> onConstant;

  @override
  Widget build(BuildContext context) {
    final bound = mapping?.sourceColumn ?? '';
    // Show what the first data row actually holds, so a wrong binding is
    // obvious before the preview runs.
    final example = bound.isEmpty || sample.isEmpty
        ? null
        : sample.first[bound];

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;
        final selector = AppSelect(
          value: bound,
          options: columns,
          placeholder: mapping?.isConstant ?? false
              ? 'Fixed: ${mapping!.constantValue}'
              : 'Not mapped',
          onChanged: onBind,
        );

        final label = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FieldLabel(label: field.label, required: field.required),
            if (field.hint != null)
              Text(
                field.hint!,
                style: AppText.sans(size: 12, color: T.muted, height: 1.35),
              ),
            if (example != null && example.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'e.g. "$example"',
                  style: AppText.mono(size: 12, color: T.greenInk),
                ),
              ),
          ],
        );

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[label, selector],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(flex: 4, child: label),
            const SizedBox(width: 16),
            Expanded(flex: 5, child: selector),
          ],
        );
      },
    );
  }
}

// ─── Step 3: preview ──────────────────────────────────────────────────────

class _PreviewStep extends ConsumerWidget {
  const _PreviewStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(importControllerProvider);
    final controller = ref.read(importControllerProvider.notifier);
    final preview = session.preview;
    if (preview == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Panel(
          child: Wrap(
            spacing: 28,
            runSpacing: 14,
            children: <Widget>[
              StatCell(label: 'Rows read', value: '${preview.totalRows}'),
              StatCell(
                label: 'Will import',
                value: '${preview.acceptedCount}',
                tone: T.greenInk,
              ),
              StatCell(
                label: 'Rejected',
                value: '${preview.rejectedCount}',
                tone: preview.hasErrors ? T.red : null,
              ),
              if (preview.newCount > 0)
                StatCell(label: 'New', value: '${preview.newCount}'),
              if (preview.updateCount > 0)
                StatCell(label: 'Updated', value: '${preview.updateCount}'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (preview.hasErrors) ...<Widget>[
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Rejected rows',
                  style: AppText.sectionTitle.copyWith(color: T.redInkDeep),
                ),
                const SizedBox(height: 4),
                Text(
                  'These are skipped. Row numbers match the source sheet.',
                  style: AppText.sans(size: 13.5, color: T.secondary),
                ),
                const SizedBox(height: 12),
                for (final e in preview.errors.take(50))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 62,
                          child: Text(
                            'Row ${e.rowNumber}',
                            style: AppText.mono(size: 12.5, color: T.muted),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${e.field}: ${e.message}',
                            style:
                                AppText.sans(size: 13.5, color: T.redInkDeep),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (preview.errors.length > 50)
                  Text(
                    '… and ${preview.errors.length - 50} more',
                    style: AppText.sans(size: 13, color: T.muted),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (preview.rows.isNotEmpty) _PreviewTable(preview: preview),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            OutlineActionButton(
              label: 'Back to mapping',
              onPressed: session.busy ? null : controller.backToMapping,
              fontSize: 15,
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledActionButton(
                label: session.busy
                    ? 'Importing…'
                    : 'Import ${preview.acceptedCount} rows',
                onPressed: (session.busy || !preview.canCommit)
                    ? null
                    : controller.commit,
                fontSize: 15.5,
                elevated: true,
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

class _PreviewTable extends StatelessWidget {
  const _PreviewTable({required this.preview});

  final ImportPreview preview;

  @override
  Widget build(BuildContext context) {
    final rows = preview.rows.take(10).toList();
    final columns = <String>[
      for (final k in rows.first.keys)
        if (k != r'$row') k,
    ];

    return Panel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('What will be imported', style: AppText.sectionTitle),
          const SizedBox(height: 12),
          // Wide tables scroll inside their own box rather than the page.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 38,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 44,
              columnSpacing: 22,
              headingTextStyle: AppText.sans(
                size: 12,
                weight: FontWeight.w700,
                color: T.muted,
              ),
              dataTextStyle: AppText.sans(size: 13, color: T.body),
              columns: <DataColumn>[
                for (final c in columns) DataColumn(label: Text(c)),
              ],
              rows: <DataRow>[
                for (final r in rows)
                  DataRow(
                    cells: <DataCell>[
                      for (final c in columns) DataCell(Text(r[c] ?? '')),
                    ],
                  ),
              ],
            ),
          ),
          if (preview.rows.length > rows.length) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'Showing ${rows.length} of ${preview.rows.length} rows.',
              style: AppText.sans(size: 13, color: T.muted),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Step 4: done ─────────────────────────────────────────────────────────

class _DoneStep extends ConsumerWidget {
  const _DoneStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(importControllerProvider).run;
    if (run == null) return const SizedBox.shrink();

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Imported ${run.rowsAccepted} rows',
            style: AppText.sectionTitle.copyWith(color: T.greenInk),
          ),
          const SizedBox(height: 4),
          Text(
            '${run.profileName} · ${run.fileName} · ${run.target.label}',
            style: AppText.sans(size: 13.5, color: T.secondary),
          ),
          const SizedBox(height: 16),
          FilledActionButton(
            label: 'Import something else',
            onPressed: ref.read(importControllerProvider.notifier).reset,
            fontSize: 15,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          ),
        ],
      ),
    );
  }
}

class _RunHistory extends ConsumerWidget {
  const _RunHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(importRunsProvider).valueOrNull ?? const <ImportRun>[];
    if (runs.isEmpty) return const SizedBox.shrink();

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Import history', style: AppText.sectionTitle),
          const SizedBox(height: 12),
          for (final r in runs.take(10))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  TagBadge(
                    label: r.target.label,
                    background: T.blueTint,
                    foreground: T.blue,
                  ),
                  Text(
                    '${r.rowsAccepted} rows',
                    style: AppText.mono(size: 13, weight: FontWeight.w600),
                  ),
                  Text(
                    '${r.fileName} · ${r.runAt} · ${r.runBy}',
                    style: AppText.sans(size: 12.5, color: T.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
