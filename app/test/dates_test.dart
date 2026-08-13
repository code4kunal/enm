import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/utils/dates.dart';

void main() {
  group('Dates.elapsed', () {
    test('computes a same-day gap', () {
      expect(Dates.elapsed('06:32', '07:35'), '1h 3m');
    });

    test('renders sub-hour gaps in minutes', () {
      expect(Dates.elapsed('13:58', '14:20'), '22 min');
    });

    test('wraps across midnight instead of going negative', () {
      // A breakdown at 23:50 attended at 00:20 is 30 minutes, not -23h.
      expect(Dates.elapsed('23:50', '00:20'), '30 min');
    });

    test('returns a dash when either stamp is missing', () {
      expect(Dates.elapsed(null, '07:35'), '—');
      expect(Dates.elapsed('06:32', null), '—');
      expect(Dates.elapsed('', ''), '—');
    });

    test('returns a dash for malformed stamps', () {
      expect(Dates.elapsed('not-a-time', '07:35'), '—');
    });

    test('treats identical stamps as zero', () {
      expect(Dates.elapsed('09:00', '09:00'), '0 min');
    });
  });

  group('Dates.today', () {
    test('formats as yyyy-MM-dd', () {
      expect(Dates.today(), matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('offsets backwards and sorts lexically', () {
      // Lexical ordering is what the period filters rely on.
      expect(Dates.today(-7).compareTo(Dates.today()), lessThan(0));
    });
  });

  group('Dates.currentShift', () {
    test('picks a valid shift for the current clock', () {
      expect(<String>['A', 'B', 'C'], contains(Dates.currentShift()));
    });
  });
}
