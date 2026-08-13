import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/models/app_user.dart';
import 'support/harness.dart';
import 'support/seed.dart';
import 'package:transvolt_em/state/session.dart';
import 'package:transvolt_em/state/users.dart';

/// User lists are caller-scoped, so a test has to be signed in to see anyone.
/// TV1001 is the seeded super admin and sees the whole estate.
Future<ProviderContainer> makeContainer() async {
  final container = fakeContainer();
  addTearDown(container.dispose);
  await container
      .read(sessionProvider.notifier)
      .signInWithCredentials('TV1001', kSeedPassword);
  return container;
}

void main() {
  group('AppUser', () {
    test('derives two-letter initials', () {
      const u = AppUser(
        id: 'u1',
        name: 'Rahul Sharma',
        userId: 'TV4021',
        email: '',
        role: UserRole.manager,
        sites: <String>['MBMT'],
        active: true,
      );
      expect(u.initials, 'RS');
    });

    test('falls back to one letter for a single-word name', () {
      const u = AppUser(
        id: 'u2',
        name: 'Ramesh',
        userId: 'TV1',
        email: '',
        role: UserRole.executive,
        sites: <String>['MBMT'],
        active: true,
      );
      expect(u.initials, 'R');
    });

    test('SSO is gated on having a mail ID', () {
      const withMail = AppUser(
        id: 'u1',
        name: 'A B',
        userId: 'TV1',
        email: 'a.b@transvolt.in',
        role: UserRole.manager,
        sites: <String>['MBMT'],
        active: true,
      );
      const withoutMail = AppUser(
        id: 'u2',
        name: 'C D',
        userId: 'TV2',
        email: '',
        role: UserRole.executive,
        sites: <String>['MBMT'],
        active: true,
      );
      expect(withMail.canUseSso, isTrue);
      expect(withoutMail.canUseSso, isFalse);
      expect(withoutMail.emailLabel, ' · No mail ID (User ID login)');
    });

    test('only managers may administer users', () {
      expect(UserRole.manager, UserRole.fromLabel('Manager'));
      const manager = AppUser(
        id: 'u1',
        name: 'A B',
        userId: 'TV1',
        email: '',
        role: UserRole.manager,
        sites: <String>['MBMT'],
        active: true,
      );
      expect(manager.canAdministerUsers, isTrue);
      expect(manager.copyWith(role: UserRole.supervisor).canAdministerUsers, isFalse);
    });
  });

  group('UserDraft', () {
    test('toggles site membership both ways', () {
      const draft = UserDraft(sites: <String>['MBMT']);
      expect(draft.toggleSite('UMT').sites, <String>['MBMT', 'UMT']);
      expect(draft.toggleSite('MBMT').sites, isEmpty);
    });

    test('titles and CTAs switch on edit vs create', () {
      const create = UserDraft();
      const edit = UserDraft(id: 'u1');
      expect(create.title, 'Create user');
      expect(create.cta, 'Create user');
      expect(edit.title, 'Edit user');
      expect(edit.cta, 'Save changes');
    });
  });

  group('UsersController.save validation', () {
    test('rejects a blank name or User ID', () async {
      final container = await makeContainer();
      final controller = container.read(usersProvider.notifier);
      await container.read(usersProvider.future);

      expect(
        () => controller.save(const UserDraft(name: '  ', userId: 'TV9')),
        throwsA(isA<AuthException>()),
      );
    });

    test('requires at least one site', () async {
      final container = await makeContainer();
      final controller = container.read(usersProvider.notifier);
      await container.read(usersProvider.future);

      await expectLater(
        controller.save(const UserDraft(name: 'New Person', userId: 'TV9999')),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            'Select at least one site',
          ),
        ),
      );
    });

    test('rejects a duplicate User ID', () async {
      final container = await makeContainer();
      final controller = container.read(usersProvider.notifier);
      await container.read(usersProvider.future);

      await expectLater(
        controller.save(
          // TV4021 is Rahul Sharma in the seed set.
          const UserDraft(
            name: 'Someone Else',
            userId: 'TV4021',
            sites: <String>['MBMT'],
          ),
        ),
        throwsA(
          isA<AuthException>().having(
            (e) => e.message,
            'message',
            'User ID already exists',
          ),
        ),
      );
    });

    test('creates a valid user and prepends it to the list', () async {
      final container = await makeContainer();
      final controller = container.read(usersProvider.notifier);
      final before = await container.read(usersProvider.future);

      final result = await controller.save(
        const UserDraft(
          name: 'Sunil Patil',
          userId: 'tv4105',
          sites: <String>['MBMT'],
        ),
      );

      // User IDs are normalised to uppercase on save.
      expect(result.user.userId, 'TV4105');
      expect(result.user.active, isTrue);
      // A new account always comes back with a one-time password to hand over.
      expect(result.temporaryPassword, isNotNull);
      expect(result.user.mustResetPassword, isTrue);

      final after = container.read(usersProvider).requireValue;
      expect(after, hasLength(before.length + 1));
      expect(after.first.id, result.user.id);
    });

    test('an edit may keep its own User ID', () async {
      final container = await makeContainer();
      final controller = container.read(usersProvider.notifier);
      final users = await container.read(usersProvider.future);
      final rahul = users.firstWhere((u) => u.userId == 'TV4021');

      final saved = await controller.save(
        UserDraft.fromUser(rahul).copyWith(name: 'Rahul S Sharma'),
      );
      expect(saved.user.name, 'Rahul S Sharma');
      expect(saved.user.userId, 'TV4021');
      // Edits never mint a password.
      expect(saved.temporaryPassword, isNull);
    });

    test('setActive soft-deletes without removing the record', () async {
      final container = await makeContainer();
      final controller = container.read(usersProvider.notifier);
      final users = await container.read(usersProvider.future);
      final target = users.first;

      final deactivated = await controller.setActive(target.id, false);
      expect(deactivated.active, isFalse);
      expect(
        container.read(usersProvider).requireValue,
        hasLength(users.length),
      );

      final restored = await controller.setActive(target.id, true);
      expect(restored.active, isTrue);
    });
  });

  group('filteredUsersProvider', () {
    test('splits the seed set by active flag', () async {
      final container = await makeContainer();
      final all = await container.read(usersProvider.future);

      container.read(userFilterProvider.notifier).set(UserFilter.inactive);
      final inactive = container.read(filteredUsersProvider);
      expect(inactive.every((u) => !u.active), isTrue);

      container.read(userFilterProvider.notifier).set(UserFilter.active);
      final active = container.read(filteredUsersProvider);
      expect(active.every((u) => u.active), isTrue);

      expect(active.length + inactive.length, all.length);
    });
  });
}
