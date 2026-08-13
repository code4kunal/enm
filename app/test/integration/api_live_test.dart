@Tags(<String>['live'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/data/api/api_client.dart';
import 'package:transvolt_em/data/api/api_repositories.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/models/app_user.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/utils/dates.dart';

/// Exercises the HTTP client against a real backend.
///
/// Skipped unless the API is reachable, so `flutter test` stays green offline.
/// Point it somewhere else with:
///
/// ```sh
/// flutter test --dart-define=API_BASE_URL=http://localhost:8123/api/v1 \
///   test/integration/api_live_test.dart
/// ```
const String kBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8123/api/v1',
);

const String kUserId = String.fromEnvironment(
  'API_USER_ID',
  defaultValue: 'TV4021',
);

const String kPassword = String.fromEnvironment(
  'API_PASSWORD',
  defaultValue: 'Transvolt@123',
);

Future<bool> _reachable(ApiClient client) async {
  try {
    await client.get('/health');
    return true;
  } on ApiException {
    return false;
  }
}

void main() {
  late ApiClient client;
  late bool online;

  setUpAll(() async {
    // SharedPreferences has no platform channel under `flutter test`.
    TestWidgetsFlutterBinding.ensureInitialized();
    client = ApiClient(baseUrl: kBaseUrl);
    online = await _reachable(client);
    if (!online) {
      // ignore: avoid_print
      print('SKIPPING live API tests — nothing answering at $kBaseUrl');
    }
  });

  tearDownAll(() => client.close());

  test('health responds', () async {
    if (!online) return;
    final json = await client.get('/health');
    expect((json as Map<String, dynamic>)['status'], 'ok');
  }, skip: false);

  test('credential sign-in returns a usable session', () async {
    if (!online) return;
    final auth = ApiAuthRepository(client);
    final user = await auth.signInWithCredentials(
      userId: kUserId,
      password: kPassword,
    );

    expect(user.userId, kUserId.toUpperCase());
    expect(user.active, isTrue);
    expect(client.isAuthenticated, isTrue);
    // Roles round-trip through the wire names.
    expect(UserRole.values, contains(user.role));
  });

  test('a wrong password is rejected with a readable message', () async {
    if (!online) return;
    final auth = ApiAuthRepository(ApiClient(baseUrl: kBaseUrl));
    await expectLater(
      auth.signInWithCredentials(userId: kUserId, password: 'wrong-password'),
      throwsA(isA<ApiException>()),
    );
  });

  test('the site roster answers', () async {
    if (!online) return;
    // A fresh install has no sites at all, and that is a valid answer — the
    // roster is built from the UI, not from a seed.
    final sites = await ApiSiteRepository(client).fetchSites();
    for (final site in sites) {
      expect(site.code, isNotEmpty);
      expect(site.timezone, isNotEmpty);
    }
  });

  test('master data resolves for the first site', () async {
    if (!online) return;
    final master = ApiMasterDataRepository(client);
    final codes = await master.siteCodes();
    expect(codes, isNotEmpty);

    final vehicles = await master.vehicleNumbers(siteCode: codes.first);
    expect(vehicles, isA<List<String>>());

    expect(await master.defectSources(), isNotEmpty);
    expect(await master.defectTypes(), isNotEmpty);
  });

  test('entries list is site-scoped and parses', () async {
    if (!online) return;
    final codes = await ApiMasterDataRepository(client).siteCodes();
    final entries =
        await ApiEntryRepository(client).fetchEntries(site: codes.first);

    expect(entries, isA<List<RegisterEntry>>());
    for (final e in entries) {
      expect(e.site, codes.first);
      expect(e.date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(e.time, matches(RegExp(r'^\d{2}:\d{2}$')));
    }
  });

  test('an entry round-trips through create and read back', () async {
    if (!online) return;
    final master = ApiMasterDataRepository(client);
    final codes = await master.siteCodes();
    final site = codes.first;
    final vehicles = await master.vehicleNumbers(siteCode: site);
    if (vehicles.isEmpty) return;

    final repo = ApiEntryRepository(client);
    final created = await repo.createEntry(
      RegisterEntry(
        id: '',
        registerId: 'coolant',
        date: Dates.today(),
        time: Dates.nowClock(),
        site: site,
        enteredBy: '',
        data: <String, String>{
          'bus': vehicles.first,
          'bcs': '1.5',
          'tcs': '0.5',
          'employee': 'Integration test',
        },
      ),
    );

    expect(created.id, isNotEmpty);
    expect(created.registerId, 'coolant');
    expect(created.busNumber, vehicles.first);

    final listed = await repo.fetchEntries(site: site);
    expect(listed.any((e) => e.id == created.id), isTrue);
  });

  test('admin user list parses into AppUser', () async {
    if (!online) return;
    final users = await ApiUserRepository(client).fetchUsers();
    expect(users, isNotEmpty);
    expect(users.first.userId, isNotEmpty);
    // Site access lands under whichever key this backend version uses.
    expect(users.first.sites, isA<List<String>>());
  });

  test('an unknown path surfaces as UnsupportedByBackend', () async {
    if (!online) return;
    await expectLater(
      client.get('/definitely-not-a-route'),
      throwsA(isA<UnsupportedByBackend>()),
    );
  });

  test('sign-out clears the token', () async {
    if (!online) return;
    await ApiAuthRepository(client).signOut();
    expect(client.isAuthenticated, isFalse);
  });
}
