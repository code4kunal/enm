import 'package:flutter/foundation.dart';

/// A depot, onboarded by an admin. The tenant unit: every vehicle, entry,
/// config and import profile hangs off exactly one site.
@immutable
class Site {
  const Site({
    required this.code,
    required this.name,
    required this.isActive,
    this.timezone = 'Asia/Kolkata',
    this.address = '',
    this.commissionedOn,
    this.vehicleCount = 0,
    this.userCount = 0,
  });

  /// Short uppercase handle (MBMT, UMT). Primary key, immutable after creation
  /// because entries reference it.
  final String code;
  final String name;

  /// Soft delete. An inactive site keeps its history but accepts no new entries
  /// and disappears from the site switcher.
  final bool isActive;

  /// IANA zone. Drives site wall-clock defaults for entry times and shifts.
  final String timezone;
  final String address;

  /// `yyyy-MM-dd`, when the site went live. Null until commissioned.
  final String? commissionedOn;

  /// Rollups shown on the site list; not authoritative.
  final int vehicleCount;
  final int userCount;

  bool get isCommissioned => commissionedOn != null;

  Site copyWith({
    String? name,
    bool? isActive,
    String? timezone,
    String? address,
    String? commissionedOn,
    int? vehicleCount,
    int? userCount,
    bool clearCommissionedOn = false,
  }) {
    return Site(
      code: code,
      name: name ?? this.name,
      isActive: isActive ?? this.isActive,
      timezone: timezone ?? this.timezone,
      address: address ?? this.address,
      commissionedOn:
          clearCommissionedOn ? null : (commissionedOn ?? this.commissionedOn),
      vehicleCount: vehicleCount ?? this.vehicleCount,
      userCount: userCount ?? this.userCount,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'name': name,
        'is_active': isActive,
        'timezone': timezone,
        'address': address,
        'commissioned_on': commissionedOn,
      };

  factory Site.fromJson(Map<String, dynamic> json) => Site(
        code: json['code'] as String,
        name: json['name'] as String,
        isActive: json['is_active'] as bool? ?? true,
        timezone: json['timezone'] as String? ?? 'Asia/Kolkata',
        address: json['address'] as String? ?? '',
        commissionedOn: json['commissioned_on'] as String?,
        vehicleCount: json['vehicle_count'] as int? ?? 0,
        userCount: json['user_count'] as int? ?? 0,
      );
}

/// A bus on a site's fleet. Backs the "Bus No" dropdown on every register —
/// the registers keep the paper wording, the master data calls it a vehicle.
@immutable
class Vehicle {
  const Vehicle({
    required this.id,
    required this.registrationNo,
    required this.siteCode,
    required this.isActive,
    this.make = '',
    this.model = '',
    this.checklistVariant,
    this.batteryCapacityKwh,
    this.odometerKm = 0,
    this.odometerUpdatedAt,
    this.lastServiceKm,
    this.lastServiceOn,
    this.lastServiceCode = '',
  });

  final String id;

  /// Normalised uppercase, no whitespace: MH40LY1894.
  final String registrationNo;
  final String siteCode;

  /// Retired vehicles stay on past entries but leave the entry dropdown.
  final bool isActive;
  final String make;
  final String model;

  /// Which inspection checklist this bus takes, when a work type has more
  /// than one.
  final String? checklistVariant;

  /// Usable pack energy.
  final double? batteryCapacityKwh;

  /// Current distance covered. The whole maintenance schedule hangs off this,
  /// which is why it is refreshed on a timer rather than typed in.
  final int odometerKm;

  /// ISO timestamp of the last odometer refresh. Null means never synced —
  /// treat the reading as unusable rather than as zero.
  final String? odometerUpdatedAt;

  /// Odometer at the last completed service, and when it happened. Together
  /// these anchor the next due point.
  final int? lastServiceKm;
  final String? lastServiceOn;

  /// Which [ServicePlan] was last carried out.
  final String lastServiceCode;

  bool get hasOdometer => odometerUpdatedAt != null;

