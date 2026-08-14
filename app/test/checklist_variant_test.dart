import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/checklist.dart';

/// Picking the checklist is the whole reason variants exist, and getting it
/// wrong means a mechanic is asked about AC cooling on a bus with no AC — or,
/// defaulted to OK as a daily inspection sensibly is, that a check nobody
/// performed lands in the maintenance record.
Checklist _list({String? variant, required List<String> labels}) =>
    Checklist.fromJson(<String, dynamic>{
      'id': 'c-${variant ?? 'none'}',
      'site_code': 'MBMT',
      'work_type_id': 1,
      'work_type_code': 'D.I',
      'work_type_name': 'Daily inspection',
      'name': 'Daily inspection',
      'variant': variant,
      'items': <dynamic>[
        for (final l in labels)
          <String, dynamic>{'id': '$variant-$l', 'label': l, 'section': ''},
      ],
    });

void main() {
  group('a checklist knows which buses take it', () {
    test('reads its variant off the wire', () {
      expect(_list(variant: '9M', labels: <String>['Horn']).variant, '9M');
      expect(_list(labels: <String>['Horn']).variant, isNull);
    });

    test('the unscoped list has no variant, which is not the same as ""', () {
      // A site running one checklist never sets a variant; that is the
      // fallback every bus lands on.
      final plain = _list(labels: <String>['Horn']);
      expect(plain.variant, isNull);
      expect(plain.variant ?? '', isEmpty);
    });

    test('carries the lines the depot wrote, in order', () {
      final nine = _list(
        variant: '9M',
        labels: <String>['Steering oil level', 'Driver fan check'],
      );
      expect(nine.items.map((i) => i.label).toList(), <String>[
        'Steering oil level',
        'Driver fan check',
      ]);
      expect(nine.isEmpty, isFalse);
    });

    test('an AC list asks about cooling and a 9M list does not', () {
      final ac = _list(
        variant: '12M AC',
        labels: <String>['Steering oil level', 'Check AC Cooling'],
      );
      final nine = _list(
        variant: '9M',
        labels: <String>['Steering oil level', 'Driver fan check'],
      );
      expect(ac.items.any((i) => i.label.contains('AC')), isTrue);
      expect(nine.items.any((i) => i.label.contains('AC')), isFalse);
    });

    test('an empty checklist is a real state and says so', () {
      expect(_list(variant: '9M', labels: <String>[]).isEmpty, isTrue);
    });
  });
}
