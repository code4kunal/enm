import 'package:flutter/foundation.dart';

/// One scheduled service in a site's preventive-maintenance plan.
///
/// Modelled on the way paid car servicing works: a service falls due on
/// whichever comes first, distance or elapsed time. A depot typically runs a
/// ladder — minor every 10,000 km, major every 40,000 km — so plans are a list
/// rather than a single interval.
@immutable
class ServicePlan {
  const ServicePlan({
    required this.code,
    required this.name,
    required this.intervalKm,
    required this.intervalDays,
    this.isActive = true,
    this.notes = '',
  });

  /// Short depot-local handle: `S1`, `PM-A`.
  final String code;
  final String name;

  /// Distance between services. 0 means this plan is time-driven only.
  final int intervalKm;

  /// Calendar days between services. 0 means distance-driven only.
  final int intervalDays;

  final bool isActive;
  final String notes;

  bool get isDistanceDriven => intervalKm > 0;

  bool get isTimeDriven => intervalDays > 0;

  /// A plan with neither interval can never fall due.
  bool get isSchedulable => isDistanceDriven || isTimeDriven;

  String get intervalLabel {
    final parts = <String>[
      if (isDistanceDriven) '${_thousands(intervalKm)} km',
      if (isTimeDriven) '$intervalDays days',
    ];
    return parts.isEmpty ? 'Not scheduled' : parts.join(' / ');
  }

  ServicePlan copyWith({
    String? code,
    String? name,
    int? intervalKm,
    int? intervalDays,
    bool? isActive,
    String? notes,
  }) =>
      ServicePlan(
        code: code ?? this.code,
        name: name ?? this.name,
        intervalKm: intervalKm ?? this.intervalKm,
        intervalDays: intervalDays ?? this.intervalDays,
        isActive: isActive ?? this.isActive,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'name': name,
        'interval_km': intervalKm,
        'interval_days': intervalDays,
        'is_active': isActive,
        'notes': notes,
      };

  factory ServicePlan.fromJson(Map<String, dynamic> json) => ServicePlan(
        code: json['code'] as String,
        name: json['name'] as String,
        intervalKm: json['interval_km'] as int? ?? 0,
        intervalDays: json['interval_days'] as int? ?? 0,
        isActive: json['is_active'] as bool? ?? true,
        notes: json['notes'] as String? ?? '',
      );
}

/// Site-local start/end for one of the three operating shifts.
///
/// A window may wrap midnight — the C shift usually does.
@immutable
class ShiftWindow {
  const ShiftWindow({
    required this.shift,
    required this.start,
    required this.end,
  });

  /// 'A', 'B' or 'C'.
  final String shift;

  /// `HH:mm`, site local time.
  final String start;
  final String end;

  bool get wrapsMidnight => end.compareTo(start) <= 0;

  ShiftWindow copyWith({String? start, String? end}) => ShiftWindow(
        shift: shift,
        start: start ?? this.start,
        end: end ?? this.end,
      );

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'shift': shift, 'start': start, 'end': end};

  factory ShiftWindow.fromJson(Map<String, dynamic> json) => ShiftWindow(
        shift: json['shift'] as String,
        start: json['start'] as String,
        end: json['end'] as String,
      );
}

/// How often odometers are refreshed from telematics.
///
/// The whole maintenance schedule is driven by distance, so a stale odometer
/// silently stops the site from knowing what is due. This is configuration
/// rather than a constant because sites differ in how often their telematics
/// provider reports.
@immutable
class OdometerSync {
  const OdometerSync({
    this.enabled = true,
    this.intervalMinutes = 60,
    this.source = 'telematics',
    this.lastSyncedAt,
  });

  final bool enabled;

  /// Minutes between scheduled pulls. Clamped to a sane floor when applied.
  final int intervalMinutes;

  /// Where readings come from: `telematics`, `manual`, or a named provider.
  final String source;

  /// ISO timestamp of the last successful pull, as reported by the server.
  final String? lastSyncedAt;

  Duration get interval =>
      Duration(minutes: intervalMinutes.clamp(5, 24 * 60));

  OdometerSync copyWith({
    bool? enabled,
    int? intervalMinutes,
    String? source,
    String? lastSyncedAt,
  }) =>
      OdometerSync(
        enabled: enabled ?? this.enabled,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        source: source ?? this.source,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'interval_minutes': intervalMinutes,
        'source': source,
      };

  factory OdometerSync.fromJson(Map<String, dynamic> json) => OdometerSync(
        enabled: json['enabled'] as bool? ?? true,
        intervalMinutes: json['interval_minutes'] as int? ?? 60,
        source: json['source'] as String? ?? 'telematics',
        lastSyncedAt: json['last_synced_at'] as String?,
      );
}

/// A site's preventive-maintenance configuration — the "docking schedule".
///
/// Held as one aggregate rather than loose key/values so validation can reason
/// across fields: a reminder lead longer than the interval it warns about is
/// incoherent, and two plans sharing a code make the due list ambiguous.
@immutable
class SiteConfig {
  const SiteConfig({
    required this.siteCode,
    this.servicePlans = const <ServicePlan>[],
    this.shifts = const <ShiftWindow>[],
    this.reminderLeadKm = 500,
    this.reminderLeadDays = 3,
    this.dockingSlotMinutes = 120,
    this.maxVehiclesInService = 0,
    this.odometerSync = const OdometerSync(),
    this.updatedAt,
    this.updatedBy = '',
  });

  final String siteCode;

  /// The service ladder. Ordered shortest interval first for display.
  final List<ServicePlan> servicePlans;
  final List<ShiftWindow> shifts;

