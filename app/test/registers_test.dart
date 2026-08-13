import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/data/registers.dart';
import 'package:transvolt_em/models/register.dart';

/// Locks the digitised columns to the physical registers. If a column is
/// renamed, reordered or dropped here, ground staff stop being able to read
/// down the screen the way they read down the page.
void main() {
  test('all five registers are present with their codes and colours', () {
    expect(kRegisters.map((r) => r.id).toList(), <String>[
      'work',
      'coolant',
      'complaint',
      'breakdown',
      'pm',
    ]);
    expect(kRegisters.map((r) => r.code).toList(), <String>[
      'WD',
      'CT',
      'DC',
      'BD',
      'PM',
    ]);
  });

  test('Daily Work Done columns match the paper register', () {
    expect(
      requireRegister('work').fields.map((f) => f.label).toList(),
      <String>[
        'Shift',
        'Date',
        'Bus No',
        'Reported Defects',
        'Source of Defect',
        'Type of Defect',
        'Attended Details',
        'Spare Parts Used',
        'Name & No. of Employee',
      ],
    );
  });

  test('Coolant Topping records BCS and TCS in litres', () {
    final r = requireRegister('coolant');
    expect(r.field('bcs')?.unit, 'litres');
    expect(r.field('tcs')?.unit, 'litres');
    expect(r.field('bcs')?.type, FieldType.number);
  });

  test('Breakdown Report carries all three time stamps plus Loss KM', () {
    final r = requireRegister('breakdown');
    for (final key in <String>['t_bd', 't_mech', 't_att']) {
      expect(r.field(key)?.type, FieldType.time, reason: key);
      // The triplet shares one row on desktop.
      expect(r.field(key)?.width, FieldWidth.third, reason: key);
    }
    expect(r.field('loss')?.unit, 'km');
  });

  test('PM Schedule Attention captures the balance-job reason', () {
    expect(requireRegister('pm').field('balance')?.label,
        'Reason for Balance Job (if any)');
  });

  test('every register requires Date and Bus No', () {
    for (final r in kRegisters) {
      expect(r.field('date')?.required, isTrue, reason: r.name);
      expect(r.field('bus')?.required, isTrue, reason: r.name);
      expect(r.field('bus')?.type, FieldType.bus, reason: r.name);
    }
  });

  test('bus fields are implicitly master-backed', () {
    for (final r in kRegisters) {
      expect(r.field('bus')?.isMasterBacked, isTrue, reason: r.name);
    }
  });

  test('every select field names a master list to draw from', () {
    for (final r in kRegisters) {
      for (final f in r.fields.where((f) => f.type == FieldType.select)) {
        expect(f.optionsFrom, isNotNull, reason: '${r.name}/${f.key}');
        expect(f.master, isTrue, reason: '${r.name}/${f.key}');
      }
    }
  });

  test('the shift segment offers exactly A, B and C', () {
    expect(
      requireRegister('work').field('shift')?.segOptions,
      <String>['A', 'B', 'C'],
    );
  });

  test('registerById returns null for an unknown id', () {
    expect(registerById('nope'), isNull);
    expect(() => requireRegister('nope'), throwsArgumentError);
  });
}