  String get displayLabel {
    final spec = <String>[
      if (make.isNotEmpty) make,
      if (model.isNotEmpty) model,
    ].join(' ');
    return spec.isEmpty ? registrationNo : '$registrationNo · $spec';
  }

  /// Registration numbers are stored uppercase with no whitespace.
  static String normalise(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'\s+'), '');

  Vehicle copyWith({
    String? registrationNo,
    String? siteCode,
    bool? isActive,
    String? make,
    String? model,
    double? batteryCapacityKwh,
    int? odometerKm,
    String? odometerUpdatedAt,
    int? lastServiceKm,
    String? lastServiceOn,
    String? lastServiceCode,
  }) {
    return Vehicle(
      id: id,
      registrationNo: registrationNo ?? this.registrationNo,
      siteCode: siteCode ?? this.siteCode,
      isActive: isActive ?? this.isActive,
      make: make ?? this.make,
      model: model ?? this.model,
      batteryCapacityKwh: batteryCapacityKwh ?? this.batteryCapacityKwh,
      odometerKm: odometerKm ?? this.odometerKm,
      odometerUpdatedAt: odometerUpdatedAt ?? this.odometerUpdatedAt,
      lastServiceKm: lastServiceKm ?? this.lastServiceKm,
      lastServiceOn: lastServiceOn ?? this.lastServiceOn,
      lastServiceCode: lastServiceCode ?? this.lastServiceCode,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'registration_no': registrationNo,
        'site_code': siteCode,
        'is_active': isActive,
        'make': make,
        'model': model,
        'battery_capacity_kwh': batteryCapacityKwh,
        'odometer_km': odometerKm,
        'last_service_km': lastServiceKm,
        'last_service_on': lastServiceOn,
        'last_service_code': lastServiceCode,
      };

  factory Vehicle.fromJson(Map<String, dynamic> json) {
    final rawReg = (json['registration_no'] ??
            json['registration_number'] ??
            json['vehicle_no'] ??
            json['vehicle_number'] ??
            json['bus_no'] ??
            json['name'] ??
            json['code'] ??
            '')
        .toString();
    final idStr = (json['id'] ?? json['uuid'] ?? '').toString();
    return Vehicle(
      id: idStr,
      registrationNo: rawReg.isNotEmpty ? rawReg : idStr,
      siteCode: (json['site_code'] ?? json['site_id'] ?? '').toString(),
      isActive: json['is_active'] as bool? ?? true,
        make: (json['make'] ?? '').toString(),
        model: (json['model'] ?? '').toString(),
        checklistVariant: json['checklist_variant']?.toString(),
        batteryCapacityKwh: (json['battery_capacity_kwh'] as num?)?.toDouble(),
        odometerKm:
            ((json['odometer_km'] ?? json['last_odo']) as num?)?.round() ?? 0,
        odometerUpdatedAt: json['odometer_updated_at']?.toString(),
        lastServiceKm: (json['last_service_km'] as num?)?.round(),
        lastServiceOn: json['last_service_on']?.toString(),
        lastServiceCode: (json['last_service_code'] ?? '').toString(),
      );
  }
}

/// An editable row in one of the shared dropdown lists (defect sources, defect
/// types). Managers maintain these per site.
@immutable
class MasterListItem {
  const MasterListItem({
    required this.id,
    required this.name,
    required this.isActive,
    this.sortOrder = 0,
  });

  final String id;
  final String name;
  final bool isActive;
  final int sortOrder;

  MasterListItem copyWith({String? name, bool? isActive, int? sortOrder}) =>
      MasterListItem(
        id: id,
        name: name ?? this.name,
        isActive: isActive ?? this.isActive,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  factory MasterListItem.fromJson(Map<String, dynamic> json) => MasterListItem(
        id: json['id'].toString(),
        name: json['name'] as String,
        isActive: json['is_active'] as bool? ?? true,
        sortOrder: json['sort_order'] as int? ?? 0,
      );
}
