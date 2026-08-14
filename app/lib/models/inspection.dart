import 'package:flutter/foundation.dart';

/// Where a booking stands.
enum SlotStatus {
  scheduled('Scheduled'),
  done('Done'),
  missed('Missed'),
  cancelled('Cancelled');

  const SlotStatus(this.label);

  final String label;

  bool get isOpen => this == SlotStatus.scheduled;

  static SlotStatus fromWire(String? value) => SlotStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => SlotStatus.scheduled,
      );
}

/// One bus booked in for one inspection on one night.
@immutable
class InspectionSlot {
  const InspectionSlot({
    required this.id,
    required this.siteCode,
    required this.vehicleId,
    required this.registrationNo,
    required this.workTypeId,
    required this.workTypeCode,
    required this.workTypeName,
    required this.scheduledOn,
    required this.status,
    this.isPinned = false,
    this.servicePlanName,
    this.servicePlanKm,
    this.completedOn,
    this.notes = '',
  });

  final String id;
  final String siteCode;
  final String vehicleId;
  final String registrationNo;
  final int workTypeId;

  /// As written on the site's own sheet: `D.I`, `10 DAYS SERVICE`.
  final String workTypeCode;
  final String workTypeName;

  /// `yyyy-MM-dd`.
  final String scheduledOn;
  final SlotStatus status;

  /// A slot a person moved by hand. The generator leaves these alone.
  final bool isPinned;

  /// The docking rung this books — "1.1 lakh docking" — or null for the
  /// calendar rotations. A docking takes a bus off the road for a major
  /// service, so it is worth telling apart at a glance.
  final String? servicePlanName;
  final int? servicePlanKm;

  bool get isDocking => servicePlanName != null;
  final String? completedOn;
  final String notes;

  InspectionSlot copyWith({
    String? scheduledOn,
    SlotStatus? status,
    bool? isPinned,
    String? notes,
  }) =>
      InspectionSlot(
        id: id,
        siteCode: siteCode,
        vehicleId: vehicleId,
        registrationNo: registrationNo,
        workTypeId: workTypeId,
        workTypeCode: workTypeCode,
        workTypeName: workTypeName,
        scheduledOn: scheduledOn ?? this.scheduledOn,
        status: status ?? this.status,
        isPinned: isPinned ?? this.isPinned,
        completedOn: completedOn,
        notes: notes ?? this.notes,
      );

  factory InspectionSlot.fromJson(Map<String, dynamic> json) => InspectionSlot(
        id: json['id'] as String,
        siteCode: json['site_code'] as String? ?? '',
        vehicleId: json['vehicle_id'] as String? ?? '',
        registrationNo: json['registration_no'] as String? ?? '',
        workTypeId: json['work_type_id'] as int? ?? 0,
        workTypeCode: json['work_type_code'] as String? ?? '',
        workTypeName: json['work_type_name'] as String? ?? '',
        scheduledOn: json['scheduled_on'] as String,
        status: SlotStatus.fromWire(json['status'] as String?),
        isPinned: json['is_pinned'] as bool? ?? false,
        servicePlanName: json['service_plan_name'] as String?,
        servicePlanKm: (json['service_plan_km'] as num?)?.toInt(),
        completedOn: json['completed_on'] as String?,
        notes: json['notes'] as String? ?? '',
      );
}

/// One column of the calendar. Empty days are returned too, so the grid is
/// continuous without the client having to fill gaps.
@immutable
class CalendarDay {
  const CalendarDay({required this.date, required this.slots});

  final String date;
  final List<InspectionSlot> slots;

  int get count => slots.length;

  bool get isEmpty => slots.isEmpty;

  int countOf(SlotStatus status) =>
      slots.where((s) => s.status == status).length;

  /// True when any bus is booked for a docking that day.
  bool get hasDocking => slots.any((s) => s.isDocking);

