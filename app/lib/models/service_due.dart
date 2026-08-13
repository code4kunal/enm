import 'package:flutter/foundation.dart';

import 'site.dart';
import 'site_config.dart';

/// How urgent a service is.
enum DueStatus {
  /// Nothing to do yet.
  ok('OK'),

  /// Inside the site's reminder lead, by distance or by date.
  dueSoon('DUE SOON'),

  /// The interval has been passed.
  overdue('OVERDUE'),

  /// No usable odometer, so distance-driven plans cannot be judged.
  unknown('NO ODOMETER');

  const DueStatus(this.label);

  final String label;

  bool get needsAttention =>
      this == DueStatus.dueSoon || this == DueStatus.overdue;
}

/// When one vehicle's one service plan next falls due.
///
/// A service is due on whichever comes first, distance or elapsed time — the
/// way paid car servicing works — so both are computed and the worse one wins.
@immutable
class ServiceDue {
  const ServiceDue({
    required this.vehicle,
    required this.plan,
    required this.status,
    this.dueAtKm,
    this.kmRemaining,
    this.dueOn,
    this.daysRemaining,
  });

  final Vehicle vehicle;
  final ServicePlan plan;
  final DueStatus status;

  /// Odometer reading the service falls due at. Null for a time-only plan.
  final int? dueAtKm;

  /// Distance still to run. Negative means overdue by that much.
  final int? kmRemaining;

  /// `yyyy-MM-dd` the service falls due. Null for a distance-only plan.
  final String? dueOn;

  /// Days left. Negative means overdue by that many.
  final int? daysRemaining;

  bool get needsAttention => status.needsAttention;

  /// The shorter of the two runways, for sorting a work queue.
  ///
  /// Distance is converted at a nominal 200 km/day so km and days compare on
  /// one axis; it only has to order the list, not predict a date.
  int get urgencyScore {
    final byKm = kmRemaining == null ? null : (kmRemaining! ~/ 200);
    final byDays = daysRemaining;
    if (byKm == null) return byDays ?? 1 << 20;
    if (byDays == null) return byKm;
    return byKm < byDays ? byKm : byDays;
  }

  String get summary {
    final parts = <String>[
      if (kmRemaining != null)
        kmRemaining! >= 0
            ? 'in ${_thousands(kmRemaining!)} km'
            : '${_thousands(-kmRemaining!)} km over',
      if (daysRemaining != null)
        daysRemaining! >= 0
            ? 'in $daysRemaining days'
            : '${-daysRemaining!} days over',
    ];
    if (parts.isEmpty) return 'Not scheduled';
    return parts.join(' · ');
  }
}

/// Computes the maintenance queue for a site.
abstract final class ServiceSchedule {
  /// Every active plan against every active vehicle.
  ///
  /// A vehicle with no odometer reading yields [DueStatus.unknown] for
  /// distance-driven plans rather than being silently treated as at zero km —
  /// a stale telematics feed must be visible, not invisible.
  static List<ServiceDue> forSite({
    required List<Vehicle> vehicles,
    required SiteConfig config,
    required DateTime now,
  }) {
    final out = <ServiceDue>[];
    for (final vehicle in vehicles.where((v) => v.isActive)) {
      for (final plan in config.activePlans) {
        out.add(_evaluate(vehicle: vehicle, plan: plan, config: config, now: now));
      }
    }
    out.sort((a, b) => a.urgencyScore.compareTo(b.urgencyScore));
    return out;
  }

  /// Only the rows a manager has to act on.
  static List<ServiceDue> attentionOnly({
    required List<Vehicle> vehicles,
    required SiteConfig config,
    required DateTime now,
  }) =>
      forSite(vehicles: vehicles, config: config, now: now)
          .where((d) => d.needsAttention)
          .toList();

  static ServiceDue _evaluate({
    required Vehicle vehicle,
    required ServicePlan plan,
    required SiteConfig config,
    required DateTime now,
  }) {
    int? dueAtKm;
    int? kmRemaining;
    String? dueOn;
    int? daysRemaining;

    var status = DueStatus.ok;
    var distanceUsable = true;

    if (plan.isDistanceDriven) {
      if (!vehicle.hasOdometer) {
        distanceUsable = false;
      } else {
        // Anchor on the last service if there is one, otherwise on zero — a
        // vehicle that has never been serviced is due at its first interval.
        final anchor = vehicle.lastServiceKm ?? 0;
        dueAtKm = anchor + plan.intervalKm;
        kmRemaining = dueAtKm - vehicle.odometerKm;

        if (kmRemaining <= 0) {
          status = DueStatus.overdue;
        } else if (kmRemaining <= config.reminderLeadKm) {
          status = DueStatus.dueSoon;
        }
      }
    }

    if (plan.isTimeDriven) {
      // Anchor on the last service date, else the odometer's first sighting,
      // else today — the point is to start a clock, not to invent history.
      final anchor = _parseDate(vehicle.lastServiceOn) ??
          _parseDate(vehicle.odometerUpdatedAt) ??
          now;
      final due = anchor.add(Duration(days: plan.intervalDays));
      dueOn = _iso(due);
      daysRemaining = _wholeDaysBetween(now, due);

      final timeStatus = daysRemaining <= 0
          ? DueStatus.overdue
          : (daysRemaining <= config.reminderLeadDays
              ? DueStatus.dueSoon
              : DueStatus.ok);
      status = _worse(status, timeStatus);
    }

    // Only report "no odometer" when nothing else already demands attention.
    if (!distanceUsable && !status.needsAttention) {
      status = DueStatus.unknown;
    }

    return ServiceDue(
      vehicle: vehicle,
      plan: plan,
      status: status,
      dueAtKm: dueAtKm,
      kmRemaining: kmRemaining,
      dueOn: dueOn,
      daysRemaining: daysRemaining,
    );
  }

  static DueStatus _worse(DueStatus a, DueStatus b) {
    const rank = <DueStatus, int>{
      DueStatus.ok: 0,
      DueStatus.unknown: 1,
      DueStatus.dueSoon: 2,
      DueStatus.overdue: 3,
    };
    return rank[a]! >= rank[b]! ? a : b;
  }

  static DateTime? _parseDate(String? value) {
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  /// Calendar days between two instants, floored, ignoring the time of day so
  /// "due today" reads as 0 rather than a fraction.
  static int _wholeDaysBetween(DateTime from, DateTime to) {
    final a = DateTime(from.year, from.month, from.day);
    final b = DateTime(to.year, to.month, to.day);
    return b.difference(a).inDays;
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

String _thousands(int value) {
  final s = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
    buffer.write(s[i]);
  }
  return buffer.toString();
}
