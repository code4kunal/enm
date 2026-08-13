import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/models/report.dart';
import 'package:transvolt_em/screens/reports/charts_pane.dart';
import 'package:transvolt_em/state/providers.dart';
import 'package:transvolt_em/state/reports.dart';
import 'package:transvolt_em/state/session.dart';
import 'package:transvolt_em/utils/dates.dart';

/// The wire shape the backend actually sends, kept verbatim: a control chart is
/// most of a screen of parsing, and a field renamed on the server has to fail
/// here rather than render as a month nobody serviced.
const Map<String, dynamic> _chartJson = <String, dynamic>{
  'kind': 'pmSchedule',
  'title': 'P.M schedule',
  'legend': 'The inspection attended. Dockings marked red.',
  'unit': '',
  'available': true,
  'unavailable_reason': '',
  'site_code': 'MBMT',
  'from_date': '2026-08-01',
  'to_date': '2026-08-03',
  'dates': <String>['2026-08-01', '2026-08-02', '2026-08-03'],
  'rows': <dynamic>[
    <String, dynamic>{
      'vehicle_id': 'v1',
      'registration_no': 'MH40LY1894',
      'cells': <dynamic>[
        <String, dynamic>{'value': 'D.I', 'mark': 'pm', 'title': 'D.I'},
        <String, dynamic>{'value': '', 'mark': 'plain'},
        <String, dynamic>{
          'value': '10D',
          'mark': 'docking',
          'title': '10 DAYS SERVICE',
        },
      ],
    },
    <String, dynamic>{
      'vehicle_id': 'v2',
      'registration_no': 'MH40LY1895',
      'cells': <dynamic>[
        <String, dynamic>{'value': '', 'mark': 'plain'},
        <String, dynamic>{'value': '', 'mark': 'plain'},
        <String, dynamic>{'value': '', 'mark': 'plain'},
      ],
    },
  ],
  'filled': 2,
};

const Map<String, dynamic> _energyJson = <String, dynamic>{
  'kind': 'energy',
  'title': 'kWh / km',
  'legend': 'Energy per kilometre.',
  'available': false,
  'unavailable_reason':
      'No energy feed. Nothing in the system records kWh or distance per bus '
          'per day.',
  'site_code': 'MBMT',
  'from_date': '2026-08-01',
  'to_date': '2026-08-03',
  'dates': <String>['2026-08-01'],
  'rows': <dynamic>[],
  'filled': 0,
};

/// Serves the two charts above and records what was asked for.
class _FakeReportRepository implements ReportRepository {
  String? lastKind;
  String? lastFrom;
  String? lastTo;

  @override
  Future<List<ChartKind>> fetchChartKinds() async => <ChartKind>[
        ChartKind.fromJson(Map<String, dynamic>.from(_chartJson)),
        ChartKind.fromJson(Map<String, dynamic>.from(_energyJson)),
      ];

  @override
  Future<ControlChart> fetchControlChart({
    required String siteCode,
    required String kind,
    required String fromDate,
    required String toDate,
  }) async {
    lastKind = kind;
    lastFrom = fromDate;
    lastTo = toDate;
    return ControlChart.fromJson(
      Map<String, dynamic>.from(kind == 'energy' ? _energyJson : _chartJson),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not under test');
}

ProviderContainer _container(_FakeReportRepository repo) {
  final container = ProviderContainer(
    overrides: <Override>[
      reportRepositoryProvider.overrideWithValue(repo),
    ],
  );
  container.read(sessionProvider.notifier).selectSite('MBMT');
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ChartsPane()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // The month heading is formatted en_IN, as it is in `main()`.
  setUpAll(() => initializeDateFormatting('en_IN'));

  group('parsing a control chart', () {
    test('reads the grid, the marks and the fill count', () {
      final chart = ControlChart.fromJson(
        Map<String, dynamic>.from(_chartJson),
      );

      expect(chart.title, 'P.M schedule');
      expect(chart.dates.length, 3);
      expect(chart.rows.length, 2);
      expect(chart.filled, 2);

      final first = chart.rows.first;
      expect(first.registrationNo, 'MH40LY1894');
      expect(first.cells[0].value, 'D.I');
      expect(first.cells[0].mark, CellMark.pm);
      expect(first.cells[1].isEmpty, isTrue);
      expect(first.cells[2].mark, CellMark.docking);
      // The block is shortened to fit; the code itself is still carried.
      expect(first.cells[2].value, '10D');
      expect(first.cells[2].title, '10 DAYS SERVICE');
    });

    test('an unknown mark falls back to plain rather than throwing', () {
      // A colour this client does not know is still a block worth drawing;
      // dropping the row would lose the bus.
      final cell = ChartCell.fromJson(<String, dynamic>{
        'value': '3',
        'mark': 'someFutureColour',
      });
      expect(cell.mark, CellMark.plain);
      expect(cell.value, '3');
    });

    test('a chart with no feed behind it carries its reason', () {
      final chart = ControlChart.fromJson(
        Map<String, dynamic>.from(_energyJson),
      );
      expect(chart.available, isFalse);
      expect(chart.unavailableReason, contains('No energy feed'));
      expect(chart.rows, isEmpty);
    });
  });

  group('the month window', () {
    test('the last day of a month is asked for, leap year included', () {
      expect(Dates.lastOfMonth('2026-08'), '2026-08-31');
      expect(Dates.lastOfMonth('2026-02'), '2026-02-28');
      expect(Dates.lastOfMonth('2028-02'), '2028-02-29');
      expect(Dates.lastOfMonth('2026-04'), '2026-04-30');
    });
  });

  group('the charts pane', () {
    testWidgets('asks for the whole month of the selected chart',
        (tester) async {
      final repo = _FakeReportRepository();
      final container = _container(repo);
      container.read(chartMonthProvider.notifier).state = '2026-08';
      addTearDown(container.dispose);

      await _pump(tester, container);

      expect(repo.lastKind, 'pmSchedule');
      expect(repo.lastFrom, '2026-08-01');
      expect(repo.lastTo, '2026-08-31');
    });

    testWidgets('draws every bus, including the ones with an empty row',
        (tester) async {
      final container = _container(_FakeReportRepository());
      addTearDown(container.dispose);

      await _pump(tester, container);

      // The bus with nothing recorded is the whole point of the grid.
      expect(find.text('MH40LY1894'), findsOneWidget);
      expect(find.text('MH40LY1895'), findsOneWidget);
      expect(find.text('D.I'), findsOneWidget);
      expect(find.text('10D'), findsOneWidget);
    });

    testWidgets('a chart with no feed shows the reason, not an empty grid',
        (tester) async {
      final container = _container(_FakeReportRepository());
      container.read(chartKindProvider.notifier).state = 'energy';
      addTearDown(container.dispose);

      await _pump(tester, container);

      expect(find.textContaining('No energy feed'), findsOneWidget);
      expect(find.text('Bus No'), findsNothing);
    });

    testWidgets('switching the chip switches the chart', (tester) async {
      final repo = _FakeReportRepository();
      final container = _container(repo);
      addTearDown(container.dispose);

      await _pump(tester, container);
      expect(repo.lastKind, 'pmSchedule');

      await tester.tap(find.text('kWh / km'));
      await tester.pumpAndSettle();

      expect(repo.lastKind, 'energy');
      expect(find.textContaining('No energy feed'), findsOneWidget);
    });
  });
}
