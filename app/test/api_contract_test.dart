import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:transvolt_em/data/api/api_client.dart';
import 'package:transvolt_em/data/api/api_repositories.dart';
import 'package:transvolt_em/data/api/siteops_client.dart';
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

/// SiteOps client that always succeeds at credential login (contract tests).
SiteOpsClient siteOpsServingOk() {
  final mock = MockClient((http.Request request) async {
    if (request.url.path.endsWith('/auth/login')) {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'result': true,
          'data': <String, dynamic>{
            'access_token': 'siteops-token',
            'username': 'kunal',
            'full_name': 'Kunal Saxena',
          },
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 404);
  });
  return SiteOpsClient(
    baseUrl: 'https://siteops.test/api/v1',
    httpClient: mock,
  );
}

/// SiteOps client that rejects credential login.
SiteOpsClient siteOpsServingUnauthorized() {
  final mock = MockClient((http.Request request) async {
    return http.Response(
      jsonEncode(<String, dynamic>{'message': 'Invalid User ID or password'}),
      401,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  return SiteOpsClient(
    baseUrl: 'https://siteops.test/api/v1',
    httpClient: mock,
  );
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
        expect(e.enteredBy, 'Kunal Saxena');
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
      expect(sent['site'], 'MBMT');
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
          'route': '7',
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

      final supervisor = users.firstWhere((u) => u.userId == 'TV4102');
      expect(supervisor.name, 'Sanjay Pawar');
      expect(supervisor.role, UserRole.supervisor);
      expect(supervisor.sites, <String>['MBMT']);
      expect(supervisor.active, isTrue);
      // A null email means "no mail ID", not the string "null".
      expect(supervisor.email, '');
      expect(supervisor.canUseSso, isFalse);

      // The super admin carries no grants and still reaches everything.
      final admin = users.firstWhere((u) => u.userId == 'KUNAL');
      expect(admin.role, UserRole.superAdmin);
      expect(admin.sites, isEmpty);
      expect(admin.canAccess('MBMT'), isTrue);
      expect(admin.siteLabel, 'All sites');
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
    test('sites, vehicles and defect lists parse', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/sites': ok('sites'),
        '/sites/MBMT/vehicles': ok('vehicles'),
        '/master/defect-sources': ok('defect_sources'),
        '/master/defect-types': ok('defect_types'),
      });
      final master = ApiMasterDataRepository(client, SiteOpsClient());

      expect(await master.siteCodes(), <String>['MBMT']);
      expect(
        await master.vehicleNumbers(siteCode: 'MBMT'),
        contains('MH40LY1894'),
      );
      expect(await master.defectSources(), contains('Driver report'));
      expect(await master.defectTypes(), contains('Electrical / HV'));
    });

    test('the master lists come back as editable objects', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/master/defect-sources': ok('defect_sources'),
      });
      final items = await ApiMasterDataRepository(client, SiteOpsClient())
          .masterList(MasterListKind.defectSources);

      // Ids and flags are what the master-data editor needs; a bare string
      // list could not be edited or hidden.
      expect(items.first.id, isNotEmpty);
      expect(items.first.name, 'Driver report');
      expect(items.first.isActive, isTrue);
    });
  });

  group('site management', () {
    test('a site row carries its rollups', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/sites': ok('sites'),
      });
      final sites = await ApiSiteRepository(client).fetchSites();

      final site = sites.single;
      expect(site.code, 'MBMT');
      expect(site.isActive, isTrue);
      expect(site.vehicleCount, greaterThan(0));
    });

    test('a vehicle with no reading reports unknown, not 0 km', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/sites/MBMT/vehicles': ok('vehicles'),
      });
      final fleet =
          await ApiVehicleRepository(client).fetchVehicles(siteCode: 'MBMT');

      final never = fleet.firstWhere((v) => v.odometerUpdatedAt == null);
      expect(never.hasOdometer, isFalse);
    });

    test('the docking config parses its plans and shifts', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/sites/MBMT/config': ok('site_config'),
      });
      final config = await ApiSiteConfigRepository(client).fetchConfig('MBMT');

      expect(config.siteCode, 'MBMT');
      expect(config.servicePlans.map((p) => p.code), containsAll(<String>['S1', 'S2']));
      // The C shift wraps midnight, which the model has to survive.
      final c = config.shifts.firstWhere((s) => s.shift == 'C');
      expect(c.wrapsMidnight, isTrue);
      expect(config.isValid, isTrue);
    });
  });

  group('error mapping', () {
    test('the error envelope becomes a readable message', () async {
      // Credential login fails at SiteOps before any E&M call.
      final client = clientServing(<String, ({int status, String body})>{});

      await expectLater(
        ApiAuthRepository(client, siteOps: siteOpsServingUnauthorized())
            .signInWithCredentials(userId: 'KUNAL', password: 'nope'),
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
    test('login hits SiteOps then stores E&M tokens', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/auth/login': ok('login'),
      });
      late Uri siteOpsUri;
      final siteOpsMock = MockClient((http.Request request) async {
        siteOpsUri = request.url;
        expect(request.headers['content-type'],
            contains('application/x-www-form-urlencoded'));
        return http.Response(
          jsonEncode(<String, dynamic>{
            'result': true,
            'data': <String, dynamic>{'access_token': 'siteops-token'},
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final siteOps = SiteOpsClient(
        baseUrl: 'https://dev-siteops-platform.transvolt.org/api/v1',
        httpClient: siteOpsMock,
      );

      final user = await ApiAuthRepository(client, siteOps: siteOps)
          .signInWithCredentials(userId: 'kunal', password: 'x');

      expect(
        siteOpsUri.toString(),
        'https://dev-siteops-platform.transvolt.org/api/v1/auth/login',
      );
      expect(user.userId, 'KUNAL');
      expect(user.role, UserRole.superAdmin);
      // A super admin's site_access is empty and must stay empty — it reaches
      // every site without a stored grant.
      expect(user.sites, isEmpty);
      expect(user.canAccess('ANY-SITE'), isTrue);
      expect(client.isAuthenticated, isTrue);
    });

    test('the E&M login body upper-cases the User ID', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(fixture('login'), 200);
      });
      final client =
          ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      await ApiAuthRepository(client, siteOps: siteOpsServingOk())
          .signInWithCredentials(userId: ' kunal ', password: 'x');
      expect(sent['user_id'], 'KUNAL');
    });
  });
}
