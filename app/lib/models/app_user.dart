import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../theme/tokens.dart';

/// Privilege ladder, most to least.
///
/// [superAdmin] is platform-level and governs every site: it onboards sites,
/// maintains global master data, and creates users of any role including other
/// super admins. [manager] is the admin *of its own sites* — fleet, config,
/// import profiles and the site's supervisors and executives.
enum UserRole {
  superAdmin('Super Admin', T.indigoTint, T.indigo),
  manager('Manager', T.blueTint, T.blue),
  supervisor('Supervisor', T.greenTint, T.greenInk),
  executive('Executive', T.amberTint, T.amber);

  const UserRole(this.label, this.badgeBg, this.badgeFg);

  final String label;
  final Color badgeBg;
  final Color badgeFg;

  /// Sees and edits every site without needing explicit site access.
  bool get governsAllSites => this == UserRole.superAdmin;

  /// May maintain a site's vehicles, master lists, docking config and imports.
  bool get canManageSites =>
      this == UserRole.superAdmin || this == UserRole.manager;

  /// May reach the user-administration screens at all.
  bool get canAdministerUsers => canManageSites;

  /// Floor authority, not site administration: retrying a failed SAP post
  /// or acknowledging a recon exception, matching the server's own
  /// `require_supervisor` gate.
  bool get canActOnJobCards =>
      this == UserRole.superAdmin ||
      this == UserRole.manager ||
      this == UserRole.supervisor;

  /// Roles this role is allowed to hand out.
  ///
  /// A manager staffs its own sites but cannot mint peers or super admins —
  /// promotion is a super-admin act.
  List<UserRole> get grantableRoles => switch (this) {
        UserRole.superAdmin => UserRole.values,
        UserRole.manager => const <UserRole>[
            UserRole.supervisor,
            UserRole.executive,
          ],
        UserRole.supervisor || UserRole.executive => const <UserRole>[],
      };

  static UserRole fromLabel(String label) => UserRole.values.firstWhere(
        (r) => r.label == label,
        orElse: () => UserRole.executive,
      );

  /// Wire value: `super_admin`, `manager`, …
  String get wireName => switch (this) {
        UserRole.superAdmin => 'super_admin',
        UserRole.manager => 'manager',
        UserRole.supervisor => 'supervisor',
        UserRole.executive => 'executive',
      };

  static UserRole fromWire(String? value) => UserRole.values.firstWhere(
        (r) => r.wireName == value,
        orElse: () => UserRole.executive,
      );
}

@immutable
class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.userId,
    required this.email,
    required this.role,
    required this.sites,
    required this.active,
    this.mustResetPassword = false,
  });

  final String id;
  final String name;

  /// Site-issued login handle (e.g. `TV4021`). Unique across the tenant.
  final String userId;

  /// Optional. Presence of a Transvolt mail ID is what enables Microsoft SSO;
  /// ground staff without one sign in with [userId] + password.
  final String email;
  final UserRole role;

  /// Explicit site access. Empty and meaningless for a super admin, who reaches
  /// every site — always ask [canAccess] rather than reading this directly.
  final List<String> sites;

  /// Soft delete. Inactive users are retained and reactivatable, but auth must
  /// reject them server-side.
  final bool active;

  /// Set when an admin creates the account or resets the password; the client
  /// forces a change on next sign-in.
  final bool mustResetPassword;

  bool get canUseSso => email.trim().isNotEmpty;

  bool get governsAllSites => role.governsAllSites;

  bool get canManageSites => role.canManageSites;

  bool get canAdministerUsers => role.canAdministerUsers;

  bool get canActOnJobCards => role.canActOnJobCards;

  /// Super admins reach every site; everyone else needs an explicit grant.
  bool canAccess(String siteCode) =>
      governsAllSites || sites.contains(siteCode);

  /// Sites this user may switch between, given the full roster.
  List<String> accessibleSites(List<String> allSiteCodes) =>
      governsAllSites ? List<String>.of(allSiteCodes) : List<String>.of(sites);

  String get initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final letters = parts.map((p) => p[0]).join();
    return letters.substring(0, letters.length >= 2 ? 2 : 1).toUpperCase();
  }

  String get emailLabel =>
      canUseSso ? ' · $email' : ' · No mail ID (User ID login)';

  /// What the site column shows on a user row.
  String get siteLabel => governsAllSites ? 'All sites' : sites.join(', ');

  AppUser copyWith({
    String? name,
    String? userId,
    String? email,
    UserRole? role,
    List<String>? sites,
    bool? active,
    bool? mustResetPassword,
  }) {
    return AppUser(
      id: id,
      name: name ?? this.name,
      userId: userId ?? this.userId,
      email: email ?? this.email,
      role: role ?? this.role,
      sites: sites ?? this.sites,
      active: active ?? this.active,
      mustResetPassword: mustResetPassword ?? this.mustResetPassword,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'user_id': userId,
        'email': email.isEmpty ? null : email,
        'role': role.wireName,
        'site_access': sites,
        'is_active': active,
        'must_reset_password': mustResetPassword,
      };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        userId: json['user_id'] as String,
        email: json['email'] as String? ?? '',
        role: UserRole.fromWire(json['role'] as String?),
        sites: List<String>.from(
          json['site_access'] as List<dynamic>? ?? <dynamic>[],
        ),
        active: json['is_active'] as bool? ?? true,
        mustResetPassword: json['must_reset_password'] as bool? ?? false,
      );
}
