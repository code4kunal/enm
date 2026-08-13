import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/report.dart';

/// The wire shapes the backend actually sends, kept verbatim: a renamed field
/// on the server has to fail here rather than render as a bus whose units were
/// never changed.
const Map<String, dynamic> _failureJson = <String, dynamic>{
  'id': 'fu1',
  'site_code': 'MBMT',
  'vehicle_id': 'v1',
  'registration_no': 'MH04LY1894',
  'unit_type_id': 9,
  'unit_name': 'Traction Motor',
  'unit_no': 'TM-99812',
  'fitted_on': '2026-07-01',
  'fitted_odometer_km': 100000,
  'removed_on': '2026-08-04',
  'removed_odometer_km': 142500,
  'kms_covered': 42500,
  'removal_reason': 'Bearing noise',
  'remarks': null,
  'is_fitted': false,
};

const Map<String, dynamic> _cardJson = <String, dynamic>{
  'site_code': 'MBMT',
  'vehicle_id': 'v1',
  'registration_no': 'MH04LY1894',
  'months': <String>['2026-06', '2026-07', '2026-08'],
  'rows': <dynamic>[
    <String, dynamic>{
      'unit_type_id': 1,
      'unit_name': 'Battery pack 1',
      'fitted_now': true,
      'cells': <dynamic>[
        <String, dynamic>{
          'kind': 'fitted',
          'label': '14',
          'unit_no': 'BP-1',
          'reason': '',
          'kms_covered': null,
        },
        null,
        null,
      ],
    },
    <String, dynamic>{
      'unit_type_id': 9,
      'unit_name': 'Traction Motor',
      'fitted_now': false,
      'cells': <dynamic>[
        null,
        null,
        <String, dynamic>{
          'kind': 'removed',
          'label': '04',
          'unit_no': 'TM-99812',
          'reason': 'Bearing noise',
          'kms_covered': 42500,
        },
      ],
    },
    <String, dynamic>{
      'unit_type_id': 30,
      'unit_name': 'Radiator',
      'fitted_now': false,
      'cells': <dynamic>[null, null, null],
    },
  ],
  'events': 2,
};

void main() {
  group('the Unit Failure Statement', () {
    test('reads a stay that has ended', () {
      final row = FittedUnit.fromJson(
        Map<String, dynamic>.from(_failureJson),
      );

      expect(row.registrationNo, 'MH04LY1894');
      expect(row.unitName, 'Traction Motor');
      expect(row.unitNo, 'TM-99812');
      expect(row.fittedOn, '2026-07-01');
      expect(row.removedOn, '2026-08-04');
      expect(row.kmsCovered, 42500);
      expect(row.removalReason, 'Bearing noise');
      expect(row.isFitted, isFalse);
    });

    test('an unknown life shows a dash, never a zero', () {
      // A nil in that column reads as a unit that failed the day it went on,
      // which is the opposite of "we do not know".
      final unknown = FittedUnit.fromJson(<String, dynamic>{
        ..._failureJson,
        'fitted_odometer_km': null,
        'removed_odometer_km': null,
        'kms_covered': null,
      });
      expect(unknown.kmsCovered, isNull);
      expect(unknown.kmsDisplay, '—');

      final known = FittedUnit.fromJson(
        Map<String, dynamic>.from(_failureJson),
      );
      expect(known.kmsDisplay, '42500');
    });

    test('a unit still on the bus has no removal', () {
      final fitted = FittedUnit.fromJson(<String, dynamic>{
        ..._failureJson,
        'removed_on': null,
        'removed_odometer_km': null,
        'kms_covered': null,
        'removal_reason': null,
        'is_fitted': true,
      });
      expect(fitted.isFitted, isTrue);
      expect(fitted.removedOn, isNull);
      expect(fitted.kmsDisplay, '—');
    });
  });

  group('the bus history card', () {
    test('reads the grid, its events and what is still fitted', () {
      final card = BusHistory.fromJson(Map<String, dynamic>.from(_cardJson));

      expect(card.registrationNo, 'MH04LY1894');
      expect(card.months.length, 3);
      expect(card.rows.length, 3);
      expect(card.events, 2);

      final pack = card.rows.first;
      expect(pack.fittedNow, isTrue);
      expect(pack.cells[0]!.kind, 'fitted');
      expect(pack.cells[0]!.label, '14');
      expect(pack.cells[1], isNull);

      final motor = card.rows[1];
      expect(motor.fittedNow, isFalse);
      expect(motor.cells[2]!.kind, 'removed');
      expect(motor.cells[2]!.reason, 'Bearing noise');
      expect(motor.cells[2]!.kmsCovered, 42500);
    });

    test('a unit never touched is still a row', () {
      // The empty rows are as much of the record as the filled ones — a card
      // is read to find what has *not* been changed as often as what has.
      final card = BusHistory.fromJson(Map<String, dynamic>.from(_cardJson));
      final radiator = card.rows.last;

      expect(radiator.unitName, 'Radiator');
      expect(radiator.cells.length, card.months.length);
      expect(radiator.cells.every((c) => c == null), isTrue);
    });

    test('an empty card is a real answer, not a missing one', () {
      final card = BusHistory.fromJson(<String, dynamic>{
        ..._cardJson,
        'rows': <dynamic>[],
        'events': 0,
      });
      expect(card.rows, isEmpty);
      expect(card.events, 0);
      expect(card.registrationNo, 'MH04LY1894');
    });
  });

  group('the unit master', () {
    test('carries the flag the DMR counts HV packs by', () {
      final pack = UnitType.fromJson(<String, dynamic>{
        'id': 1,
        'name': 'Battery pack 1',
        'sort_order': 0,
        'is_hv_battery': true,
      });
      final motor = UnitType.fromJson(<String, dynamic>{
        'id': 9,
        'name': 'Traction Motor',
        'sort_order': 8,
        'is_hv_battery': false,
      });

      expect(pack.isHvBattery, isTrue);
      expect(motor.isHvBattery, isFalse);
      expect(motor.sortOrder, 8);
    });
  });
}
