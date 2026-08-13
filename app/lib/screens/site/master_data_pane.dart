import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories.dart';
import '../../models/site.dart';
import '../../state/session.dart';
import '../../state/sites.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/chips.dart';
import '../../widgets/dashed.dart';
import '../../widgets/form_controls.dart';
import '../../widgets/sub_tabs.dart';

/// The editable dropdown lists behind Source of Defect and Type of Defect.
///
/// These are tenant-wide rather than per site: a defect type means the same
/// thing everywhere, and entries FK to them, so only a super admin may edit.
class MasterDataPane extends ConsumerStatefulWidget {
  const MasterDataPane({super.key});

  @override
  ConsumerState<MasterDataPane> createState() => _MasterDataPaneState();
}

class _MasterDataPaneState extends ConsumerState<MasterDataPane> {
  MasterListKind _kind = MasterListKind.defectSources;

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(sessionProvider).governsAllSites;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ScreenHeader(
          title: 'Master data',
          subtitle: canEdit
              ? 'Shared across every site. An entry can only carry a value that '
                  'is on one of these lists.'
              : 'Shared across every site and maintained by a super admin. '
                  'Read-only here.',
        ),
        const SizedBox(height: 16),
        SubTabs(
          labels: <String>[
            for (final k in MasterListKind.values) k.label,
          ],
          selectedIndex: MasterListKind.values.indexOf(_kind),
          onChanged: (i) => setState(() => _kind = MasterListKind.values[i]),
        ),
        const SizedBox(height: 16),
        _MasterList(kind: _kind, canEdit: canEdit),
      ],
    );
  }
}

class _MasterList extends ConsumerStatefulWidget {
  const _MasterList({required this.kind, required this.canEdit});

  final MasterListKind kind;
  final bool canEdit;

  @override
  ConsumerState<_MasterList> createState() => _MasterListState();
}

class _MasterListState extends ConsumerState<_MasterList> {
  final _addController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      ref.read(toastProvider.notifier).show(success);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(masterListProvider(widget.kind));
    final controller = ref.read(masterListControllerProvider(widget.kind));
    final items = async.valueOrNull ?? const <MasterListItem>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.canEdit) ...<Widget>[
          Panel(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: AppTextField(
                        controller: _addController,
                        placeholder: 'Add to ${widget.kind.label.toLowerCase()}…',
                        onSubmitted: (_) => _add(controller),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledActionButton(
                      label: 'Add',
                      onPressed: _busy ? null : () => _add(controller),
                      fontSize: 14,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                  ],
                ),
                if (_error != null) InlineError(message: _error!),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        if (async.isLoading && items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator(color: T.green)),
          )
        else if (items.isEmpty)
          EmptyState(message: 'No ${widget.kind.label.toLowerCase()} yet.')
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final item in items) ...<Widget>[
                _Row(
                  item: item,
                  canEdit: widget.canEdit,
                  onToggle: () => _run(
                    () => controller.setActive(item, !item.isActive),
                    item.isActive
                        ? '"${item.name}" hidden from the dropdown'
                        : '"${item.name}" restored',
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }

  void _add(MasterListController controller) {
    final name = _addController.text.trim();
    if (name.isEmpty) return;
    _run(() async {
      await controller.add(name);
      _addController.clear();
    }, 'Added "$name"');
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.item,
    required this.canEdit,
    required this.onToggle,
  });

  final MasterListItem item;
  final bool canEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: item.isActive ? 1 : 0.62,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: T.cardSmShape,
          border: Border.all(color: T.border),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    item.name,
                    style: AppText.sans(size: 15, weight: FontWeight.w600),
                  ),
                  if (!item.isActive)
                    const TagBadge(
                      label: 'HIDDEN',
                      background: T.inactiveFill,
                      foreground: T.muted,
                    ),
                ],
              ),
            ),
            if (canEdit)
              OutlineActionButton(
                label: item.isActive ? 'Hide' : 'Restore',
                onPressed: onToggle,
                foreground: item.isActive ? T.redInk : T.greenInk,
                borderColor: item.isActive ? T.redBorderTint : T.green,
                fontSize: 12.5,
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              ),
          ],
        ),
      ),
    );
  }
}
