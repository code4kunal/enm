import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/session.dart';
import '../widgets/dashed.dart';
import '../widgets/fade_up.dart';
import '../widgets/sub_tabs.dart';
import 'admin/audit_pane.dart';
import 'admin/project_reports_pane.dart';
import 'admin/sites_pane.dart';
import 'admin/summary_pane.dart';
import 'admin/users_pane.dart';

/// Platform administration.
///
/// Super admins get Summary, project reports, Sites, Users and Audit.
/// Managers reach only the user pane, and only for staff on their own sites.
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

    // Only a super admin onboards sites and sees estate KPIs / audit.
    final showEstate = session.governsAllSites;
    if (!showEstate) {
      return const FadeUp(
        key: ValueKey<String>('admin-users'),
        child: UsersPane(),
      );
    }

    const labels = <String>[
      'Summary',
      'Reports',
      'Sites',
      'Users',
      'Audit',
    ];

    return FadeUp(
      key: ValueKey<String>('admin-$_pane'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SubTabs(
            labels: labels,
            selectedIndex: _pane,
            onChanged: (i) => setState(() => _pane = i),
          ),
          const SizedBox(height: 20),
          switch (_pane) {
            0 => const AdminSummaryPane(),
            1 => const AdminProjectReportsPane(),
            2 => const SitesPane(),
            3 => const UsersPane(),
            _ => const AdminAuditPane(),
          },
        ],
      ),
    );
  }
}
