import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories.dart';
import '../models/app_user.dart';
import '../models/site.dart';
import 'providers.dart';
import 'selected_site.dart';
import '../data/auth/ms_sso.dart';

/// Where the user is in the sign-in flow.
///
/// [choosingSite] sits between authentication and the app because a user can
/// hold access to several sites — a super admin to all of them — and every list
/// in the app is site-scoped.
enum AuthStage { signedOut, choosingSite, signedIn }

@immutable
class SessionState {
  const SessionState({
    this.stage = AuthStage.signedOut,
    this.user,
    this.site = '',
    this.availableSites = const <String>[],
    this.signingIn = false,
    this.restoring = false,
    this.error,
  });

  final AuthStage stage;
  final AppUser? user;

  /// Active site. Empty until sign-in resolves the user's access.
  final String site;

  /// Sites this user may switch between, resolved after authentication. For a
  /// super admin this is the whole roster.
  final List<String> availableSites;

  /// True while the Microsoft handshake is in flight — drives the button's
  /// "Connecting to Microsoft…" label and sweep animation.
  final bool signingIn;

  /// True until startup has tried token restore (and optional MS redirect).
  /// The router must not treat this as signed-out or a reload flashes login.
  final bool restoring;

  /// Inline login error, shown in red under the credential fields.
  final String? error;

  bool get isAuthenticated => user != null;

  /// Platform-level: onboards sites, maintains global master data, creates any
  /// user including other super admins.
  bool get governsAllSites => user?.governsAllSites ?? false;

  /// May maintain a site's fleet, master lists, docking config and imports.
  bool get canManageSites => user?.canManageSites ?? false;

  bool get canAdministerUsers => user?.canAdministerUsers ?? false;

  /// Whether the signed-in account holds an `em_<resource>:<action>` grant.
  ///
  /// What every screen asks before offering a control. The server re-checks
  /// each one, so this only decides what is worth showing.
  bool can(String permission) => user?.can(permission) ?? false;

  /// Whether the Site tab has anything behind it for this account: the fleet,
  /// the docking configuration, or the import profiles.
  bool get canOpenSiteTab =>
      can('em_vehicle:read') ||
      can('em_site_config:read') ||
      can('em_import:read');

  /// The account was created or reset by an admin and owes a password change.
  bool get mustResetPassword => user?.mustResetPassword ?? false;

