import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_store.dart';
import 'support/harness.dart';
import 'support/seed.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/models/app_user.dart';
import 'package:transvolt_em/models/site.dart';
import 'package:transvolt_em/state/providers.dart';
import 'package:transvolt_em/state/session.dart';
import 'package:transvolt_em/state/sites.dart';

Future<ProviderContainer> signedIn(String userId) async {
  final container = fakeContainer();
  addTearDown(container.dispose);
  await container
      .read(sessionProvider.notifier)
      .signInWithCredentials(userId, kSeedPassword);
  container.read(sessionProvider.notifier).enterApp();
  return container;
}

void main() {
  group('site visibility', () {
    test('a super admin sees every site', () async {
      final container = await signedIn('TV1001');
      final sites = await container.read(sitesAdminProvider.future);
      expect(sites, hasLength(kSeedSiteSpecs.length));
    });

    test('a manager sees only their granted sites', () async {
      final container = await signedIn('TV4021');
      final sites = await container.read(sitesAdminProvider.future);
      expect(sites.map((s) => s.code).toList(), <String>['MBMT', 'UMT']);
    });

    test('the site picker excludes deactivated sites', () async {
      // KANDLA is seeded inactive and is the only site TV3610 holds.
      final container = await signedIn('TV1001');
      final available = container.read(sessionProvider).availableSites;
      expect(available, isNot(contains('KANDLA')));
    });
  });

  group('onboarding', () {
    test('creates a site and makes it immediately switchable', () async {
      final container = await signedIn('TV1001');
      final controller = container.read(sitesAdminProvider.notifier);
      await container.read(sitesAdminProvider.future);

      final created = await controller.save(
        const SiteDraft(code: 'pune', name: 'Pune City Transport'),
      );

      // Codes are normalised to uppercase.
      expect(created.code, 'PUNE');
      expect(created.isActive, isTrue);
      expect(
        container.read(sessionProvider).availableSites,
        contains('PUNE'),
      );
    });

    test('rejects a duplicate code', () async {
      final container = await signedIn('TV1001');
      final controller = container.read(sitesAdminProvider.notifier);
      await container.read(sitesAdminProvider.future);

      await expectLater(
        controller.save(const SiteDraft(code: 'MBMT', name: 'Clash')),
        throwsA(isA<ApiException>()),
      );
    });

    test('rejects a malformed code', () async {
      final container = await signedIn('TV1001');
      await container.read(sitesAdminProvider.future);

      await expectLater(
        container
            .read(sitesAdminProvider.notifier)
            .save(const SiteDraft(code: 'A', name: 'Too short')),
        throwsA(isA<ApiException>()),
      );
    });

    test('requires a name', () async {
      final container = await signedIn('TV1001');
      await container.read(sitesAdminProvider.future);

      await expectLater(
        container
            .read(sitesAdminProvider.notifier)
            .save(const SiteDraft(code: 'NEWSITE', name: '  ')),
        throwsA(isA<ApiException>()),
      );
    });

    test('deactivating a site removes it from the switcher', () async {
      final container = await signedIn('TV1001');
      final controller = container.read(sitesAdminProvider.notifier);
      await container.read(sitesAdminProvider.future);

      await controller.setActive('UMT', false);
      expect(
        container.read(sessionProvider).availableSites,
        isNot(contains('UMT')),
      );
    });
  });

  group('fleet', () {
    test('is scoped to the active site', () async {
      final container = await signedIn('TV4021');
      final vehicles = await container.read(vehiclesProvider.future);
      expect(vehicles, isNotEmpty);
      expect(vehicles.every((v) => v.siteCode == 'MBMT'), isTrue);
    });

    test('switchSite refreshes Bus No master data for the new depot', () async {
      final container = await signedIn('TV4021');
      final before = await container.read(masterDataProvider.future);
      expect(before.siteCode, 'MBMT');
      expect(before.vehicles, isNotEmpty);
      expect(before.vehicles.every((v) => v.startsWith('MH40')), isTrue);

      container.read(sessionProvider.notifier).switchSite('UMT');
      final after = await container.read(masterDataProvider.future);
      expect(after.siteCode, 'UMT');
      expect(after.vehicles, isNotEmpty);
      expect(after.vehicles, isNot(equals(before.vehicles)));
      expect(after.vehicles.every((v) => v.startsWith('MH12')), isTrue);

      final fleet = await container.read(vehiclesProvider.future);
      expect(fleet.every((v) => v.siteCode == 'UMT'), isTrue);
    });

    test('adding a vehicle normalises its registration', () async {
      final container = await signedIn('TV4021');
      await container.read(vehiclesProvider.future);

      final created = await container
          .read(vehiclesProvider.notifier)
          .add(registrationNo: ' mh40 ly 9999 ');
      expect(created.registrationNo, 'MH40LY9999');
    });

    test('a duplicate registration is rejected', () async {
      final container = await signedIn('TV4021');
      await container.read(vehiclesProvider.future);

      await expectLater(
        container
            .read(vehiclesProvider.notifier)
            .add(registrationNo: 'MH40LY1894'),
        throwsA(isA<ApiException>()),
      );
    });

    test('retiring a vehicle drops it from the entry dropdown', () async {
      final container = await signedIn('TV4021');
      final vehicles = await container.read(vehiclesProvider.future);
      final target = vehicles.first;

      await container
          .read(vehiclesProvider.notifier)
          .setActive(target.id, false);

      final master = await container.read(masterDataProvider.future);
      expect(master.vehicles, isNot(contains(target.registrationNo)));

      // The record itself survives, so past entries still resolve.
      final all = container.read(vehiclesProvider).requireValue;
      expect(all.any((v) => v.id == target.id), isTrue);
    });

    test('a new vehicle appears in the entry dropdown', () async {
      final container = await signedIn('TV4021');
      await container.read(vehiclesProvider.future);

      await container
          .read(vehiclesProvider.notifier)
          .add(registrationNo: 'MH40LY7777');

      final master = await container.read(masterDataProvider.future);
      expect(master.vehicles, contains('MH40LY7777'));
    });
  });

  group('roles', () {
    test('a super admin may grant any role', () {
      expect(UserRole.superAdmin.grantableRoles, UserRole.values);
    });

    test('a manager may not mint peers or super admins', () {
      expect(
        UserRole.manager.grantableRoles,
        <UserRole>[UserRole.supervisor, UserRole.executive],
      );
    });

    test('supervisors and executives grant nothing', () {
      expect(UserRole.supervisor.grantableRoles, isEmpty);
      expect(UserRole.executive.grantableRoles, isEmpty);
    });

    test('a super admin reaches a site it holds no explicit grant for', () {
      const admin = AppUser(
        id: 'x',
        name: 'A B',
        userId: 'TV1',
        email: '',
        role: UserRole.superAdmin,
        sites: <String>[],
        active: true,
      );
      expect(admin.canAccess('ANYTHING'), isTrue);
      expect(admin.accessibleSites(<String>['A', 'B']), <String>['A', 'B']);
      expect(admin.siteLabel, 'All sites');
    });

    test('a manager is confined to its grants', () {
      const manager = AppUser(
        id: 'y',
        name: 'C D',
        userId: 'TV2',
        email: '',
        role: UserRole.manager,
        sites: <String>['MBMT'],
        active: true,
      );
      expect(manager.canAccess('MBMT'), isTrue);
      expect(manager.canAccess('UMT'), isFalse);
      expect(manager.accessibleSites(<String>['MBMT', 'UMT']), <String>['MBMT']);
    });
  });

  group('Site model', () {
    test('tracks commissioning', () {
      const pending = Site(code: 'X', name: 'X', isActive: true);
      expect(pending.isCommissioned, isFalse);
      expect(
        pending.copyWith(commissionedOn: '2026-01-01').isCommissioned,
        isTrue,
      );
    });
  });

  group('first run', () {
    test('a super admin with no sites can still enter and onboard one',
        () async {
      // A fresh install has users but an empty site roster; Admin → Sites is
      // where the first one is created, so the picker must not lock the door.
      final store = FakeStore()..sites.clear();
      final container = fakeContainer(store);
      final session = container.read(sessionProvider.notifier);
      await session.signInWithCredentials('TV1001', kSeedPassword);

      expect(container.read(sessionProvider).availableSites, isEmpty);
      expect(container.read(sessionProvider).site, isEmpty);

      session.enterApp();
      expect(container.read(sessionProvider).stage, AuthStage.signedIn);
    });

    test('everyone else still needs a site before entering', () async {
      final container = fakeContainer();
      final session = container.read(sessionProvider.notifier);
      await session.signInWithCredentials('TV4021', kSeedPassword);

      session.selectSite('');
      session.enterApp();
      expect(container.read(sessionProvider).stage, isNot(AuthStage.signedIn));
    });
  });
}
