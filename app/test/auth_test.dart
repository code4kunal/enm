import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness.dart';
import 'support/seed.dart';
import 'package:transvolt_em/state/session.dart';

ProviderContainer makeContainer() {
  final container = fakeContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('credential sign-in', () {
    test('lands on the site picker with the first site pre-selected',
        () async {
      final container = makeContainer();
      await container
          .read(sessionProvider.notifier)
          .signInWithCredentials('TV4021', kSeedPassword);

      final s = container.read(sessionProvider);
      expect(s.stage, AuthStage.choosingSite);
      expect(s.user?.name, 'Rahul Sharma');
      expect(s.site, 'MBMT');
      expect(s.availableSites, <String>['MBMT', 'UMT']);
    });

    test('is case-insensitive on the User ID', () async {
      final container = makeContainer();
      await container
          .read(sessionProvider.notifier)
          .signInWithCredentials('tv4021', kSeedPassword);
      expect(container.read(sessionProvider).user?.userId, 'TV4021');
    });

    test('rejects empty credentials without calling the backend', () async {
      final container = makeContainer();
      await container.read(sessionProvider.notifier).signInWithCredentials('', '');

      final s = container.read(sessionProvider);
      expect(s.error, 'Enter your User ID and password');
      expect(s.stage, AuthStage.signedOut);
    });

    test('rejects an unknown User ID', () async {
      final container = makeContainer();
      await container
          .read(sessionProvider.notifier)
          .signInWithCredentials('TV0000', kSeedPassword);

      expect(container.read(sessionProvider).error, 'User ID not recognised');
    });

    test('rejects a deactivated account', () async {
      final container = makeContainer();
      // TV3610 (Deepak Rane) is seeded inactive.
      await container
          .read(sessionProvider.notifier)
          .signInWithCredentials('TV3610', kSeedPassword);

      final s = container.read(sessionProvider);
      expect(s.stage, AuthStage.signedOut);
      expect(s.error, contains('inactive'));
    });

    test('clearError wipes the inline message', () async {
      final container = makeContainer();
      final controller = container.read(sessionProvider.notifier);
      await controller.signInWithCredentials('TV0000', kSeedPassword);
      expect(container.read(sessionProvider).error, isNotNull);

      controller.clearError();
      expect(container.read(sessionProvider).error, isNull);
    });
  });

  group('Microsoft SSO', () {
    test('resolves to an account with a mail ID', () async {
      final container = makeContainer();
      await container.read(sessionProvider.notifier).signInWithMicrosoft();

      final s = container.read(sessionProvider);
      expect(s.stage, AuthStage.choosingSite);
      expect(s.user?.canUseSso, isTrue);
      expect(s.signingIn, isFalse);
    });
  });

  group('site selection', () {
    test('enterApp requires an authenticated user and a site', () {
      final container = makeContainer();
      container.read(sessionProvider.notifier).enterApp();
      expect(container.read(sessionProvider).stage, AuthStage.signedOut);
    });

    test('switchSite changes the active scope', () async {
      final container = makeContainer();
      final controller = container.read(sessionProvider.notifier);
      await controller.signInWithCredentials('TV4021', kSeedPassword);
      controller.enterApp();

      controller.switchSite('UMT');
      expect(container.read(sessionProvider).site, 'UMT');
      expect(container.read(sessionProvider).stage, AuthStage.signedIn);
    });
  });

  group('authorisation', () {
    test('managers may administer, executives may not', () async {
      final container = makeContainer();
      final controller = container.read(sessionProvider.notifier);

      await controller.signInWithCredentials('TV4021', kSeedPassword); // Manager
      expect(container.read(sessionProvider).canAdministerUsers, isTrue);

      await controller.signOut();
      await controller.signInWithCredentials('TV3987', kSeedPassword); // Executive
      expect(container.read(sessionProvider).canAdministerUsers, isFalse);
    });
  });

  group('sign out', () {
    test('returns to a clean signed-out session', () async {
      final container = makeContainer();
      final controller = container.read(sessionProvider.notifier);
      await controller.signInWithCredentials('TV4021', kSeedPassword);
      controller.enterApp();

      await controller.signOut();
      final s = container.read(sessionProvider);
      expect(s.stage, AuthStage.signedOut);
      expect(s.user, isNull);
      expect(s.site, '');
    });
  });
}
