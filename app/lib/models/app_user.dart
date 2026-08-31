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
  ///
  /// Only meaningful for an E&M-local account. A user signed in through
  /// siteops-platform carries [AppUser.governsAllSites] from the server,
  /// because their E&M role is a label and the platform decides.
  bool get governsAllSites => this == UserRole.superAdmin;

  /// May maintain a site's vehicles, master lists, docking config and imports.
  bool get canManageSites =>
      this == UserRole.superAdmin || this == UserRole.manager;

  /// May reach the user-administration screens at all.
  bool get canAdministerUsers => canManageSites;

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
    this.permissions = const <String>{},
    this.isPlatformManaged = false,
    bool? governsAllSites,
  }) : _governsAllSites = governsAllSites;

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

  /// What this account may do, as `em_<resource>:<action>` names.
  ///
  /// Granted in siteops-platform, which is where roles are built and where an
  /// administrator attaches E&M's permissions to them. The client gates on
  /// these rather than on [role], which became a label the moment the
  /// platform became the authority.
  final Set<String> permissions;

  /// True for any account SiteOps manages — created via `ensure_user` on the
  /// backend, password always null there. E&M's admin screens hide edit
  /// actions for these; the account is administered in SiteOps.
  final bool isPlatformManaged;

  final bool? _governsAllSites;

  bool get canUseSso => email.trim().isNotEmpty;

  /// Reaches every site without a stored grant. Answered by the server for a
  /// platform user; falls back to the role for an E&M-local account.
  bool get governsAllSites => _governsAllSites ?? role.governsAllSites;

  /// Whether this account holds a permission.
  ///
  /// An empty [permissions] set means the server did not send any — an
  /// account predating the integration, or a fake in a test — so the old
  /// role ladder answers instead. Wrong answers here only ever hide a
  /// control the server would refuse anyway: every one of these checks is
  /// re-made server-side.
  bool can(String permission) {
    if (governsAllSites) return true;
    if (permissions.isEmpty) return _roleAllows(permission);
    return permissions.contains(permission);
  }

  bool _roleAllows(String permission) {
    final write = !permission.endsWith(':read');
    return switch (role) {
      UserRole.superAdmin => true,
      UserRole.manager => true,
      UserRole.supervisor => !write ||
          permission.startsWith('em_entry:') ||
          permission.startsWith('em_inspection:'),
      UserRole.executive => !write,
    };
  }

  bool get canManageSites => can('em_site_config:write');

  bool get canAdministerUsers => can('em_user:write');

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
    Set<String>? permissions,
    bool? isPlatformManaged,
    bool? governsAllSites,
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
      permissions: permissions ?? this.permissions,
      isPlatformManaged: isPlatformManaged ?? this.isPlatformManaged,
      governsAllSites: governsAllSites ?? _governsAllSites,
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
        'permissions': permissions.toList()..sort(),
        'is_platform_managed': isPlatformManaged,
        'governs_all_sites': governsAllSites,
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
        permissions: <String>{
          for (final p in (json['permissions'] as List<dynamic>? ?? <dynamic>[]))
            p as String,
        },
        isPlatformManaged: json['is_platform_managed'] as bool? ?? false,
        governsAllSites: json['governs_all_sites'] as bool?,
      );
}
