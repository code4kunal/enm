import 'package:intl/intl.dart';

/// The app stores dates as `yyyy-MM-dd` strings throughout: they sort and
/// compare lexically, which is exactly what the register period filters need,
/// and they round-trip to the API without timezone drift.
abstract final class Dates {
  static final _iso = DateFormat('yyyy-MM-dd');
  static final _clock = DateFormat('HH:mm');
  static final _long = DateFormat('EEE, d MMM yyyy', 'en_IN');

  /// `yyyy-MM-dd`, offset by [dayOffset] days from today.
  static String today([int dayOffset = 0]) =>
      _iso.format(DateTime.now().add(Duration(days: dayOffset)));

  static String iso(DateTime d) => _iso.format(d);

  static String nowClock() => _clock.format(DateTime.now());

  /// "Mon, 13 Aug 2026" — the date line on Home.
  static String longToday() => _long.format(DateTime.now());

  static DateTime? parse(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return null;
    return DateTime.tryParse(isoDate);
  }

  /// First day of the current month as `yyyy-MM`, for the "This month" filter.
  static String currentMonthPrefix() => today().substring(0, 7);

  /// Time-of-day greeting used on Home.
  static String greeting(String firstName) {
    final h = DateTime.now().hour;
    final part = h < 12
        ? 'Good morning'
        : h < 17
            ? 'Good afternoon'
            : 'Good evening';
    return '$part, $firstName';
  }

  /// Shift auto-pick by the clock: A before 14:00, B before 22:00, else C.
  static String currentShift() {
    final h = DateTime.now().hour;
    if (h < 14) return 'A';
    if (h < 22) return 'B';
    return 'C';
  }

  /// Elapsed time between two `HH:mm` stamps, wrapping across midnight.
  ///
  /// Returns `—` when either stamp is missing. A breakdown reported at 23:50
  /// and attended at 00:20 is 30 min, not minus 23 hours.
  static String elapsed(String? from, String? to) {
    final a = _minutes(from);
    final b = _minutes(to);
    if (a == null || b == null) return '—';
    var m = b - a;
    if (m < 0) m += 1440;
    final hours = m ~/ 60;
    final mins = m % 60;
    return hours > 0 ? '${hours}h ${mins}m' : '$mins min';
  }

  static int? _minutes(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return null;
    final parts = hhmm.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }
}
