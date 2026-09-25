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
import 'package:transvolt_em/models/checklist.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/models/staff.dart';
import 'package:transvolt_em/models/ticket.dart';

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

    test('a resolved breakdown parses as EntryStatus.resolved, not done',
        () async {
      final mock = MockClient((http.Request request) async {
        final body = jsonDecode(fixture('entry_create')) as Map<String, dynamic>;
        body['status'] = 'resolved';
        return http.Response(
          jsonEncode(body), 200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      final entry = await ApiEntryRepository(client).createEntry(
        const RegisterEntry(
          id: '', registerId: 'breakdown', date: '2026-08-13', time: '09:29',
          site: 'MBMT', enteredBy: '', data: <String, String>{'bus': 'MH40LY1894'},
        ),
      );
      expect(entry.status, EntryStatus.resolved);
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
          't_reported': '06:50',
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

    test('work done ticket-link keys round-trip, including the attendee list', () {
      final wire = RegisterFieldMap.toWire('work', <String, String>{
        'ticketId': 't1',
        'completesTicket': 'true',
        'completionTime': '16:00',
        'attendeeUserIds': 'u1,u2',
      });
      expect(wire['ticket_id'], 't1');
      expect(wire['completes_ticket'], true);
      expect(wire['completion_time'], '16:00');
      expect(wire['attendee_user_ids'], <String>['u1', 'u2']);

      final back = RegisterFieldMap.fromWire('work', <String, dynamic>{
        'ticket_id': 't1',
        'completes_ticket': true,
        'completion_time': '16:00',
        'attendees': <dynamic>[
          <String, dynamic>{'user_id': 'u1', 'name': 'A'},
          <String, dynamic>{'user_id': 'u2', 'name': 'B'},
        ],
      });
      expect(back['ticketId'], 't1');
      expect(back['completesTicket'], 'true');
      expect(back['completionTime'], '16:00');
      expect(back['attendeeUserIds'], 'u1,u2');
    });

    test('employee is no longer a work-done field-map key', () {
      final wire = RegisterFieldMap.toWire('work', <String, String>{'employee': 'X'});
      expect(wire.containsKey('employee'), isFalse);
    });

    test('spares is no longer a work-done field-map key', () {
      final wire = RegisterFieldMap.toWire('work', <String, String>{'spares': 'X'});
      expect(wire.containsKey('spares'), isFalse);
    });

    test('work done spare part ids round-trip as a list', () {
      final wire = RegisterFieldMap.toWire('work', <String, String>{
        'sparePartIds': 'p1,p2',
      });
      expect(wire['spare_part_ids'], <String>['p1', 'p2']);

      final back = RegisterFieldMap.fromWire('work', <String, dynamic>{
        'spare_parts': <dynamic>[
          <String, dynamic>{'part_id': 'p1', 'part_no': 'SP-1', 'name': 'Filter'},
          <String, dynamic>{'part_id': 'p2', 'part_no': 'SP-2', 'name': 'Pad'},
        ],
      });
      expect(back['sparePartIds'], 'p1,p2');
    });

    test('spare part labels round-trip so a deactivated part still renders', () {
      // The directory (sparePartDirectoryProvider) is active-rows-only, so a
      // deactivated part's label can only come from the entry's own echo --
      // this is what the form falls back to for a selected id the directory
      // no longer carries.
      final back = RegisterFieldMap.fromWire('work', <String, dynamic>{
        'spare_parts': <dynamic>[
          <String, dynamic>{'part_id': 'p1', 'part_no': 'SP-1', 'name': 'Filter'},
        ],
      });
      expect(back['sparePartLabels'], 'p1|SP-1|Filter');
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
      final client = clientServing(<String, ({int status, String body})>{
        '/auth/login': (
          status: 401,
          body: jsonEncode(<String, dynamic>{
            'error': <String, String>{
              'code': 'UNAUTHORIZED',
              'message': 'Invalid User ID or password',
            },
          }),
        ),
      });

      await expectLater(
        ApiAuthRepository(client)
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
    test('login stores E&M tokens from the login response', () async {
      final client = clientServing(<String, ({int status, String body})>{
        '/auth/login': ok('login'),
      });

      final user = await ApiAuthRepository(client)
          .signInWithCredentials(userId: 'kunal', password: 'x');

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

      await ApiAuthRepository(client)
          .signInWithCredentials(userId: ' kunal ', password: 'x');
      expect(sent['user_id'], 'KUNAL');
    });
  });

  group('ticket search', () {
    test('a ticket search result parses onto TicketSearchResult', () async {
      final mock = MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<dynamic>[
            <String, dynamic>{
              'ticket_id': 't1',
              'title': 'HV contactor tripped · MH40LY1895',
              'entry_date': '2026-09-24',
              'status': 'open',
            },
          ]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client =
          ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      final List<TicketSearchResult> results =
          await ApiTicketRepository(client).search(site: 'MBMT');
      expect(results, hasLength(1));
      expect(results.first.title, contains('MH40LY1895'));
    });

    test('the register filter is sent as source_kind, in TicketSourceKind wire values', () async {
      // GET /tickets/search binds its filter to `source_kind`, a
      // `TicketSourceKind` enum -- a different vocabulary from the
      // `Register` enum entries use (a ticket's source can be an inspection
      // result with no register at all). Sending the old `register` key, or
      // an app id translated through the wrong map, is a silent no-op: the
      // backend just ignores an unrecognized query param.
      Map<String, String>? sent;
      final mock = MockClient((http.Request request) async {
        sent = request.url.queryParameters;
        return http.Response(
          '[]',
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final repo = ApiTicketRepository(
        ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock),
      );

      for (final entry in ticketSourceKindWire.entries) {
        await repo.search(site: 'MBMT', register: entry.key);
        expect(sent!.containsKey('register'), isFalse, reason: entry.key);
        expect(sent!['source_kind'], entry.value, reason: entry.key);
      }

      // No filter means no parameter at all — not an empty one.
      await repo.search(site: 'MBMT');
      expect(sent!.containsKey('source_kind'), isFalse);
    });
  });

  group('breakdown edit round trip', () {
    /// Everything `BreakdownData` on the server accepts as input. Anything
    /// else in a PUT body is a 400: the schema is `extra="forbid"`.
    const accepted = <String>{
      'bus_no',
      'defect_type',
      'driver_id',
      'route',
      'location',
      'complaint',
      'reported_time',
      'loss_km',
      'attended_details',
      'remarks',
      'supervisor',
      'attended_time',
      'resolved_at',
    };

    test('an attended breakdown writes back exactly what the server sent',
        () async {
      // The edit form is GET-then-PUT-the-whole-form-back. Once a Work Done
      // session has attended the ticket the server echoes a real
      // `attended_time`, and `_fromWire` puts it in the form's data — so the
      // PUT carries it whether or not any control is bound to it.
      final fetched = <String, dynamic>{
        'id': 'e1',
        'register': 'breakdown',
        'site': 'MBMT',
        'date': '2026-09-24',
        'entry_time': '06:50',
        'status': 'resolved',
        'created_by': <String, dynamic>{'id': 'u1', 'name': 'R. Sharma'},
        'data': <String, dynamic>{
          'bus_no': 'MH40LY1895',
          'defect_type': 'Electrical / HV',
          'driver_id': 'DRV221',
          'route': '7',
          'location': 'Kashimira signal',
          'complaint': 'HV contactor tripped',
          'reported_time': '06:50',
          'attended_time': '07:35',
          'loss_km': 18.5,
          'attended_details': 'Contactor replaced',
          'remarks': null,
          'supervisor': 'S. Pawar',
          'resolved_at': '2026-09-24T08:10:00+05:30',
        },
      };

      Map<String, dynamic>? put;
      final mock = MockClient((http.Request request) async {
        if (request.method == 'PUT') {
          put = jsonDecode(request.body) as Map<String, dynamic>;
        }
        return http.Response(
          jsonEncode(fetched),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final repo = ApiEntryRepository(
        ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock),
      );

      final entry = await repo.fetchEntry('e1');
      expect(entry.data['t_att'], '07:35', reason: 'still shown to the user');

      await repo.updateEntry(entry);
      final data = (put!['data'] as Map<String, dynamic>);
      // The assertion that would have caught it: every key the form writes
      // back has to be one the server's schema accepts.
      expect(
        data.keys.toSet().difference(accepted),
        isEmpty,
        reason: 'PUT sent a key BreakdownData forbids',
      );
      expect(data['attended_time'], '07:35');
      expect(data['reported_time'], '06:50');
    });
  });

  group('staff directory', () {
    test('staff directory keeps the id the backend returns', () async {
      final mock = MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{
                'id': 'u1',
                'name': 'S. Pawar',
                'user_id': 'TV4022',
                'role': 'executive',
              },
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      final staff = await ApiMasterDataRepository(client)
          .staffDirectory(siteCode: 'MBMT');
      expect(staff, hasLength(1));
      expect(staff.first.id, 'u1');
      expect(staff.first.name, 'S. Pawar');
    });
  });

  group('coolant day entry', () {
    test('a 2-row submission posts one request with both rows in the body',
        () async {
      late Map<String, dynamic> sent;
      final fixture1 = jsonDecode(fixture('entry_create')) as Map<String, dynamic>;
      final fixture2 = Map<String, dynamic>.of(fixture1)..['id'] = 'other-id';
      final mock = MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'items': <Map<String, dynamic>>[fixture1, fixture2],
          }),
          201,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      final created = await ApiEntryRepository(client).createCoolantDay(
        site: 'MBMT',
        entryDate: '2026-09-25',
        supervisor: 'R. Mehta',
        rows: <Map<String, dynamic>>[
          <String, dynamic>{'vehicle_id': 'v1', 'bcs_litres': '1.5'},
          <String, dynamic>{'vehicle_id': 'v2', 'bcs_litres': '2.0'},
        ],
      );

      expect(sent['entry_date'], '2026-09-25');
      expect(sent['supervisor'], 'R. Mehta');
      final rows = sent['rows'] as List<dynamic>;
      expect(rows, hasLength(2));
      expect((rows[0] as Map<String, dynamic>)['vehicle_id'], 'v1');
      expect((rows[1] as Map<String, dynamic>)['vehicle_id'], 'v2');
      expect(created, hasLength(2));
    });
  });

  group('spare parts directory', () {
    test('spare part directory keeps the id the backend returns', () async {
      final mock = MockClient((http.Request request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'items': <dynamic>[
              <String, dynamic>{'id': 'sp1', 'part_no': 'SP-1001', 'name': 'Brake pad set'},
            ],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      final parts = await ApiMasterDataRepository(client)
          .sparePartDirectory(siteCode: 'MBMT');
      expect(parts, hasLength(1));
      expect(parts.first.id, 'sp1');
      expect(parts.first.partNo, 'SP-1001');
      expect(parts.first.name, 'Brake pad set');
    });

    test('a work done submission posts spare_part_ids as a list', () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(fixture('entry_create'), 200);
      });
      final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      await ApiEntryRepository(client).createEntry(
        const RegisterEntry(
          id: '',
          registerId: 'work',
          date: '2026-09-25',
          time: '09:29',
          site: 'MBMT',
          enteredBy: '',
          data: <String, String>{
            'bus': 'MH40LY1894',
            'defects': 'AC not cooling',
            'sparePartIds': 'sp1,sp2',
          },
        ),
      );
      final data = sent['data'] as Map<String, dynamic>;
      expect(data['spare_part_ids'], <String>['sp1', 'sp2']);
    });
  });

  group('inspection result ticket linkage', () {
    test('ticket_id and ticket_status parse onto InspectionResult', () {
      final result = InspectionResult.fromJson(const <String, dynamic>{
        'item_id': 'it1',
        'result': 'not_ok',
        'remark': 'worn',
        'ticket_id': 't1',
        'ticket_status': 'open',
      });
      expect(result.ticketId, 't1');
      expect(result.ticketStatus, 'open');
    });

    test('a result with no ticket parses both as null', () {
      final result = InspectionResult.fromJson(const <String, dynamic>{
        'item_id': 'it1',
        'result': 'ok',
      });
      expect(result.ticketId, isNull);
      expect(result.ticketStatus, isNull);
    });
  });

  group('inspection batch', () {
    test('a batch submission posts every vehicle in one request body',
        () async {
      late Map<String, dynamic> sent;
      final mock = MockClient((http.Request request) async {
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'i1', 'site_code': 'MBMT', 'vehicle_id': 'v1',
                'registration_no': 'MH40LY1894', 'work_type_id': 1,
                'work_type_code': 'D.I', 'work_type_name': 'Daily inspection',
                'inspected_on': '2026-09-25', 'failed_count': 0,
                'results': <Map<String, dynamic>>[],
              },
              <String, dynamic>{
                'id': 'i2', 'site_code': 'MBMT', 'vehicle_id': 'v2',
                'registration_no': 'MH40LY1895', 'work_type_id': 1,
                'work_type_code': 'D.I', 'work_type_name': 'Daily inspection',
                'inspected_on': '2026-09-25', 'failed_count': 1,
                'results': <Map<String, dynamic>>[],
              },
            ],
          }),
          201,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);

      final entries = await ApiChecklistRepository(client).recordInspectionBatch(
        siteCode: 'MBMT',
        workTypeId: 1,
        inspectedOn: '2026-09-25',
        items: const <InspectionBatchItem>[
          InspectionBatchItem(
            vehicleId: 'v1',
            results: <InspectionResult>[
              InspectionResult(itemId: 'it1', result: CheckResult.ok),
            ],
          ),
          InspectionBatchItem(
            vehicleId: 'v2',
            results: <InspectionResult>[
              InspectionResult(itemId: 'it1', result: CheckResult.notOk, remark: 'worn'),
            ],
          ),
        ],
      );

      expect(sent['work_type_id'], 1);
      expect(sent['inspected_on'], '2026-09-25');
      final items = sent['items'] as List<dynamic>;
      expect(items, hasLength(2));
      expect((items[0] as Map<String, dynamic>)['vehicle_id'], 'v1');
      expect((items[1] as Map<String, dynamic>)['vehicle_id'], 'v2');
      expect(entries, hasLength(2));
      expect(entries[1].failedCount, 1);
    });
  });
}
