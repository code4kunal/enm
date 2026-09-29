import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:transvolt_em/data/api/api_client.dart';
import 'package:transvolt_em/data/api/api_repositories.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/models/ticket.dart';

/// The wire seam for the two new server-side fields.
///
/// Kept out of `api_contract_test.dart` only because these fields do not
/// exist yet; the shape below is what `EntryOut` / `TicketSearchResult`
/// serialise (see the backend tests of the same name).
ApiClient _serving(Object body) {
  final mock = MockClient((http.Request request) async {
    return http.Response(
      jsonEncode(body),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  });
  return ApiClient(baseUrl: 'http://api.test/api/v1', httpClient: mock);
}

Map<String, dynamic> _entryJson({
  String? ticketStatus,
  String? ticketCompletedAt,
}) =>
    <String, dynamic>{
      'id': 'e1',
      'display_id': 'BD-2026-000002',
      'register': 'breakdown',
      'site': 'MBMT',
      'date': '2026-09-29',
      'entry_time': '14:45',
      'entered_by': 'Rahul Sharma (TV4021)',
      'created_by': <String, dynamic>{
        'id': 'u1',
        'name': 'Rahul Sharma',
        'user_id': 'TV4021',
      },
      'created_at': '2026-09-29T14:45:00+05:30',
      'updated_at': null,
      'status': 'open',
      'data': <String, dynamic>{
        'bus_no': 'MH40LY1894',
        'complaint': 'HV contactor tripped',
        'reported_time': '14:45',
      },
      'photos': <dynamic>[],
      'ticket_status': ticketStatus,
      'ticket_completed_at': ticketCompletedAt,
    };

void main() {
  group('entry list parsing', () {
    test('test_ac8_ticket_status_and_completion_date_parse_off_the_list', () {
      // The CSV export reads the *list* fetch, so these have to survive it —
      // linked_sessions never does (detail route only).
      final client = _serving(<String, dynamic>{
        'items': <dynamic>[
          _entryJson(ticketStatus: 'completed', ticketCompletedAt: '2026-09-29'),
        ],
        'total': 1,
      });

      return ApiEntryRepository(client)
          .fetchEntries(site: 'MBMT')
          .then((List<RegisterEntry> entries) {
        expect(entries, hasLength(1));
        expect(entries.first.ticketStatus, 'completed');
        expect(entries.first.ticketCompletedAt, '2026-09-29');
        expect(entries.first.displayId, 'BD-2026-000002');
      });
    });

    test('test_ac8_a_null_ticket_status_parses_as_null_not_a_string', () {
      final client = _serving(<String, dynamic>{
        'items': <dynamic>[_entryJson()],
        'total': 1,
      });

      return ApiEntryRepository(client)
          .fetchEntries(site: 'MBMT')
          .then((List<RegisterEntry> entries) {
        expect(entries.first.ticketStatus, isNull);
        expect(entries.first.ticketCompletedAt, isNull);
      });
    });
  });

  group('ticket search parsing', () {
    test('test_ac4_defect_type_parses_onto_the_search_result', () async {
      final client = _serving(<dynamic>[
        <String, dynamic>{
          'ticket_id': 't1',
          'title': 'HV contactor tripped · MH40LY1895',
          'entry_date': '2026-09-29',
          'status': 'open',
          'source_kind': 'breakdown',
          'bus_no': 'MH40LY1895',
          'defect_text': 'HV contactor tripped',
          'defect_type': 'Electrical / HV',
        },
      ]);

      final List<TicketSearchResult> results =
          await ApiTicketRepository(client).search(site: 'MBMT');
      expect(results.first.defectType, 'Electrical / HV');
    });

    test('test_ac4_a_ticket_with_no_defect_type_parses_as_null', () async {
      final client = _serving(<dynamic>[
        <String, dynamic>{
          'ticket_id': 't1',
          'title': 'Brake check · MH40LY1894',
          'entry_date': '2026-09-29',
          'status': 'open',
          'source_kind': 'daily_inspection',
        },
      ]);

      final List<TicketSearchResult> results =
          await ApiTicketRepository(client).search(site: 'MBMT');
      expect(results.first.defectType, isNull);
    });
  });
}
