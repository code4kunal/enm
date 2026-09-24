import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/data/registers.dart';
import 'package:transvolt_em/models/register.dart';

/// Locks the digitised columns to the physical registers. If a column is
/// renamed, reordered or dropped here, ground staff stop being able to read
/// down the screen the way they read down the page.
void main() {
  test('the four registers are present with their codes and colours', () {
    // PM Schedule Attention is deliberately absent: what it recorded is now an
    // inspection against its own checklist, and two places to write the same
    // thing is how a register stops being trusted.
    expect(kRegisters.map((r) => r.id).toList(), <String>[
      'work',
      'coolant',
      'complaint',
      'breakdown',
    ]);
    expect(kRegisters.map((r) => r.code).toList(), <String>[
      'WD',
      'CT',
      'DC',
      'BD',
    ]);
    expect(registerById('pm'), isNull);
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
        'Supervisor (Floor)',
      ],
    );
  });

  test('Coolant Topping records BCS and TCS in litres', () {
    final r = requireRegister('coolant');
    expect(r.field('bcs')?.unit, 'litres');
    expect(r.field('tcs')?.unit, 'litres');
    expect(r.field('bcs')?.type, FieldType.number);
  });

  test('Breakdown Report asks for the reported time plus Loss KM', () {
    final r = requireRegister('breakdown');
    expect(r.field('t_reported')?.type, FieldType.time);
    expect(r.field('t_reported')?.width, FieldWidth.half);
    expect(r.field('loss')?.unit, 'km');
  });

  test('Breakdown Report does not offer the server-computed attended time', () {
    // `t_att` is stamped when the first Work Done session is logged against
    // the breakdown's ticket, the same way `resolved_at` is stamped by
    // resolving it. The API accepts and ignores it, so an editable control
    // here would only collect a value the server throws away.
    expect(requireRegister('breakdown').field('t_att'), isNull);
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