  /// How far ahead a vehicle is flagged as "due soon", by distance…
  final int reminderLeadKm;

  /// …and by time.
  final int reminderLeadDays;

  /// Nominal minutes a vehicle occupies a maintenance bay for a service.
  final int dockingSlotMinutes;

  /// Cap on vehicles off the road for maintenance at once. 0 means no cap.
  final int maxVehiclesInService;

  final OdometerSync odometerSync;

  final String? updatedAt;
  final String updatedBy;

  static SiteConfig empty(String siteCode) => SiteConfig(siteCode: siteCode);

  List<ServicePlan> get activePlans =>
      servicePlans.where((p) => p.isActive && p.isSchedulable).toList();

  /// The shortest active distance interval — what most vehicles hit first.
  int get shortestIntervalKm {
    final distances = activePlans
        .where((p) => p.isDistanceDriven)
        .map((p) => p.intervalKm)
        .toList();
    if (distances.isEmpty) return 0;
    return distances.reduce((a, b) => a < b ? a : b);
  }

  /// Maintenance slots one bay can turn over in a 24h day.
  double get servicesPerBayPerDay =>
      dockingSlotMinutes <= 0 ? 0 : 1440 / dockingSlotMinutes;

  ServicePlan? planByCode(String code) {
    for (final p in servicePlans) {
      if (p.code.toUpperCase() == code.toUpperCase()) return p;
    }
    return null;
  }

  /// Coherence problems a manager should see before saving. Empty means valid.
  List<String> get validationIssues {
    final issues = <String>[];

    if (activePlans.isEmpty) {
      issues.add(
        'No active service plan has an interval — nothing will ever fall due.',
      );
    }

    final codes =
        servicePlans.map((p) => p.code.trim().toUpperCase()).toList();
    if (codes.toSet().length != codes.length) {
      issues.add('Two service plans share the same code.');
    }
    if (codes.any((c) => c.isEmpty)) {
      issues.add('Every service plan needs a code.');
    }

    for (final plan in activePlans) {
      if (plan.isDistanceDriven && reminderLeadKm >= plan.intervalKm) {
        issues.add(
          '"${plan.name}" is warned about ${_thousands(reminderLeadKm)} km '
          'ahead of a ${_thousands(plan.intervalKm)} km interval — it would '
          'always read as due.',
        );
      }
      if (plan.isTimeDriven && reminderLeadDays >= plan.intervalDays) {
        issues.add(
          '"${plan.name}" is warned about $reminderLeadDays days ahead of a '
          '${plan.intervalDays} day interval — it would always read as due.',
        );
      }
    }

    if (odometerSync.enabled && odometerSync.intervalMinutes < 5) {
      issues.add('Odometer sync cannot run more often than every 5 minutes.');
    }
    if (maxVehiclesInService < 0) {
      issues.add('Max vehicles in service cannot be negative.');
    }

    return issues;
  }

  bool get isValid => validationIssues.isEmpty;

  SiteConfig copyWith({
    List<ServicePlan>? servicePlans,
    List<ShiftWindow>? shifts,
    int? reminderLeadKm,
    int? reminderLeadDays,
    int? dockingSlotMinutes,
    int? maxVehiclesInService,
    OdometerSync? odometerSync,
    String? updatedAt,
    String? updatedBy,
  }) {
    return SiteConfig(
      siteCode: siteCode,
      servicePlans: servicePlans ?? this.servicePlans,
      shifts: shifts ?? this.shifts,
      reminderLeadKm: reminderLeadKm ?? this.reminderLeadKm,
      reminderLeadDays: reminderLeadDays ?? this.reminderLeadDays,
      dockingSlotMinutes: dockingSlotMinutes ?? this.dockingSlotMinutes,
      maxVehiclesInService: maxVehiclesInService ?? this.maxVehiclesInService,
      odometerSync: odometerSync ?? this.odometerSync,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'site_code': siteCode,
        'service_plans': servicePlans.map((p) => p.toJson()).toList(),
        'shifts': shifts.map((s) => s.toJson()).toList(),
        'reminder_lead_km': reminderLeadKm,
        'reminder_lead_days': reminderLeadDays,
        'docking_slot_minutes': dockingSlotMinutes,
        'max_vehicles_in_service': maxVehiclesInService,
        'odometer_sync': odometerSync.toJson(),
      };

  factory SiteConfig.fromJson(Map<String, dynamic> json) => SiteConfig(
        siteCode: json['site_code'] as String,
        servicePlans: <ServicePlan>[
          for (final p
              in (json['service_plans'] as List<dynamic>? ?? <dynamic>[]))
            ServicePlan.fromJson(p as Map<String, dynamic>),
        ],
        shifts: <ShiftWindow>[
          for (final s in (json['shifts'] as List<dynamic>? ?? <dynamic>[]))
            ShiftWindow.fromJson(s as Map<String, dynamic>),
        ],
        reminderLeadKm: json['reminder_lead_km'] as int? ?? 500,
        reminderLeadDays: json['reminder_lead_days'] as int? ?? 3,
        dockingSlotMinutes: json['docking_slot_minutes'] as int? ?? 120,
        maxVehiclesInService: json['max_vehicles_in_service'] as int? ?? 0,
        odometerSync: OdometerSync.fromJson(
          json['odometer_sync'] as Map<String, dynamic>? ??
              const <String, dynamic>{},
        ),
        updatedAt: json['updated_at'] as String?,
        updatedBy: json['updated_by'] as String? ?? '',
      );
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
