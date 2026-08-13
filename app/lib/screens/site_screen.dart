import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/chips.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/sub_tabs.dart';
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

  static const _labels = <String>[
    'Fleet',
    'Master data',
    'Docking',
    'Import',
  ];

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final site = ref.watch(activeSiteProvider);
    final capabilities = ref.watch(backendCapabilitiesProvider);

    if (!session.canManageSites) {
      return const EmptyState(
        message: 'Site administration is limited to managers.',
      );
    }
    if (session.site.isEmpty) {
      return const EmptyState(message: 'Pick a site first.');
    }

    return FadeUp(
      key: ValueKey<String>('site-${session.site}-$_pane'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (site != null) _SiteBanner(name: site.name, code: site.code),
          if (!capabilities.siteManagement) ...<Widget>[
            const SizedBox(height: 12),
            const _LegacyBackendNotice(),
          ],
          const SizedBox(height: 16),
          SubTabs(
            labels: _labels,
            selectedIndex: _pane,
            onChanged: (i) => setState(() => _pane = i),
          ),
          const SizedBox(height: 20),
          switch (_pane) {
            0 => const FleetPane(),
            1 => const MasterDataPane(),
            2 => const DockingPane(),
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

/// Shown when the connected API predates site management, so a manager knows
/// why editing is refused rather than meeting a bare error.
class _LegacyBackendNotice extends StatelessWidget {
  const _LegacyBackendNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: T.amberTint,
        borderRadius: T.cardSmShape,
        border: Border.all(color: T.amber),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const TagBadge(
            label: 'READ-ONLY',
            background: T.card,
            foreground: T.amber,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The connected API still uses fixed depots. Fleet, docking and '
              'import edits need the site-management release.',
              style: AppText.sans(size: 13.5, color: T.amber, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
