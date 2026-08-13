import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/admin_screen.dart';
import 'screens/breakdowns_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_form_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/registers_screen.dart';
import 'screens/shell_screen.dart';
import 'screens/site_screen.dart';
import 'state/session.dart';

abstract final class Routes {
  static const login = '/login';
  static const home = '/home';
  static const registers = '/registers';
  static const breakdowns = '/breakdowns';
  static const site = '/site';
  static const admin = '/admin';
  static const profile = '/profile';

  static String newEntry(String registerId) => '/entry/new/$registerId';

  static String editEntry(String entryId) => '/entry/edit/$entryId';
}

/// Bridges Riverpod's session state to GoRouter's refresh mechanism so the
/// redirect re-runs on sign-in and sign-out.
class _SessionRefresh extends ChangeNotifier {
  _SessionRefresh(this._ref) {
    _sub = _ref.listen<AuthStage>(
      sessionProvider.select((s) => s.stage),
      (_, __) => notifyListeners(),
    );
  }

  final Ref _ref;
  late final ProviderSubscription<AuthStage> _sub;

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
      final stage = ref.read(sessionProvider).stage;
      final atLogin = state.matchedLocation == Routes.login;

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
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: Routes.registers,
            builder: (context, state) => const RegistersScreen(),
          ),
          GoRoute(
            path: Routes.breakdowns,
            builder: (context, state) => const BreakdownsScreen(),
          ),
          GoRoute(
            path: Routes.site,
            builder: (context, state) => const SiteScreen(),
          ),
          GoRoute(
            path: Routes.admin,
            builder: (context, state) => const AdminScreen(),
          ),
          GoRoute(
            path: Routes.profile,
            builder: (context, state) => const ProfileScreen(),
          ),
          GoRoute(
            path: '/entry/new/:registerId',
            builder: (context, state) => RegisterFormScreen(
              registerId: state.pathParameters['registerId']!,
            ),
          ),
          GoRoute(
            path: '/entry/edit/:entryId',
            builder: (context, state) => RegisterFormScreen(
              entryId: state.pathParameters['entryId'],
            ),
          ),
        ],
      ),
    ],
  );
});
