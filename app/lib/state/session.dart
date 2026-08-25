import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import '../models/app_user.dart';
import '../models/site.dart';
import 'providers.dart';
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

  /// Inline login error, shown in red under the credential fields.
  final String? error;

  bool get isAuthenticated => user != null;

  /// Platform-level: onboards sites, maintains global master data, creates any
  /// user including other super admins.
  bool get governsAllSites => user?.governsAllSites ?? false;

  /// May maintain a site's fleet, master lists, docking config and imports.
  bool get canManageSites => user?.canManageSites ?? false;

  bool get canAdministerUsers => user?.canAdministerUsers ?? false;

  bool get canActOnJobCards => user?.canActOnJobCards ?? false;

  /// The account was created or reset by an admin and owes a password change.
  bool get mustResetPassword => user?.mustResetPassword ?? false;

  SessionState copyWith({
    AuthStage? stage,
    AppUser? user,
    String? site,
    List<String>? availableSites,
    bool? signingIn,
    String? error,
    bool clearError = false,
  }) {
    return SessionState(
      stage: stage ?? this.stage,
      user: user ?? this.user,
      site: site ?? this.site,
      availableSites: availableSites ?? this.availableSites,
      signingIn: signingIn ?? this.signingIn,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState();

  AuthRepository get _auth => ref.read(authRepositoryProvider);

  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }

  /// Hands the browser to Microsoft. The page is replaced, so nothing after
  /// this runs on success — [resumeMicrosoftSignIn] picks it up on the way
  /// back.
  Future<void> signInWithMicrosoft(SsoConfig config) async {
    if (state.signingIn) return;
    state = state.copyWith(signingIn: true, clearError: true);
    try {
      await _auth.beginMicrosoftSignIn(config);
    } on ApiException catch (e) {
      state = state.copyWith(signingIn: false, error: e.message);
    }
  }

  /// Finishes a sign-in that a redirect started. A no-op on an ordinary load.
  ///
  /// Runs before the first frame so a returning user never sees the sign-in
  /// card flash past on their way in.
  Future<void> resumeMicrosoftSignIn(SsoConfig config) async {
    // Whether this load is actually a redirect is the repository's to know —
    // it returns null when it is not. Checking only that the deployment has
    // SSO at all keeps that judgement in one place.
    if (!config.enabled) return;
    state = state.copyWith(signingIn: true, clearError: true);
    try {
      final user = await _auth.completeMicrosoftSignIn(config);
      if (user == null) {
        state = state.copyWith(signingIn: false);
        return;
      }
      await _onAuthenticated(user);
    } on ApiException catch (e) {
      state = state.copyWith(signingIn: false, error: e.message);
    }
  }

  Future<void> signInWithCredentials(String userId, String password) async {
    if (userId.trim().isEmpty || password.isEmpty) {
      state = state.copyWith(error: 'Enter your User ID and password');
      return;
    }
    state = state.copyWith(clearError: true);
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
    );

    List<String> reachable;
    try {
      final sites = await ref.read(siteRepositoryProvider).fetchSites();
      reachable = sites
          .where((s) => s.isActive)
          .map((s) => s.code)
          .where(user.canAccess)
          .toList();
    } on ApiException {
      reachable = List<String>.of(user.sites);
    }

    state = state.copyWith(
      availableSites: reachable,
      // Pre-select the first site so the CTA is live immediately.
      site: reachable.isNotEmpty ? reachable.first : '',
    );
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
    state = state.copyWith(stage: AuthStage.signedIn);
  }

  /// Header site switcher. Re-scopes every list in the app.
  void switchSite(String site) {
    if (site == state.site) return;
    state = state.copyWith(site: site);
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
    state = const SessionState();
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