  /// Slots grouped by inspection type, smallest group first.
  ///
  /// On a night with 57 daily inspections, 5 ten-day services and 4 dockings,
  /// listing them in any other order buries the dockings — and a docking is
  /// the one that takes a bus off the road. The exceptional work rises, the
  /// routine bulk sinks.
  Map<String, List<InspectionSlot>> get byWorkType {
    final out = <String, List<InspectionSlot>>{};
    for (final slot in slots) {
      out.putIfAbsent(slot.workTypeCode, () => <InspectionSlot>[]).add(slot);
    }
    final ordered = out.entries.toList()
      ..sort((a, b) => a.value.length.compareTo(b.value.length));
    return <String, List<InspectionSlot>>{
      for (final e in ordered) e.key: e.value,
    };
  }

  factory CalendarDay.fromJson(Map<String, dynamic> json) => CalendarDay(
        date: json['date'] as String,
        slots: <InspectionSlot>[
          for (final s in (json['slots'] as List<dynamic>? ?? <dynamic>[]))
            InspectionSlot.fromJson(s as Map<String, dynamic>),
        ],
      );
}

/// A window of the schedule.
@immutable
class InspectionCalendar {
  const InspectionCalendar({
    required this.siteCode,
    required this.fromDate,
    required this.toDate,
    required this.days,
    this.scheduled = 0,
    this.done = 0,
    this.missed = 0,
  });

  final String siteCode;
  final String fromDate;
  final String toDate;
  final List<CalendarDay> days;
  final int scheduled;
  final int done;
  final int missed;

  static const empty = InspectionCalendar(
    siteCode: '',
    fromDate: '',
    toDate: '',
    days: <CalendarDay>[],
  );

  CalendarDay? dayOf(String date) {
    for (final d in days) {
      if (d.date == date) return d;
    }
    return null;
  }

  factory InspectionCalendar.fromJson(Map<String, dynamic> json) =>
      InspectionCalendar(
        siteCode: json['site_code'] as String? ?? '',
        fromDate: json['from_date'] as String? ?? '',
        toDate: json['to_date'] as String? ?? '',
        days: <CalendarDay>[
          for (final d in (json['days'] as List<dynamic>? ?? <dynamic>[]))
            CalendarDay.fromJson(d as Map<String, dynamic>),
        ],
        scheduled: json['scheduled'] as int? ?? 0,
        done: json['done'] as int? ?? 0,
        missed: json['missed'] as int? ?? 0,
      );
}

/// How often one inspection comes round, and how many fit in a night.
@immutable
class InspectionPlan {
  const InspectionPlan({
    required this.workTypeId,
    required this.workTypeCode,
    required this.workTypeName,
    required this.cycleDays,
    required this.slotsPerDay,
    this.id = '',
    this.isActive = true,
  });

  final String id;
  final int workTypeId;
  final String workTypeCode;
  final String workTypeName;
  final int cycleDays;

  /// 0 means uncapped — a daily inspection covers the whole fleet.
  final int slotsPerDay;
  final bool isActive;

  bool get isUncapped => slotsPerDay <= 0;

  String get cadenceLabel =>
      cycleDays == 1 ? 'Every night' : 'Every $cycleDays days';

  String get capacityLabel =>
      isUncapped ? 'Whole fleet' : '$slotsPerDay per night';

  InspectionPlan copyWith({int? cycleDays, int? slotsPerDay, bool? isActive}) =>
      InspectionPlan(
        id: id,
        workTypeId: workTypeId,
        workTypeCode: workTypeCode,
        workTypeName: workTypeName,
        cycleDays: cycleDays ?? this.cycleDays,
        slotsPerDay: slotsPerDay ?? this.slotsPerDay,
        isActive: isActive ?? this.isActive,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'work_type_id': workTypeId,
        'cycle_days': cycleDays,
        'slots_per_day': slotsPerDay,
        'is_active': isActive,
      };

