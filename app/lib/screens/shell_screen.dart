import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../router.dart';
import '../models/site.dart';
import '../state/entries.dart';
import '../state/odometer_sync.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_toast.dart';
import '../widgets/chips.dart';
import '../widgets/code_square.dart';
import '../state/providers.dart';
import '../state/selected_site.dart';

/// One navigation destination, shared by the desktop tab row and the mobile
/// bottom nav.
class _Tab {
  const _Tab(this.label, this.route);

  final String label;
  final String route;
}

class ShellScreen extends ConsumerWidget {
  const ShellScreen({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMobile =
        MediaQuery.sizeOf(context).width < T.mobileBreakpoint;
    final session = ref.watch(sessionProvider);
    final openBreakdowns = ref.watch(openBreakdownsProvider).length;
    final openRecon = ref.watch(jobCardReconProvider).valueOrNull?.length ?? 0;

    // Keeping the odometers current is what makes the maintenance schedule
    // mean anything, so the poller is mounted by the shell rather than by the
    // one screen that happens to read it.
    ref.watch(odometerSyncProvider);

    final tabs = <_Tab>[
      const _Tab('Home', Routes.home),
      const _Tab('Registers', Routes.registers),
      const _Tab('Breakdowns', Routes.breakdowns),
      const _Tab('Job Cards', Routes.jobCards),
      const _Tab('Schedule', Routes.schedule),
      const _Tab('Vehicle Master', Routes.vehicleMaster),
      const _Tab('Reports', Routes.reports),
      // Site and Admin are role-gated â€” hidden rather than disabled, and the
      // server enforces the same rule.
      if (session.canManageSites) const _Tab('Site', Routes.site),
      if (session.canAdministerUsers) const _Tab('Admin', Routes.admin),
    ];

    // The entry form keeps whichever tab launched it lit; on a deep link it
    // falls back to Home.
    final activeRoute = tabs.any((t) => t.route == location)
        ? location
        : (location.startsWith('/entry/') || location == Routes.profile
            ? ''
            : Routes.home);

    return Scaffold(
      backgroundColor: T.pageBg,
      body: Stack(
        children: <Widget>[
          Column(
            children: <Widget>[
              _Header(
                isMobile: isMobile,
                tabs: tabs,
                activeRoute: activeRoute,
                openBreakdowns: openBreakdowns,
                openRecon: openRecon,
              ),
              // A bounded box, and nothing else: `child` is the ShellRoute's
              // Navigator, which cannot lay out against an unbounded height.
              // Each page scrolls itself, inside `PageBody`.
              Expanded(child: child),
            ],
          ),
          if (isMobile)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomNav(
                tabs: tabs,
                activeRoute: activeRoute,
                openBreakdowns: openBreakdowns,
                openRecon: openRecon,
              ),
            ),
          AppToast(isMobile: isMobile),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.isMobile,
    required this.tabs,
    required this.activeRoute,
    required this.openBreakdowns,
    required this.openRecon,
  });

  final bool isMobile;
  final List<_Tab> tabs;
  final String activeRoute;
  final int openBreakdowns;
  final int openRecon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final user = session.user;

    return Material(
      color: T.card,
      child: SafeArea(
        bottom: false,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: T.border)),
          ),
          child: Column(
            children: <Widget>[
              Center(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: T.maxContentWidth),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Row(
                      children: <Widget>[
                        Image.asset(
                          'assets/images/transvolt-logo.png',
                          height: 20,
                          fit: BoxFit.contain,
                          semanticLabel: 'Transvolt',
                        ),
                        const SizedBox(width: 14),
                        Container(width: 1, height: 22, color: T.border),
                        const SizedBox(width: 14),
                        Text(
                          'E&M',
                          style: AppText.sans(
                            size: 13,
                            weight: FontWeight.w700,
                            color: T.green,
                            letterSpacing: 0.14 * 13,
                          ),
                        ),
                        const Spacer(),
                        const _SiteOpsDropdown(),
                        const SizedBox(width: 12),
                        // The avatar opens the account screen; sign-out lives
                        // there, so a mis-tap on a tablet cannot drop a
                        // mechanic mid-entry.
                        Tooltip(
                          message: user == null
                              ? 'Account'
                              : '${user.name} Â· Account',
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => context.go(Routes.profile),
                            child: Stack(
                              children: <Widget>[
                                InitialsAvatar(
                                  initials: user?.initials ?? '?',
                                  size: 36,
                                ),
                                // Nudge toward the account screen while a
                                // temporary password is still in force.
                                if (session.mustResetPassword)
                                  Positioned(
                                    right: 0,
                                    top: 0,
                                    child: Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: T.red,
                                        shape: BoxShape.circle,
                                        border:
                                            Border.all(color: T.card, width: 1.5),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (!isMobile)
                Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: T.maxContentWidth),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: <Widget>[
                          for (final t in tabs)
                            _DesktopTab(
                              tab: t,
                              active: t.route == activeRoute,
                              badge: switch (t.route) {
                                Routes.breakdowns => openBreakdowns,
                                Routes.jobCards => openRecon,
                                _ => 0,
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopTab extends StatelessWidget {
  const _DesktopTab({
    required this.tab,
    required this.active,
    required this.badge,
  });

  final _Tab tab;
  final bool active;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go(tab.route),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? T.green : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: <Widget>[
            Text(
              tab.label,
              style: AppText.sans(
                size: 14.5,
                weight: FontWeight.w600,
                color: active ? T.ink : T.muted,
              ),
            ),
            if (badge > 0) ...<Widget>[
              const SizedBox(width: 7),
              CountBadge(count: badge),
            ],
          ],
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.tabs,
    required this.activeRoute,
    required this.openBreakdowns,
    required this.openRecon,
  });

  final List<_Tab> tabs;
  final String activeRoute;
  final int openBreakdowns;
  final int openRecon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: T.card,
        border: Border(top: BorderSide(color: T.border)),
        boxShadow: T.bottomNavShadow,
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: <Widget>[
            for (final t in tabs)
              Expanded(
                child: _BottomNavItem(
                  tab: t,
                  active: t.route == activeRoute,
                  badge: switch (t.route) {
                    Routes.breakdowns => openBreakdowns,
                    Routes.jobCards => openRecon,
                    _ => 0,
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.tab,
    required this.active,
    required this.badge,
  });

  final _Tab tab;
  final bool active;
  final int badge;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go(tab.route),
      child: SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            // 4px green indicator bar hanging off the top edge.
            Positioned(
              top: 0,
              child: Container(
                width: 34,
                height: 4,
                decoration: BoxDecoration(
                  color: active ? T.green : Colors.transparent,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(4),
                  ),
                ),
              ),
            ),
            Text(
              tab.label,
              style: AppText.sans(
                size: 13.5,
                weight: active ? FontWeight.w700 : FontWeight.w600,
                color: active ? T.green : T.muted,
              ),
            ),
            if (badge > 0)
              Align(
                alignment: const Alignment(0.62, -0.5),
                child: CountBadge(count: badge, compact: true),
              ),
          ],
        ),
      ),
    );
  }
}



// ─── SiteOps Site Dropdown ────────────────────────────────────────────────────


// ___ SiteOps Site Dropdown ___________________________________________________

class _SiteItem {
  const _SiteItem({required this.id, required this.name, required this.siteType, required this.code});
  final String id;
  final String name;
  final String siteType;
  /// Short uppercase handle (MBMT) that the E&M backend uses as site PK.
  final String code;
}

class _SiteOpsDropdown extends ConsumerStatefulWidget {
  const _SiteOpsDropdown();

  @override
  ConsumerState<_SiteOpsDropdown> createState() => _SiteOpsDropdownState();
}

class _SiteOpsDropdownState extends ConsumerState<_SiteOpsDropdown> {
  List<_SiteItem> _sites = [];
  _SiteItem? _selected;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSites();
  }

  /// Map a SiteOps dropdown row to the E&M depot code (`MBMT`), never a UUID.
  String _enmCodeFor(Map<String, dynamic> j, List<Site> enmSites) {
    final raw = (j['code'] ?? j['site_code'])?.toString().trim().toUpperCase() ?? '';
    // Reject empty strings and UUID-shaped values from SiteOps. A non-UUID
    // raw code is still SiteOps's OWN code (e.g. "WC-003"), not necessarily
    // ours — only trust it if it is actually one of our site codes.
    final looksLikeUuid = raw.contains('-') && raw.length >= 32;
    if (raw.isNotEmpty && !looksLikeUuid && enmSites.any((s) => s.code == raw)) {
      return raw;
    }

    final name = (j['name']?.toString() ?? '').trim().toLowerCase();
    if (name.isEmpty) {
      return enmSites.length == 1 ? enmSites.first.code : '';
    }

    for (final s in enmSites) {
      final enmName = s.name.trim().toLowerCase();
      final enmCode = s.code.toLowerCase();
      if (enmName == name || enmCode == name) return s.code;
      if (enmName.contains(name) || name.contains(enmName)) return s.code;
      if (name.contains(enmCode) || enmName.contains(enmCode)) return s.code;
    }

    // Single-depot installs: SiteOps name may not match E&M wording.
    if (enmSites.length == 1) return enmSites.first.code;
    return '';
  }

  Future<void> _loadSites() async {
    try {
      // Proxied through our own backend, which holds the SiteOps service
      // key — no per-user SiteOps session required just to populate this.
      final json = await ref.read(apiClientProvider).get('/siteops/sites');
      final data = (json is Map ? json['data'] : json) as List<dynamic>? ?? [];

      // E&M sites keyed by code — SiteOps only supplies the UUID + display name.
      final enmSites = await ref.read(siteRepositoryProvider).fetchSites();

      final sites = data
          .cast<Map<String, dynamic>>()
          .map((j) {
            final name = j['name']?.toString() ?? '';
            return _SiteItem(
              id: j['id']?.toString() ?? '',
              name: name,
              siteType: j['site_type']?.toString() ?? '',
              code: _enmCodeFor(j, enmSites),
            );
          })
          .toList();
      if (mounted) {
        setState(() {
          _sites = sites;
          if (sites.isNotEmpty) {
            // Default to the depot's real site rather than whichever SiteOps
            // happens to list first — that is often an empty test site.
            // "Ghodbandar1" and other near-duplicates exist too, so prefer an
            // exact name match before falling back to a loose one.
            final defaultSite = sites.firstWhere(
                  (s) => s.name.trim().toLowerCase() == 'ghodbandar',
                  orElse: () => sites.firstWhere(
                        (s) => s.name.toLowerCase().contains('ghodb'),
                        orElse: () => sites.first,
                      ),
                );
            _selected = defaultSite;
            ref.read(selectedSiteProvider.notifier).select(defaultSite.id, defaultSite.name);
            // Never push a SiteOps UUID into session — E&M APIs key on MBMT etc.
            if (defaultSite.code.isNotEmpty) {
              ref.read(sessionProvider.notifier).switchSite(defaultSite.code);
            }
          }
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_sites.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: T.subtleFill,
        borderRadius: T.controlShape,
        border: Border.all(color: T.inputBorder, width: 1.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selected?.id,
          isDense: true,
          borderRadius: T.controlShape,
          dropdownColor: T.card,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          icon: const Icon(Icons.expand_more, size: 20, color: T.secondary),
          style: AppText.sans(size: 13, weight: FontWeight.w600),
          items: <DropdownMenuItem<String>>[
            for (final s in _sites)
              DropdownMenuItem<String>(
                value: s.id,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(s.name, style: AppText.sans(size: 13)),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: T.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        s.siteType,
                        style: AppText.mono(size: 10, color: T.green, weight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          onChanged: (id) {
            if (id != null) {
              final site = _sites.firstWhere((s) => s.id == id);
              setState(() => _selected = site);
              ref.read(selectedSiteProvider.notifier).select(site.id, site.name);
              if (site.code.isNotEmpty) {
                ref.read(sessionProvider.notifier).switchSite(site.code);
              }
            }
          },
        ),
      ),
    );
  }
}
