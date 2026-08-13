import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:transvolt_em/data/api/api_client.dart';
import 'package:transvolt_em/data/api/api_repositories.dart';
import 'package:transvolt_em/data/api/field_map.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/models/app_user.dart';
import 'package:transvolt_em/models/entry.dart';

/// Contract tests against responses captured from a running backend.
///
/// The fixtures in `test/fixtures/` are verbatim output from the FastAPI
/// service, so these tests catch the thing unit tests with hand-written JSON
/// never do: the client and the server disagreeing about a field name.
String fixture(String name) =>
    File('test/fixtures/$name.json').readAsStringSync();

/// Serves canned responses, keyed by the path each request asks for.
ApiClient clientServing(Map<String, ({int status, String body})> routes) {
  final mock = MockClient((http.Request request) async {
    final path = request.url.path.replaceFirst('/api/v1', '');
    final match = routes[path];
    if (match == null) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error': <String, String>{'code': 'NOT_FOUND', 'message': 'Not Found'},
        }),
        404,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response(
      match.body,
      match.status,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  return ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);
}

({int status, String body}) ok(String name) =>
    (status: 200, body: fixture(name));

void main() {
  group('entry parsing', () {
    test('a real coolant entry maps onto the form keys', () {
      final client = clientServing(<String, ({int status, String body})>{
        '/entries': ok('entries'),
      });

      return ApiEntryRepository(client)
          .fetchEntries(site: 'MBMT')
          .then((entries) {
        expect(entries, hasLength(1));
        final e = entries.single;

        expect(e.registerId, 'coolant');
        expect(e.site, 'MBMT');
        expect(e.time, '09:29');
        expect(e.enteredBy, 'Rahul Sharma');
        expect(e.status, EntryStatus.done);

        // The server says bus_no / bcs_litres / topped_by; the form wants
        // bus / bcs / employee.
        expect(e.busNumber, 'MH40LY1894');
        expect(e.data['bcs'], '1.5');
        expect(e.data['tcs'], '0.5');
        expect(e.data['employee'], 'Fixture');
        // Nothing should survive under the wire names.
        expect(e.data.containsKey('bus_no'), isFalse);
        expect(e.data.containsKey('bcs_litres'), isFalse);
      });
    });

    test('a created entry parses the same way', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/entries': ok('entry_create'),
      });

      final created = await ApiEntryRepository(client).createEntry(
        const RegisterEntry(
          id: '',
          registerId: 'coolant',
          date: '2026-08-13',
          time: '09:29',
          site: 'MBMT',
          enteredBy: '',
          data: <String, String>{'bus': 'MH40LY1894', 'bcs': '1.5'},
        ),
      );
      expect(created.id, isNotEmpty);
      expect(created.busNumber, 'MH40LY1894');
      expect(created.data['bcs'], '1.5');
    });

    test('the create body uses the API field names', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(fixture('entry_create'), 200);
      });
      final client =
          ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      await ApiEntryRepository(client).createEntry(
        const RegisterEntry(
          id: '',
          registerId: 'coolant',
          date: '2026-08-13',
          time: '09:29',
          site: 'MBMT',
          enteredBy: '',
          data: <String, String>{
            'bus': 'MH40LY1894',
            'bcs': '1.5',
            'tcs': '',
            'employee': 'Fixture',
          },
        ),
      );

      expect(sent['register'], 'coolant');
      expect(sent['depot'], 'MBMT');
      final data = sent['data'] as Map<String, dynamic>;
      expect(data['bus_no'], 'MH40LY1894');
      // Numbers go over as numbers, not strings.
      expect(data['bcs_litres'], 1.5);
      expect(data['topped_by'], 'Fixture');
      // Blank optional values are omitted, not sent as "".
      expect(data.containsKey('tcs_litres'), isFalse);
    });
  });

  group('field map', () {
    test('every register round-trips its own columns', () {
      const cases = <String, Map<String, String>>{
        'work': <String, String>{
          'shift': 'A',
          'bus': 'MH40LY1894',
          'defects': 'AC fault',
          'source': 'Driver report',
          'defectType': 'AC & HVAC',
          'attended': 'Fixed',
          'spares': 'Fuse',
          'employee': 'R. Sharma',
        },
        'complaint': <String, String>{
          'bus': 'MH1',
          'defectType': 'Doors',
          'complaint': 'Door stuck',
          'action': 'Adjusted',
          'mechanic': 'A. Khan',
        },
        'breakdown': <String, String>{
          'bus': 'MH1',
          'driver': 'DRV-1',
          'loc': 'SV Road',
          'complaint': 'No traction',
          't_bd': '06:32',
          't_mech': '06:50',
          't_att': '07:35',
          'loss': '18',
          'attended': 'Reset',
          'remarks': 'Watch',
        },
        'pm': <String, String>{
          'bus': 'MH1',
          'defectType': 'Tyres',
          'defects': 'Uneven wear',
          'action': 'Rotated',
          'balance': 'NIL',
          'spares': 'NIL',
          'employee': 'Team A',
        },
      };

      cases.forEach((registerId, data) {
        final wire = RegisterFieldMap.toWire(registerId, data);
        final back = RegisterFieldMap.fromWire(registerId, wire);
        expect(back, data, reason: registerId);
      });
    });

    test('unknown keys are dropped rather than sent', () {
      final wire = RegisterFieldMap.toWire(
        'coolant',
        const <String, String>{'bus': 'MH1', 'nonsense': 'x'},
      );
      expect(wire.keys, <String>['bus_no']);
    });

    test('a whole number comes back without a trailing .0', () {
      final back = RegisterFieldMap.fromWire(
        'coolant',
        <String, dynamic>{'bcs_litres': 2.0},
      );
      expect(back['bcs'], '2');
    });
  });

  group('user parsing', () {
    test('a real admin user list maps onto AppUser', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/admin/users': ok('users'),
      });
      final users = await ApiUserRepository(client).fetchUsers();

      expect(users, hasLength(1));
      final u = users.single;
      expect(u.name, 'Rahul Sharma');
      expect(u.userId, 'TV4021');
      expect(u.role, UserRole.manager);
      expect(u.sites, <String>['MBMT', 'UMT']);
      expect(u.active, isTrue);
      // A null email means "no mail ID", not the string "null".
      expect(u.email, '');
      expect(u.canUseSso, isFalse);
    });

    test('role wire names round-trip', () {
      for (final role in UserRole.values) {
        expect(UserRole.fromWire(role.wireName), role);
      }
      expect(UserRole.fromWire('super_admin'), UserRole.superAdmin);
      // An unknown role degrades to the least privileged, never the most.
      expect(UserRole.fromWire('wizard'), UserRole.executive);
    });
  });

  group('master data parsing', () {
    test('depots, buses and defect lists parse', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/master/depots': ok('depots'),
        '/master/buses': ok('buses'),
        '/master/defect-sources': ok('defect_sources'),
        '/master/defect-types': ok('defect_types'),
      });
      final master = ApiMasterDataRepository(client);

      expect(await master.siteCodes(), <String>['MBMT', 'UMT']);
      expect(await master.vehicleNumbers(siteCode: 'MBMT'), isNotEmpty);
      expect(await master.defectSources(), isNotEmpty);
      expect(await master.defectTypes(), isNotEmpty);
    });
  });

  group('capabilities', () {
    test('a backend without /sites is detected as legacy', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/master/depots': ok('depots'),
      });
      await client.detectCapabilities();

      expect(client.capabilities.siteManagement, isFalse);
      expect(client.capabilities.scopeParam, 'depot');
    });

    test('a backend with /sites unlocks site management', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/sites': (
          status: 200,
          body: jsonEncode(<String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{'code': 'MBMT', 'name': 'Mira', 'is_active': true},
            ],
          }),
        ),
      });
      await client.detectCapabilities();

      expect(client.capabilities.siteManagement, isTrue);
      expect(client.capabilities.scopeParam, 'site');
    });

    test('legacy site fetch falls back to the depot master', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/master/depots': ok('depots'),
      });
      final sites = await ApiSiteRepository(client).fetchSites();
      expect(sites.map((s) => s.code), <String>['MBMT', 'UMT']);
    });

    test('onboarding refuses clearly on a legacy backend', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/master/depots': ok('depots'),
      });
      await expectLater(
        ApiSiteRepository(client).createSite(code: 'X', name: 'Y'),
        throwsA(isA<UnsupportedByBackend>()),
      );
    });
  });

  group('error mapping', () {
    test('the error envelope becomes a readable message', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/auth/login': (status: 401, body: fixture('error_401')),
      });

      await expectLater(
        ApiAuthRepository(client)
            .signInWithCredentials(userId: 'TV4021', password: 'nope'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'Invalid User ID or password',
          ),
        ),
      );
    });

    test('an unrouted path becomes UnsupportedByBackend', () async {
      final client = clientServing(<String, ({int status, String body})>{});
      await expectLater(
        client.get('/nope'),
        throwsA(isA<UnsupportedByBackend>()),
      );
    });

    test('a transport failure names the host rather than leaking a stack', () async {
      final mock = MockClient((_) async => throw const SocketException('down'));
      final client =
          ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      await expectLater(
        client.get('/health'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('Cannot reach the server'),
          ),
        ),
      );
    });
  });

  group('auth', () {
    test('login stores the tokens and probes capabilities', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/auth/login': ok('login'),
        '/master/depots': ok('depots'),
      });

      final user = await ApiAuthRepository(client)
          .signInWithCredentials(userId: 'tv4021', password: 'x');

      expect(user.userId, 'TV4021');
      expect(client.isAuthenticated, isTrue);
      // /sites 404s in this fixture set, so it settles on legacy.
      expect(client.capabilities.siteManagement, isFalse);
    });

    test('the login body upper-cases the User ID', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(fixture('login'), 200);
      });
      final client =
          ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      await ApiAuthRepository(client)
          .signInWithCredentials(userId: ' tv4021 ', password: 'x');
      expect(sent['user_id'], 'TV4021');
    });
  });
}
