import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/job_card.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../state/toast.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/sub_tabs.dart';

/// SAP master-data sync status. Never shows a secret value — configured
/// yes/no and a timestamp only, matching the spec's own rule for this panel.
class SyncPane extends ConsumerStatefulWidget {
  const SyncPane({super.key});

  @override
  ConsumerState<SyncPane> createState() => _SyncPaneState();
}

class _SyncPaneState extends ConsumerState<SyncPane> {
  bool _syncing = false;
  SapSyncStatus? _last;
  String? _error;

  Future<void> _syncNow() async {
    final site = ref.read(sessionProvider).site;
    if (site.isEmpty) return;
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      final result = await ref.read(sapSyncRepositoryProvider).syncNow(site);
      setState(() => _last = result);
      ref.read(toastProvider.notifier).show(
            '${result.equipmentMatched} buses, ${result.materialsSynced} parts, '
            '${result.flocsMatched} site matched',
          );
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSync = ref.watch(sessionProvider).canManageSites;

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('SAP master sync', style: AppText.sans(size: 16, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Pulls the fleet\'s SAP equipment numbers and the spares catalog. '
            'Runs nightly on its own; use this to pull sooner.',
            style: AppText.sans(size: 13, color: T.secondary),
          ),
          const SizedBox(height: 16),
          if (!canSync)
            Text(
              'Only a manager can trigger a sync.',
              style: AppText.sans(size: 13, color: T.muted),
            )
          else
            FilledActionButton(
              label: _syncing ? 'Syncing…' : 'SAP sync now',
              onPressed: _syncing ? null : _syncNow,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_error!, style: AppText.sans(size: 13, color: T.red)),
          ],
          if (_last != null) ...<Widget>[
            const SizedBox(height: 16),
            _Row('Buses matched', '${_last!.equipmentMatched}'),
            _Row('Parts synced', '${_last!.materialsSynced}'),
            _Row('Site matched', _last!.flocsMatched > 0 ? 'Yes' : 'No'),
            _Row('Last synced', _last!.syncedAt),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: <Widget>[
          Text(label, style: AppText.sans(size: 13, color: T.secondary)),
          const Spacer(),
          Text(value, style: AppText.mono(size: 13, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}
