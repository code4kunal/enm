import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/admin_screen.dart';
import 'screens/breakdowns_screen.dart';
import 'screens/home_screen.dart';
import 'screens/inspection_form_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_form_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/registers_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/schedule_screen.dart';
import 'screens/shell_screen.dart';
import 'screens/site_screen.dart';
import 'screens/vehicle_master_screen.dart';
import 'state/session.dart';
import 'widgets/page_body.dart';

abstract final class Routes {
  static const login = '/login';
  static const home = '/home';
  static const registers = '/registers';
  static const breakdowns = '/breakdowns';
  static const schedule = '/schedule';
  static const vehicleMaster = '/vehicle-master';
  static const reports = '/reports';
  static const site = '/site';
  static const admin = '/admin';
  static const profile = '/profile';

  static String newEntry(String registerId) => '/entry/new/$registerId';

  /// Data entry for one inspection type - each has its own checklist, so each
  /// has its own form.
  static String newInspection(int workTypeId) => '/inspection/new/$workTypeId';

  static String editEntry(String entryId) => '/entry/edit/$entryId';
}

/// Bridges Riverpod's session state to GoRouter's refresh mechanism so the
/// redirect re-runs on sign-in and sign-out.
class _SessionRefresh extends ChangeNotifier {
  _SessionRefresh(this._ref) {
    _sub = _ref.listen<SessionState>(
      sessionProvider,
      (_, __) => notifyListeners(),
    );
  }

  final Ref _ref;
  late final ProviderSubscription<SessionState> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.login,
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      // Hold navigation until tokens are restored — otherwise a reload always
      // looks signed-out and bounces to /login before /auth/me returns.
      if (session.restoring) return null;

      final atLogin = state.matchedLocation == Routes.login;
      final stage = session.stage;

      // The site picker lives on the login card, so anything short of
      // signedIn belongs there.
      if (stage != AuthStage.signedIn) return atLogin ? null : Routes.login;
      return atLogin ? Routes.home : null;
    },
    routes: <RouteBase>[
      GoRoute(
        path: Routes.login,
        builder: (context, state) => const LoginScreen(),
      ),
      ShellRoute(
        // The header, tabs and bottom nav persist across every app route,
        // including the entry form.
        builder: (context, state, child) => ShellScreen(
          location: state.matchedLocation,
          child: child,
        ),
        routes: <RouteBase>[
          GoRoute(
            path: Routes.home,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: HomeScreen()),
            ),
          ),
          GoRoute(
            path: Routes.registers,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: RegistersScreen()),
            ),
          ),
          GoRoute(
            path: Routes.breakdowns,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: BreakdownsScreen()),
            ),
          ),
          GoRoute(
            path: '/inspection/new/:workTypeId',
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: PageBody(
                child: InspectionFormScreen(
                  workTypeId:
                      int.tryParse(state.pathParameters['workTypeId'] ?? '') ?? 0,
                ),
              ),
            ),
          ),
          GoRoute(
            path: Routes.schedule,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: ScheduleScreen()),
            ),
          ),
          GoRoute(
            path: Routes.vehicleMaster,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: VehicleMasterScreen()),
            ),
          ),
          GoRoute(
            path: Routes.reports,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: ReportsScreen()),
            ),
          ),
          GoRoute(
            path: Routes.site,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: SiteScreen()),
            ),
          ),
          GoRoute(
            path: Routes.admin,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: AdminScreen()),
            ),
          ),
          GoRoute(
            path: Routes.profile,
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: const PageBody(child: ProfileScreen()),
            ),
          ),
          GoRoute(
            path: '/entry/new/:registerId',
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: PageBody(
                child: RegisterFormScreen(
                  registerId: state.pathParameters['registerId']!,
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/entry/edit/:entryId',
            pageBuilder: (context, state) => NoTransitionPage<void>(
              key: state.pageKey,
              child: PageBody(
                child: RegisterFormScreen(
                  entryId: state.pathParameters['entryId'],
                ),
              ),
            ),
          ),
        ],
      ),
    ],
  );
});
