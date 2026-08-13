import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import '../models/app_user.dart';
import '../models/site.dart';
import 'providers.dart';

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

  Future<void> signInWithMicrosoft() async {
    if (state.signingIn) return;
    state = state.copyWith(signingIn: true, clearError: true);
    try {
      await _onAuthenticated(await _auth.signInWithMicrosoft());
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
    if (state.user == null || state.site.isEmpty) return;
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
