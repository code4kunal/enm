import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/service_due.dart';
import 'package:transvolt_em/models/site.dart';
import 'package:transvolt_em/models/site_config.dart';

SiteConfig config({
  List<ServicePlan>? plans,
  int reminderLeadKm = 500,
  int reminderLeadDays = 7,
  int slotMinutes = 120,
  int maxInService = 2,
  int syncMinutes = 60,
}) {
  return SiteConfig(
    siteCode: 'MBMT',
    servicePlans: plans ??
        const <ServicePlan>[
          ServicePlan(
            code: 'S1',
            name: 'Minor service',
            intervalKm: 10000,
            intervalDays: 90,
          ),
        ],
    reminderLeadKm: reminderLeadKm,
    reminderLeadDays: reminderLeadDays,
    dockingSlotMinutes: slotMinutes,
    maxVehiclesInService: maxInService,
    odometerSync: OdometerSync(intervalMinutes: syncMinutes),
  );
}

Vehicle vehicle({
  String reg = 'MH40LY0001',
  int odo = 5000,
  int? lastKm = 0,
  String? lastOn,
  bool synced = true,
  bool active = true,
}) {
  return Vehicle(
    id: reg,
    registrationNo: reg,
    siteCode: 'MBMT',
    isActive: active,
    odometerKm: odo,
    odometerUpdatedAt: synced ? '2026-08-13T09:00:00Z' : null,
    lastServiceKm: lastKm,
    lastServiceOn: lastOn,
  );
}

final DateTime now = DateTime(2026, 8, 13);

