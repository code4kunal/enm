import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/sub_tabs.dart';
import 'admin/sites_pane.dart';
import 'admin/users_pane.dart';

/// Platform administration.
///
/// Super admins govern the whole estate — onboarding sites and creating any
/// user, including other super admins. Managers reach only the user pane, and
/// only for staff on their own sites.
class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  int _pane = 0;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    if (!session.canAdministerUsers) {
      return const EmptyState(
        message: 'Administration is limited to managers and super admins.',
      );
    }

    // Only a super admin onboards sites, so managers see the users pane alone.
    final showSites = session.governsAllSites;
    if (!showSites) {
      return const FadeUp(
        key: ValueKey<String>('admin-users'),
        child: UsersPane(),
      );
    }

    return FadeUp(
      key: ValueKey<String>('admin-$_pane'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SubTabs(
            labels: const <String>['Sites', 'Users'],
            selectedIndex: _pane,
            onChanged: (i) => setState(() => _pane = i),
          ),
          const SizedBox(height: 20),
          if (_pane == 0) const SitesPane() else const UsersPane(),
        ],
      ),
    );
  }
}
