import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/app_user.dart';

/// Gating in the client is a courtesy: it decides which controls are worth
/// showing, and the server refuses the call regardless. What these tests hold
/// is that the courtesy follows the grants siteops-platform actually issued,
/// rather than the `role` column, which is a label once the platform is the
/// authority.

AppUser user({
  UserRole role = UserRole.executive,
  Set<String> permissions = const <String>{},
  bool? governsAllSites,
}) =>
    AppUser(
      id: 'u1',
      name: 'Rahul Sharma',
      userId: 'TV4021',
      email: '',
      role: role,
      sites: const <String>['MBMT'],
      active: true,
      permissions: permissions,
      governsAllSites: governsAllSites,
    );

void main() {
  group('permissions from the platform', () {
    test('a granted permission is held whatever the role says', () {
      final u = user(permissions: const <String>{'em_site_config:write'});
      expect(u.can('em_site_config:write'), isTrue);
      expect(u.canManageSites, isTrue);
    });

    test('an ungranted permission is not held, role notwithstanding', () {
      // The platform sent a permission set, so the role ladder does not get
      // a second vote: a `manager` label with read-only grants stays
      // read-only.
      final u = user(role: UserRole.manager, permissions: const <String>{'em_entry:read'});
      expect(u.can('em_entry:write'), isFalse);
      expect(u.canManageSites, isFalse);
    });

    test('governs_all_sites from the server outranks the role column', () {
      // A platform admin's E&M role is `executive` — a shadow row's label.
      final u = user(permissions: const <String>{}, governsAllSites: true);
      expect(u.can('em_site:write'), isTrue);
      expect(u.governsAllSites, isTrue);
    });

    test('parsing the wire keeps grants and the admin flag', () {
      final u = AppUser.fromJson(const <String, dynamic>{
        'id': 'u1',
        'name': 'Sanjay Pawar',
        'user_id': 'TV4102',
        'email': null,
        'role': 'executive',
        'site_access': <String>['MBMT'],
        'permissions': <String>['em_entry:write', 'em_entry:read'],
        'governs_all_sites': false,
        'is_active': true,
      });
      expect(u.can('em_entry:write'), isTrue);
      expect(u.can('em_report:write'), isFalse);
      expect(u.governsAllSites, isFalse);
    });
  });

  group('accounts with no grants fall back to the role ladder', () {
    test('a manager still manages', () {
      expect(user(role: UserRole.manager).canManageSites, isTrue);
    });

    test('a supervisor files work but does not configure the site', () {
      final u = user(role: UserRole.supervisor);
      expect(u.can('em_entry:write'), isTrue);
      expect(u.can('em_inspection:write'), isTrue);
      expect(u.can('em_site_config:write'), isFalse);
    });

    test('an executive reads only', () {
      final u = user(role: UserRole.executive);
      expect(u.can('em_report:read'), isTrue);
      expect(u.can('em_entry:write'), isFalse);
    });

    test('a super admin holds everything', () {
      expect(user(role: UserRole.superAdmin).can('em_site:delete'), isTrue);
    });
  });
}