  SessionState copyWith({
    AuthStage? stage,
    AppUser? user,
    String? site,
    List<String>? availableSites,
    bool? signingIn,
    bool? restoring,
    String? error,
    bool clearError = false,
  }) {
    return SessionState(
      stage: stage ?? this.stage,
      user: user ?? this.user,
      site: site ?? this.site,
      availableSites: availableSites ?? this.availableSites,
      signingIn: signingIn ?? this.signingIn,
      restoring: restoring ?? this.restoring,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SessionController extends Notifier<SessionState> {
  static const _lastSiteKey = 'transvolt.last_site';

  @override
  SessionState build() => const SessionState(restoring: true);

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }

  /// Startup: finish an MS redirect if present, else restore tokens from storage.
  ///
  /// Must finish before the router treats the user as signed out — see
  /// [SessionState.restoring].
  Future<void> bootstrap(SsoConfig config) async {
    // Microsoft redirect replaces the page; finishing it wins over a stale
    // stored session from a previous visit.
    if (config.enabled) {
      state = state.copyWith(signingIn: true, clearError: true);
      try {
        final user = await _auth.completeMicrosoftSignIn(config);
        if (user != null) {
          await _onAuthenticated(user);
          return;
        }
        state = state.copyWith(signingIn: false);
      } on ApiException catch (e) {
        state = SessionState(restoring: false, error: e.message);
        return;
      }
    }

    await restoreFromStorage();
  }

  /// Load persisted JWTs, validate with `/auth/me`, and re-enter the app.
  Future<void> restoreFromStorage() async {
    try {
      final user = await _auth.restoreSession();
      if (user == null) {
        state = const SessionState(restoring: false);
        return;
      }
      await _enterRestored(user);
    } on ApiException {
      state = const SessionState(restoring: false);
    } catch (_) {
      state = const SessionState(restoring: false);
    }
  }

  /// Hands the browser to Microsoft. The page is replaced, so nothing after
  /// this runs on success — [bootstrap] picks it up on the way back.
  Future<void> signInWithMicrosoft(SsoConfig config) async {
    if (state.signingIn) return;
    state = state.copyWith(signingIn: true, clearError: true, restoring: false);
    try {
      await _auth.beginMicrosoftSignIn(config);
    } on ApiException catch (e) {
      state = state.copyWith(signingIn: false, error: e.message);
    }
  }

  /// Finishes a sign-in that a redirect started. Prefer [bootstrap] at startup.
  Future<void> resumeMicrosoftSignIn(SsoConfig config) async {
    if (!config.enabled) {
      state = state.copyWith(restoring: false, signingIn: false);
      return;
    }
    state = state.copyWith(signingIn: true, clearError: true);
    try {
      final user = await _auth.completeMicrosoftSignIn(config);
      if (user == null) {
        state = state.copyWith(signingIn: false, restoring: false);
        return;
      }
      await _onAuthenticated(user);
    } on ApiException catch (e) {
      state = SessionState(restoring: false, error: e.message);
    }
  }

  Future<void> signInWithCredentials(String userId, String password) async {
    if (userId.trim().isEmpty || password.isEmpty) {
      state = state.copyWith(
        error: 'Enter your User ID and password',
        restoring: false,
      );
      return;
    }
    state = state.copyWith(clearError: true, restoring: false);
    try {
      await _onAuthenticated(
        await _auth.signInWithCredentials(userId: userId, password: password),
      );
    } on ApiException catch (e) {
      state = state.copyWith(error: e.message);
    }
  }

  /// Resolves which sites the account can reach, then parks on the picker.
  ///
  /// A super admin's reachable set is the live roster rather than a stored
  /// list, so onboarding a site grants access without touching the account.
  Future<void> _onAuthenticated(AppUser user) async {
    state = SessionState(
      stage: AuthStage.choosingSite,
      user: user,
      signingIn: false,
      restoring: false,
    );

    final reachable = await _reachableSites(user);
    final remembered = await _readLastSite();
    final preferred = reachable.contains(remembered)
        ? remembered
        : (reachable.isNotEmpty ? reachable.first : '');

    state = state.copyWith(
      availableSites: reachable,
      site: preferred,
    );
  }

  /// Reload path: skip the site picker when a remembered site is still valid.
  Future<void> _enterRestored(AppUser user) async {
    final reachable = await _reachableSites(user);
    // Prefer E&M code persisted with the SiteOps selection, then last site.
    await ref.read(selectedSiteProvider.notifier).ready;
    final selectedEnm = ref.read(selectedSiteProvider).enmCode;
    final remembered = selectedEnm.isNotEmpty
        ? selectedEnm
        : await _readLastSite();
    final site = reachable.contains(remembered)
        ? remembered
        : (reachable.isNotEmpty ? reachable.first : '');

    if (site.isEmpty && !user.governsAllSites) {
      state = SessionState(
        stage: AuthStage.choosingSite,
        user: user,
        availableSites: reachable,
        restoring: false,
      );
      return;
    }

    state = SessionState(
      stage: AuthStage.signedIn,
      user: user,
      availableSites: reachable,
      site: site,
      restoring: false,
    );
    if (site.isNotEmpty) await _writeLastSite(site);
  }

  Future<List<String>> _reachableSites(AppUser user) async {
    try {
      final sites = await ref.read(siteRepositoryProvider).fetchSites();
      return sites
          .where((s) => s.isActive)
          .map((s) => s.code)
          .where(user.canAccess)
          .toList();
    } on ApiException {
      return List<String>.of(user.sites);
    }
  }

  Future<String> _readLastSite() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_lastSiteKey) ?? '';
    } on Exception {
      return '';
    } on Error {
      return '';
    }
  }

  Future<void> _writeLastSite(String site) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (site.isEmpty) {
        await prefs.remove(_lastSiteKey);
      } else {
        await prefs.setString(_lastSiteKey, site);
      }
    } on Exception {
      // Persistence is best-effort — in-memory session still works.
    } on Error {
      // Same degradation as ApiClient prefs.
    }
  }

  /// Site pick on the login card, before entering the app.
  void selectSite(String site) => state = state.copyWith(site: site);

  void enterApp() {
    final user = state.user;
    if (user == null) return;
    // A super admin may enter with no site: on a fresh install there are none
    // yet, and Admin → Sites is where the first one gets onboarded. Everyone
    // else works inside a site and needs one picked.
    if (state.site.isEmpty && !user.governsAllSites) return;
    state = state.copyWith(stage: AuthStage.signedIn, restoring: false);
    if (state.site.isNotEmpty) {
      // Fire-and-forget — enterApp is sync for the UI.
      unawaited(_writeLastSite(state.site));
    }
  }

  /// Header site switcher. Re-scopes every list in the app.
  ///
  /// [masterDataProvider] / [siteVehiclesProvider] / [vehiclesProvider] watch
  /// [SessionState.site], so updating it here is what refreshes Bus No and
  /// staff dropdowns. Empty [site] clears the active depot (SiteOps row with
  /// no E&M mapping) — do not leave the previous code in place.
  void switchSite(String site) {
    final code = site.trim().toUpperCase();
    if (code == state.site) return;
    // copyWith treats a null [site] as "keep"; pass the (possibly empty) code
    // explicitly so an unmapped SiteOps row clears the previous depot.
    state = state.copyWith(site: code);
    unawaited(_writeLastSite(code));
  }

  /// Keeps the session's copy of the user current after an admin edits it or a
  /// password change clears the reset flag.
  void refreshUser(AppUser user) {
    if (state.user?.id != user.id) return;
    state = state.copyWith(user: user);
  }

  /// Called after a site is onboarded so a super admin can switch to it at once.
  void adoptSites(List<Site> sites) {
    final user = state.user;
    if (user == null) return;
    final reachable = sites
        .where((s) => s.isActive)
        .map((s) => s.code)
        .where(user.canAccess)
        .toList();
    state = state.copyWith(
      availableSites: reachable,
      site: reachable.contains(state.site)
          ? state.site
          : (reachable.isNotEmpty ? reachable.first : ''),
    );
  }

  Future<void> changePassword(String current, String next) async {
    await _auth.changePassword(currentPassword: current, newPassword: next);
    final user = state.user;
    if (user != null) {
      state = state.copyWith(user: user.copyWith(mustResetPassword: false));
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    await ref.read(selectedSiteProvider.notifier).clear();
    state = const SessionState(restoring: false);
  }
}

final sessionProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);


/// Whether this deployment offers Microsoft sign-in, asked once per launch.
///
/// The sign-in card waits on this rather than always showing the button: a
/// button that fails when tapped is worse than no button, and this is the only
/// way one build can serve a site with SSO and a site without.
final ssoConfigProvider = FutureProvider<SsoConfig>((ref) {
  return ref.watch(authRepositoryProvider).ssoConfig();
});
