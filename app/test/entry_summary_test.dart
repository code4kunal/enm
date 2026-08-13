import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/state/entries.dart';

RegisterEntry entry(String registerId, Map<String, String> data) {
  return RegisterEntry(
    id: 'e1',
    registerId: registerId,
    date: '2026-08-13',
    time: '07:40',
    site: 'MBMT',
    enteredBy: 'R. Sharma / 4021',
    data: data,
  );
}

void main() {
  group('entrySummary', () {
    test('coolant reports both topping volumes', () {
      final e = entry('coolant', <String, String>{'bcs': '1.5', 'tcs': '0.5'});
      expect(entrySummary(e), 'BCS 1.5 L · TCS 0.5 L');
    });

    test('coolant defaults missing volumes to zero', () {
      final e = entry('coolant', <String, String>{'bcs': '2'});
      expect(entrySummary(e), 'BCS 2 L · TCS 0 L');
    });

    test('breakdown leads with location, then complaint, then action', () {
      final e = entry('breakdown', <String, String>{
        'loc': 'Kashimira signal',
        'complaint': 'No traction',
        'attended': 'Interlock reset',
      });
      expect(entrySummary(e), 'Kashimira signal — No traction · Interlock reset');
    });

    test('breakdown omits the action clause when nothing was done yet', () {
      final e = entry('breakdown', <String, String>{
        'loc': 'Mira Road',
        'complaint': 'Door 1 not closing',
      });
      expect(entrySummary(e), 'Mira Road — Door 1 not closing');
    });

    test('work pairs reported defects with attended details', () {
      final e = entry('work', <String, String>{
        'defects': 'AC not cooling',
        'attended': 'Fuse replaced',
      });
      expect(entrySummary(e), 'AC not cooling · Fuse replaced');
    });

    test('driver complaint falls back to complaint and action keys', () {
      final e = entry('complaint', <String, String>{
        'complaint': 'Wiper not clearing',
        'action': 'Blade replaced',
      });
      expect(entrySummary(e), 'Wiper not clearing · Blade replaced');
    });

    test('returns just the reported text when no action is recorded', () {
      final e = entry('pm', <String, String>{'defects': 'Brake pad wear'});
      expect(entrySummary(e), 'Brake pad wear');
    });

    test('survives a completely empty data map', () {
      expect(entrySummary(entry('work', <String, String>{})), '');
    });
  });
}
