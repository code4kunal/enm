import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:transvolt_em/data/api/api_client.dart';
import 'package:transvolt_em/data/api/api_repositories.dart';
import 'package:transvolt_em/data/repositories.dart';

/// The four bytes every PDF starts with. Asserting on them is what separates
/// "the server sent a file" from "the server sent a JSON error the client then
/// handed to a share sheet".
final Uint8List _pdf = Uint8List.fromList(
  utf8.encode('%PDF-1.4\nfake\n%%EOF'),
);

ApiClient _clientReturning(
  Uint8List body, {
  required void Function(http.Request) onRequest,
  int status = 200,
}) {
  return ApiClient(
    baseUrl: 'http://test/api/v1',
    httpClient: MockClient((request) async {
      onRequest(request);
      return http.Response.bytes(
        body,
        status,
        headers: <String, String>{'content-type': 'application/pdf'},
      );
    }),
  );
}

void main() {
  group('downloading a report', () {
    test('the day reports carry the date', () async {
      late Uri seen;
      final repo = ApiReportRepository(
        _clientReturning(_pdf, onRequest: (r) => seen = r.url),
      );

      final file = await repo.downloadReport(
        ReportDoc.dmrDay,
        siteCode: 'MBMT',
        date: '2026-08-05',
      );

      expect(seen.path, '/api/v1/sites/MBMT/reports/dmr/day/export');
      expect(seen.queryParameters['date'], '2026-08-05');
      expect(file.bytes.sublist(0, 4), utf8.encode('%PDF'));
      expect(file.name, 'mbmt-dmr-2026-08-05.pdf');
    });

    test('the month reports ask for pdf, since csv is the default', () async {
      late Uri seen;
      final repo = ApiReportRepository(
        _clientReturning(_pdf, onRequest: (r) => seen = r.url),
      );

      await repo.downloadReport(
        ReportDoc.dmrMonth,
        siteCode: 'MBMT',
        month: '2026-08',
      );

      expect(seen.path, '/api/v1/sites/MBMT/reports/dmr/export');
      expect(seen.queryParameters['month'], '2026-08');
      expect(seen.queryParameters['format'], 'pdf');
    });

    test('the month report can ask for excel instead', () async {
      late Uri seen;
      final repo = ApiReportRepository(
        _clientReturning(_pdf, onRequest: (r) => seen = r.url),
      );

      final file = await repo.downloadReport(
        ReportDoc.dmrMonth,
        siteCode: 'MBMT',
        month: '2026-08',
        format: 'xlsx',
      );

      expect(seen.queryParameters['format'], 'xlsx');
      expect(file.name, 'mbmt-dmr-month-2026-08.xlsx');
    });

    test('a control chart carries its kind and its window', () async {
      late Uri seen;
      final repo = ApiReportRepository(
        _clientReturning(_pdf, onRequest: (r) => seen = r.url),
      );

      await repo.downloadReport(
        ReportDoc.controlChart,
        siteCode: 'MBMT',
        chartKind: 'pmSchedule',
        fromDate: '2026-08-01',
        toDate: '2026-08-31',
      );

      expect(
        seen.path,
        '/api/v1/sites/MBMT/reports/control-charts/pmSchedule/export',
      );
      expect(seen.queryParameters['from'], '2026-08-01');
      expect(seen.queryParameters['to'], '2026-08-31');
      expect(seen.queryParameters['format'], 'pdf');
    });

    test('a bus history card is scoped to one bus', () async {
      late Uri seen;
      final repo = ApiReportRepository(
        _clientReturning(_pdf, onRequest: (r) => seen = r.url),
      );

      await repo.downloadReport(
        ReportDoc.busHistory,
        siteCode: 'MBMT',
        vehicleId: 'v1',
        month: '2026-08',
      );

      expect(seen.path, '/api/v1/sites/MBMT/reports/bus-history/v1/export');
      expect(seen.queryParameters['to'], '2026-08');
    });

    test('every report has a route', () async {
      // A new ReportDoc with no branch would throw here rather than at a
      // depot's desk.
      for (final doc in ReportDoc.values) {
        final repo = ApiReportRepository(
          _clientReturning(_pdf, onRequest: (_) {}),
        );
        final file = await repo.downloadReport(
          doc,
          siteCode: 'MBMT',
          date: '2026-08-05',
          month: '2026-08',
          chartKind: 'pmSchedule',
          fromDate: '2026-08-01',
          toDate: '2026-08-31',
          vehicleId: 'v1',
        );
        expect(file.name, endsWith('.pdf'), reason: '$doc');
        expect(file.bytes, isNotEmpty, reason: '$doc');
      }
    });

    test('a failure surfaces as an error, not as an empty file', () async {
      final repo = ApiReportRepository(
        ApiClient(
          baseUrl: 'http://test/api/v1',
          httpClient: MockClient(
            (_) async => http.Response(
              '{"error":{"code":"NOT_FOUND","message":"Vehicle not found"}}',
              404,
              headers: <String, String>{'content-type': 'application/json'},
            ),
          ),
        ),
      );

      await expectLater(
        repo.downloadReport(
          ReportDoc.busHistory,
          siteCode: 'MBMT',
          vehicleId: 'nope',
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
