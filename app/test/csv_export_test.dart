import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/utils/csv_export.dart';

RegisterEntry entry({
  String registerId = 'work',
  Map<String, String> data = const <String, String>{'bus': 'MH40LY1894'},
  String by = 'R. Sharma / 4021',
  String displayId = '',
  String? ticketStatus,
  String? ticketCompletedAt,
}) {
  return RegisterEntry(
    id: 'e1',
    registerId: registerId,
    date: '2026-08-13',
    time: '07:40',
    site: 'MBMT',
    enteredBy: by,
    data: data,
    displayId: displayId,
    ticketStatus: ticketStatus,
    ticketCompletedAt: ticketCompletedAt,
  );
}

/// The handoff columns, which AC-8 adds to rather than replaces.
const List<String> _originalColumns = <String>[
  'Register',
  'Date',
  'Site',
  'Bus No',
  'Details',
  'Entered by',
];

List<String> _header(String csv) => csv.split('\r\n').first.split(',');

/// Row [i] of the body. Only safe for fixtures with no embedded commas,
/// which is why the fixtures below avoid them.
List<String> _row(String csv, [int i = 0]) =>
    csv.split('\r\n')[i + 1].split(',');

/// The index of the one column whose heading matches [p] — the exact
/// headings are the implementer's call, their presence and content is not.
int _column(String csv, Pattern p) {
  final matches = _header(csv).where((c) => c.contains(p)).toList();
  expect(matches, hasLength(1), reason: 'header: ${_header(csv)}');
  return _header(csv).indexOf(matches.single);
}

void main() {
  group('CsvExport.build', () {
    test('test_ac8_header_keeps_the_handoff_columns_and_adds_two', () {
      final csv = CsvExport.build(<RegisterEntry>[]);
      final header = _header(csv);

      // The handoff columns stay, unmoved and in order — ground staff read
      // down these the way they read down the page, and every other test in
      // this file pins that layout.
      expect(header.take(_originalColumns.length).toList(), _originalColumns);
      // …with the entry's own display id and the ticket-lifecycle summary
      // appended after them.
      expect(header, hasLength(_originalColumns.length + 2));
      expect(_column(csv, RegExp('ID', caseSensitive: false)), isNonNegative);
      expect(
        _column(csv, RegExp('Ticket', caseSensitive: false)),
        isNonNegative,
      );
    });

    test('test_ac8_row_carries_the_entry_display_id', () {
      final csv = CsvExport.build(<RegisterEntry>[
        entry(
          registerId: 'breakdown',
          displayId: 'BD-2026-000002',
          data: const <String, String>{
            'bus': 'MH40LY1894',
            'complaint': 'HV contactor tripped',
          },
        ),
      ]);
      expect(_row(csv)[_column(csv, RegExp('ID', caseSensitive: false))],
          'BD-2026-000002');
    });

    test('test_ac8_row_summarises_a_completed_ticket_with_its_date', () {
      final csv = CsvExport.build(<RegisterEntry>[
        entry(
          registerId: 'breakdown',
          displayId: 'BD-2026-000002',
          ticketStatus: 'completed',
          ticketCompletedAt: '2026-09-29',
          data: const <String, String>{
            'bus': 'MH40LY1894',
            'complaint': 'HV contactor tripped',
          },
        ),
      ]);
      expect(
        _row(csv)[_column(csv, RegExp('Ticket', caseSensitive: false))],
        matches(RegExp(r'^Completed.*2026-09-29$')),
      );
    });

    test('test_ac8_row_summarises_an_open_ticket', () {
      final csv = CsvExport.build(<RegisterEntry>[
        entry(
          registerId: 'complaint',
          displayId: 'DC-2026-000004',
          ticketStatus: 'open',
          data: const <String, String>{
            'bus': 'MH40LY1894',
            'complaint': 'AC not cooling',
          },
        ),
      ]);
      expect(
        _row(csv)[_column(csv, RegExp('Ticket', caseSensitive: false))],
        'Open',
      );
    });

    test('test_ac8_a_register_that_cannot_carry_a_ticket_exports_blank', () {
      // work_done is never a ticket's source, so ticketStatus is null —
      // the column degrades to blank rather than inventing a state.
      final csv = CsvExport.build(<RegisterEntry>[
        entry(displayId: 'WD-2026-000011'),
      ]);
      expect(
        _row(csv)[_column(csv, RegExp('Ticket', caseSensitive: false))],
        '',
      );
      expect(_row(csv)[_column(csv, RegExp('ID', caseSensitive: false))],
          'WD-2026-000011');
    });

    test('test_ac8_a_ticketable_entry_with_no_ticket_yet_exports_blank', () {
      // Same null, different reason (nobody has raised one) — the column
      // can't tell the two apart and doesn't need to.
      final csv = CsvExport.build(<RegisterEntry>[
        entry(
          registerId: 'coolant',
          displayId: 'CT-2026-000007',
          data: const <String, String>{'bus': 'MH40LY1894', 'bcs': '2'},
        ),
      ]);
      expect(
        _row(csv)[_column(csv, RegExp('Ticket', caseSensitive: false))],
        '',
      );
    });

    test('test_ac8_an_entry_that_never_round_tripped_exports_a_blank_id', () {
      // displayId is '' for a locally built entry; no crash, no "null".
      final csv = CsvExport.build(<RegisterEntry>[entry()]);
      expect(
        _row(csv)[_column(csv, RegExp('ID', caseSensitive: false))],
        '',
      );
    });

    test('writes one CRLF-delimited row per entry', () {
      final csv = CsvExport.build(<RegisterEntry>[entry(), entry()]);
      expect(csv.split('\r\n'), hasLength(3));
    });

    test('resolves the register id to its display name', () {
      final csv = CsvExport.build(<RegisterEntry>[entry()]);
      expect(csv, contains('Daily Work Done,2026-08-13,MBMT,MH40LY1894'));
    });

    test('quotes fields containing commas', () {
      final csv = CsvExport.build(<RegisterEntry>[
        entry(data: <String, String>{
          'bus': 'MH40LY1894',
          'defects': 'AC not cooling, noise from axle',
        }),
      ]);
      expect(csv, contains('"AC not cooling, noise from axle"'));
    });

    test('doubles embedded quotes', () {
      final csv = CsvExport.build(<RegisterEntry>[
        entry(data: <String, String>{
          'bus': 'MH40LY1894',
          'defects': 'Driver said "no power"',
        }),
      ]);
      expect(csv, contains('"Driver said ""no power"""'));
    });

    test('quotes fields containing newlines so rows stay intact', () {
      final csv = CsvExport.build(<RegisterEntry>[
        entry(data: <String, String>{
          'bus': 'MH40LY1894',
          'defects': 'line one\nline two',
        }),
      ]);
      expect(csv, contains('"line one\nline two"'));
      // Header + a single logical row, despite the embedded newline.
      expect(csv.split('\r\n'), hasLength(2));
    });

    test('leaves plain fields unquoted', () {
      final csv = CsvExport.build(<RegisterEntry>[
        entry(data: <String, String>{'bus': 'MH40LY1894', 'defects': 'AC fault'}),
      ]);
      expect(csv, contains(',AC fault,'));
    });
  });

  group('CsvExport.fileName', () {
    test('is site-scoped and lowercase', () {
      expect(CsvExport.fileName('MBMT'), 'transvolt-em-register-mbmt.csv');
    });
  });
}
