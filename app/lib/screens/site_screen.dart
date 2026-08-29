import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/sub_tabs.dart';
import 'site/checklists_pane.dart';
import 'site/docking_pane.dart';
import 'site/fleet_pane.dart';
import 'site/import_pane.dart';
import 'site/master_data_pane.dart';

/// Everything a manager maintains for the site they are standing in.
///
/// Reached by managers and super admins; the shell hides the tab for anyone
/// else, and the server enforces the same rule.
class SiteScreen extends ConsumerStatefulWidget {
  const SiteScreen({super.key});

  @override
  ConsumerState<SiteScreen> createState() => _SiteScreenState();
}

class _SiteScreenState extends ConsumerState<SiteScreen> {
  int _pane = 0;

  /// The panes, each with the grant its screen needs. A depot that imports
  /// spreadsheets but may not read the fleet sees Import and nothing else,
  /// rather than a Fleet pane reporting an empty depot it simply cannot see.
  static const _panes = <({String label, String permission})>[
    (label: 'Fleet', permission: 'em_vehicle:read'),
    (label: 'Master data', permission: 'em_master:read'),
    (label: 'Checklists', permission: 'em_site_config:read'),
    (label: 'Docking', permission: 'em_site_config:read'),
    (label: 'Import', permission: 'em_import:read'),
  ];

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final site = ref.watch(activeSiteProvider);

    if (!session.canOpenSiteTab) {
      return const EmptyState(
        message: 'Site administration is limited to managers.',
      );
    }
    if (session.site.isEmpty) {
      return const EmptyState(message: 'Pick a site first.');
    }

    final visible =
        _panes.where((p) => session.can(p.permission)).toList(growable: false);
    if (visible.isEmpty) {
      return const EmptyState(
        message: 'Site administration is limited to managers.',
      );
    }
    // The remembered pane may be one this account cannot open — land on the
    // first it can rather than on an empty screen it has no way to leave.
    final selected = _panes.indexWhere(
      (p) => p.label == _panes[_pane].label && session.can(p.permission),
    );
    final shown = selected == -1
        ? 0
        : visible.indexWhere((p) => p.label == _panes[_pane].label);

    return FadeUp(
      key: ValueKey<String>('site-${session.site}-$_pane'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (site != null) _SiteBanner(name: site.name, code: site.code),
          const SizedBox(height: 16),
          SubTabs(
            labels: <String>[for (final p in visible) p.label],
            selectedIndex: shown,
            onChanged: (i) => setState(
              () => _pane = _panes.indexWhere((p) => p.label == visible[i].label),
            ),
          ),
          const SizedBox(height: 20),
          switch (_panes.indexWhere((p) => p.label == visible[shown].label)) {
            0 => const FleetPane(),
            1 => const MasterDataPane(),
            2 => const ChecklistsPane(),
            3 => const DockingPane(),
            _ => const ImportPane(),
          },
        ],
      ),
    );
  }
}

class _SiteBanner extends StatelessWidget {
  const _SiteBanner({required this.name, required this.code});

  final String name;
  final String code;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            color: T.ink,
            borderRadius: T.controlShape,
          ),
          child: Text(
            code,
            style: AppText.mono(
              size: 14,
              weight: FontWeight.w700,
              color: T.white,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            name,
            style: AppText.sans(size: 17, weight: FontWeight.w700),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
