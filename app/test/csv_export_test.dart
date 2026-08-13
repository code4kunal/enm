import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/utils/csv_export.dart';

RegisterEntry entry({
  String registerId = 'work',
  Map<String, String> data = const <String, String>{'bus': 'MH40LY1894'},
  String by = 'R. Sharma / 4021',
}) {
  return RegisterEntry(
    id: 'e1',
    registerId: registerId,
    date: '2026-08-13',
    time: '07:40',
    site: 'MBMT',
    enteredBy: by,
    data: data,
  );
}

void main() {
  group('CsvExport.build', () {
    test('emits the handoff column order as the header row', () {
      final csv = CsvExport.build(<RegisterEntry>[]);
      expect(
        csv,
        'Register,Date,Site,Bus No,Details,Entered by',
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