  factory InspectionPlan.fromJson(Map<String, dynamic> json) => InspectionPlan(
        id: json['id'] as String? ?? '',
        workTypeId: json['work_type_id'] as int,
        workTypeCode: json['work_type_code'] as String? ?? '',
        workTypeName: json['work_type_name'] as String? ?? '',
        cycleDays: json['cycle_days'] as int? ?? 10,
        slotsPerDay: json['slots_per_day'] as int? ?? 0,
        isActive: json['is_active'] as bool? ?? true,
      );
}

/// What the nightly run produced.
@immutable
class GenerationResult {
  const GenerationResult({
    required this.created,
    required this.missed,
    required this.completed,
    required this.alertsRaised,
  });

  final int created;
  final int missed;
  final int completed;
  final int alertsRaised;

  bool get changedNothing =>
      created == 0 && missed == 0 && completed == 0 && alertsRaised == 0;

  String get summary {
    if (changedNothing) return 'Already up to date.';
    final parts = <String>[
      if (created > 0) '$created booked',
      if (completed > 0) '$completed completed',
      if (missed > 0) '$missed missed',
      if (alertsRaised > 0) '$alertsRaised new alert${alertsRaised == 1 ? '' : 's'}',
    ];
    return parts.join(' · ');
  }

  factory GenerationResult.fromJson(Map<String, dynamic> json) =>
      GenerationResult(
        created: json['created'] as int? ?? 0,
        missed: json['missed'] as int? ?? 0,
        completed: json['completed'] as int? ?? 0,
        alertsRaised: json['alerts_raised'] as int? ?? 0,
      );
}

// ─── Alerts ────────────────────────────────────────────────────────────────

enum AlertKind {
  missedInspection('missed_inspection', 'Missed inspection'),
  breakdownOpen('breakdown_open', 'Open breakdown'),
  serviceOverdue('service_overdue', 'Service overdue');

  const AlertKind(this.wireName, this.label);

  final String wireName;
  final String label;

  static AlertKind fromWire(String? value) => AlertKind.values.firstWhere(
        (a) => a.wireName == value,
        orElse: () => AlertKind.missedInspection,
      );
}

enum AlertState {
  open('Open'),
  acknowledged('Acknowledged'),
  resolved('Resolved');

  const AlertState(this.label);

  final String label;

  static AlertState fromWire(String? value) => AlertState.values.firstWhere(
        (a) => a.name == value,
        orElse: () => AlertState.open,
      );
}

/// Something the site has to look at.
@immutable
class SiteAlert {
  const SiteAlert({
    required this.id,
    required this.siteCode,
    required this.kind,
    required this.state,
    required this.title,
    required this.body,
    required this.raisedOn,
    this.registrationNo = '',
    this.vehicleId,
    this.slotId,
    this.entryId,
    this.acknowledgedAt,
  });

  final String id;
  final String siteCode;
  final AlertKind kind;
  final AlertState state;
  final String title;
  final String body;
  final String raisedOn;
  final String registrationNo;
  final String? vehicleId;
  final String? slotId;
  final String? entryId;
  final String? acknowledgedAt;

  bool get isOpen => state == AlertState.open;

  factory SiteAlert.fromJson(Map<String, dynamic> json) => SiteAlert(
        id: json['id'] as String,
        siteCode: json['site_code'] as String? ?? '',
        kind: AlertKind.fromWire(json['type'] as String?),
        state: AlertState.fromWire(json['status'] as String?),
        title: json['title'] as String? ?? '',
        body: json['body'] as String? ?? '',
        raisedOn: json['raised_on'] as String? ?? '',
        registrationNo: json['registration_no'] as String? ?? '',
        vehicleId: json['vehicle_id'] as String?,
        slotId: json['slot_id'] as String?,
        entryId: json['entry_id'] as String?,
        acknowledgedAt: json['acknowledged_at'] as String?,
      );
}