String daysAgo(int days) {
  final d = now.subtract(Duration(days: days));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

void main() {
  group('ServicePlan', () {
    test('a plan needs at least one interval to ever fall due', () {
      const none = ServicePlan(
        code: 'X',
        name: 'X',
        intervalKm: 0,
        intervalDays: 0,
      );
      expect(none.isSchedulable, isFalse);
      expect(none.intervalLabel, 'Not scheduled');
    });

    test('labels both intervals when both are set', () {
      const both = ServicePlan(
        code: 'S1',
        name: 'Minor',
        intervalKm: 10000,
        intervalDays: 90,
      );
      expect(both.intervalLabel, '10,000 km / 90 days');
    });

    test('a distance-only plan says so', () {
      const km = ServicePlan(
        code: 'S1',
        name: 'Minor',
        intervalKm: 15000,
        intervalDays: 0,
      );
      expect(km.intervalLabel, '15,000 km');
      expect(km.isTimeDriven, isFalse);
    });
  });

  group('config derived figures', () {
    test('shortest interval picks the smallest active distance plan', () {
      final c = config(
        plans: const <ServicePlan>[
          ServicePlan(code: 'S3', name: 'Major', intervalKm: 40000, intervalDays: 0),
          ServicePlan(code: 'S1', name: 'Minor', intervalKm: 10000, intervalDays: 0),
        ],
      );
      expect(c.shortestIntervalKm, 10000);
    });

    test('a paused plan is not counted', () {
      final c = config(
        plans: const <ServicePlan>[
          ServicePlan(
            code: 'S1',
            name: 'Minor',
            intervalKm: 10000,
            intervalDays: 0,
            isActive: false,
          ),
          ServicePlan(code: 'S3', name: 'Major', intervalKm: 40000, intervalDays: 0),
        ],
      );
      expect(c.activePlans, hasLength(1));
      expect(c.shortestIntervalKm, 40000);
    });

    test('bay throughput follows the slot length', () {
      expect(config(slotMinutes: 120).servicesPerBayPerDay, 12);
      expect(config(slotMinutes: 0).servicesPerBayPerDay, 0);
    });

    test('planByCode is case-insensitive', () {
      expect(config().planByCode('s1')?.name, 'Minor service');
      expect(config().planByCode('nope'), isNull);
    });
  });

  group('config validation', () {
    test('a coherent config passes', () {
      expect(config().validationIssues, isEmpty);
    });

    test('no schedulable plan is caught', () {
      final c = config(plans: const <ServicePlan>[]);
      expect(c.validationIssues.first, contains('nothing will ever fall due'));
    });

    test('duplicate plan codes are caught', () {
      final c = config(
        plans: const <ServicePlan>[
          ServicePlan(code: 'S1', name: 'A', intervalKm: 10000, intervalDays: 0),
          ServicePlan(code: 's1', name: 'B', intervalKm: 20000, intervalDays: 0),
        ],
      );
      expect(c.validationIssues.any((i) => i.contains('same code')), isTrue);
    });

    test('a blank plan code is caught', () {
      final c = config(
        plans: const <ServicePlan>[
          ServicePlan(code: '  ', name: 'A', intervalKm: 10000, intervalDays: 0),
        ],
      );
      expect(c.validationIssues.any((i) => i.contains('needs a code')), isTrue);
    });

    test('a reminder lead longer than its interval is caught', () {
      final c = config(reminderLeadKm: 12000);
      expect(
        c.validationIssues.any((i) => i.contains('always read as due')),
        isTrue,
      );
    });

    test('a time reminder lead longer than its interval is caught', () {
      final c = config(reminderLeadDays: 120);
      expect(
        c.validationIssues.any((i) => i.contains('always read as due')),
        isTrue,
      );
    });

    test('an odometer sync faster than 5 minutes is rejected', () {
      expect(
        config(syncMinutes: 1)
            .validationIssues
            .any((i) => i.contains('5 minutes')),
        isTrue,
      );
    });
  });

  group('OdometerSync', () {
    test('clamps the interval to a sane range', () {
      expect(const OdometerSync(intervalMinutes: 1).interval.inMinutes, 5);
      expect(const OdometerSync(intervalMinutes: 5000).interval.inHours, 24);
      expect(const OdometerSync(intervalMinutes: 30).interval.inMinutes, 30);
    });
  });

  group('service due', () {
    test('a fresh vehicle well inside its interval is OK', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(odo: 2000, lastKm: 0, lastOn: daysAgo(5))],
        config: config(),
        now: now,
      );
      expect(due.single.status, DueStatus.ok);
      expect(due.single.kmRemaining, 8000);
    });

    test('inside the distance reminder lead reads as due soon', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(odo: 9700, lastKm: 0, lastOn: daysAgo(5))],
        config: config(reminderLeadKm: 500),
        now: now,
      );
      expect(due.single.status, DueStatus.dueSoon);
      expect(due.single.kmRemaining, 300);
    });

    test('past the interval reads as overdue, with how far over', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(odo: 11200, lastKm: 0, lastOn: daysAgo(5))],
        config: config(),
        now: now,
      );
      expect(due.single.status, DueStatus.overdue);
      expect(due.single.kmRemaining, -1200);
      expect(due.single.summary, contains('1,200 km over'));
    });

    test('time can make a service due even with distance to spare', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(odo: 1000, lastKm: 0, lastOn: daysAgo(95))],
        config: config(),
        now: now,
      );
      // 95 days since the last service against a 90-day interval.
      expect(due.single.status, DueStatus.overdue);
      expect(due.single.daysRemaining, lessThan(0));
      expect(due.single.kmRemaining, 9000);
    });

    test('the worse of the two runways wins', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(odo: 9800, lastKm: 0, lastOn: daysAgo(1))],
        config: config(reminderLeadKm: 500),
        now: now,
      );
      // Comfortable on time, due soon on distance.
      expect(due.single.status, DueStatus.dueSoon);
    });

    test('anchors on the last service, not on zero', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[
          vehicle(odo: 45000, lastKm: 40000, lastOn: daysAgo(5)),
        ],
        config: config(),
        now: now,
      );
      expect(due.single.dueAtKm, 50000);
      expect(due.single.status, DueStatus.ok);
    });

    test('a vehicle never serviced is due at its first interval', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(odo: 9000, lastKm: null, lastOn: null)],
        config: config(
          plans: const <ServicePlan>[
            ServicePlan(
              code: 'S1',
              name: 'Minor',
              intervalKm: 10000,
              intervalDays: 0,
            ),
          ],
        ),
        now: now,
      );
      expect(due.single.dueAtKm, 10000);
      expect(due.single.status, DueStatus.ok);
    });

    test('no odometer reading is surfaced, not treated as zero km', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(odo: 0, synced: false, lastOn: daysAgo(1))],
        config: config(
          plans: const <ServicePlan>[
            ServicePlan(
              code: 'S1',
              name: 'Minor',
              intervalKm: 10000,
              intervalDays: 0,
            ),
          ],
        ),
        now: now,
      );
      expect(due.single.status, DueStatus.unknown);
      expect(due.single.kmRemaining, isNull);
    });

    test('a real time overdue outranks a missing odometer', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[
          vehicle(odo: 0, synced: false, lastOn: daysAgo(200)),
        ],
        config: config(),
        now: now,
      );
      expect(due.single.status, DueStatus.overdue);
    });

    test('retired vehicles are left out of the queue', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[vehicle(active: false)],
        config: config(),
        now: now,
      );
      expect(due, isEmpty);
    });

    test('every active plan is evaluated against every vehicle', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[
          vehicle(reg: 'A', lastOn: daysAgo(1)),
          vehicle(reg: 'B', lastOn: daysAgo(1)),
        ],
        config: config(
          plans: const <ServicePlan>[
            ServicePlan(code: 'S1', name: 'Minor', intervalKm: 10000, intervalDays: 0),
            ServicePlan(code: 'S3', name: 'Major', intervalKm: 40000, intervalDays: 0),
          ],
        ),
        now: now,
      );
      expect(due, hasLength(4));
    });

    test('the queue is ordered worst first', () {
      final due = ServiceSchedule.forSite(
        vehicles: <Vehicle>[
          vehicle(reg: 'FINE', odo: 1000, lastKm: 0, lastOn: daysAgo(1)),
          vehicle(reg: 'OVER', odo: 12000, lastKm: 0, lastOn: daysAgo(1)),
          vehicle(reg: 'SOON', odo: 9800, lastKm: 0, lastOn: daysAgo(1)),
        ],
        config: config(),
        now: now,
      );
      expect(
        due.map((d) => d.vehicle.registrationNo).toList(),
        <String>['OVER', 'SOON', 'FINE'],
      );
    });

    test('attentionOnly keeps just the actionable rows', () {
      final attention = ServiceSchedule.attentionOnly(
        vehicles: <Vehicle>[
          vehicle(reg: 'FINE', odo: 1000, lastKm: 0, lastOn: daysAgo(1)),
          vehicle(reg: 'OVER', odo: 12000, lastKm: 0, lastOn: daysAgo(1)),
        ],
        config: config(),
        now: now,
      );
      expect(attention, hasLength(1));
      expect(attention.single.vehicle.registrationNo, 'OVER');
    });
  });

  group('serialisation', () {
    test('round-trips through JSON', () {
      final original = config().copyWith(
        shifts: const <ShiftWindow>[
          ShiftWindow(shift: 'A', start: '06:00', end: '14:00'),
        ],
      );
      final restored = SiteConfig.fromJson(original.toJson());

      expect(restored.siteCode, 'MBMT');
      expect(restored.servicePlans.single.code, 'S1');
      expect(restored.servicePlans.single.intervalKm, 10000);
      expect(restored.shifts.single.shift, 'A');
      expect(restored.reminderLeadKm, original.reminderLeadKm);
      expect(restored.odometerSync.intervalMinutes, 60);
    });
  });

  group('shift windows', () {
    test('detects the overnight shift', () {
      const c = ShiftWindow(shift: 'C', start: '22:00', end: '06:00');
      const b = ShiftWindow(shift: 'B', start: '14:00', end: '22:00');
      expect(c.wrapsMidnight, isTrue);
      expect(b.wrapsMidnight, isFalse);
    });
  });
}
