import 'package:flutter/foundation.dart';

/// Estate-wide Admin Summary — one site's counts for a period.
@immutable
class SiteSummaryMetrics {
  const SiteSummaryMetrics({
    required this.siteCode,
    required this.name,
    required this.isActive,
    required this.operatingCategories,
    this.vehicleCount = 0,
    this.userCount = 0,
    this.workDone = 0,
    this.driverComplaints = 0,
    this.breakdowns = 0,
    this.coolant = 0,
    this.inspections = 0,
    this.openOffRoad = 0,
  });

  final String siteCode;
  final String name;
  final bool isActive;
  final List<String> operatingCategories;
  final int vehicleCount;
  final int userCount;
  final int workDone;
  final int driverComplaints;
  final int breakdowns;
  final int coolant;
  final int inspections;
  final int openOffRoad;

  factory SiteSummaryMetrics.fromJson(Map<String, dynamic> json) {
    return SiteSummaryMetrics(
      siteCode: json['site_code'] as String? ?? '',
      name: json['name'] as String? ?? '',
      isActive: json['is_active'] as bool? ?? true,
      operatingCategories: [
        for (final c in (json['operating_categories'] as List<dynamic>? ?? const []))
          c.toString(),
      ],
      vehicleCount: (json['vehicle_count'] as num?)?.toInt() ?? 0,
      userCount: (json['user_count'] as num?)?.toInt() ?? 0,
      workDone: (json['work_done'] as num?)?.toInt() ?? 0,
      driverComplaints: (json['driver_complaints'] as num?)?.toInt() ?? 0,
      breakdowns: (json['breakdowns'] as num?)?.toInt() ?? 0,
      coolant: (json['coolant'] as num?)?.toInt() ?? 0,
      inspections: (json['inspections'] as num?)?.toInt() ?? 0,
      openOffRoad: (json['open_off_road'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class EstateTotals {
  const EstateTotals({
    this.sites = 0,
    this.activeSites = 0,
    this.vehicles = 0,
    this.users = 0,
    this.workDone = 0,
    this.driverComplaints = 0,
    this.breakdowns = 0,
    this.coolant = 0,
    this.inspections = 0,
    this.openOffRoad = 0,
  });

  final int sites;
  final int activeSites;
  final int vehicles;
  final int users;
  final int workDone;
  final int driverComplaints;
  final int breakdowns;
  final int coolant;
  final int inspections;
  final int openOffRoad;

  factory EstateTotals.fromJson(Map<String, dynamic> json) {
    return EstateTotals(
      sites: (json['sites'] as num?)?.toInt() ?? 0,
      activeSites: (json['active_sites'] as num?)?.toInt() ?? 0,
      vehicles: (json['vehicles'] as num?)?.toInt() ?? 0,
      users: (json['users'] as num?)?.toInt() ?? 0,
      workDone: (json['work_done'] as num?)?.toInt() ?? 0,
      driverComplaints: (json['driver_complaints'] as num?)?.toInt() ?? 0,
      breakdowns: (json['breakdowns'] as num?)?.toInt() ?? 0,
      coolant: (json['coolant'] as num?)?.toInt() ?? 0,
      inspections: (json['inspections'] as num?)?.toInt() ?? 0,
      openOffRoad: (json['open_off_road'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class SegmentSummary {
  const SegmentSummary({
    required this.key,
    required this.label,
    required this.totals,
    required this.sites,
  });

  final String key;
  final String label;
  final EstateTotals totals;
  final List<SiteSummaryMetrics> sites;

  factory SegmentSummary.fromJson(String key, Map<String, dynamic> json) {
    final totalsRaw = json['totals'] as Map<String, dynamic>? ?? const {};
    return SegmentSummary(
      key: key,
      label: json['label'] as String? ?? key,
      totals: EstateTotals(
        sites: (totalsRaw['site_count'] as num?)?.toInt() ?? 0,
        workDone: (totalsRaw['work_done'] as num?)?.toInt() ?? 0,
        driverComplaints: (totalsRaw['driver_complaints'] as num?)?.toInt() ?? 0,
        breakdowns: (totalsRaw['breakdowns'] as num?)?.toInt() ?? 0,
        coolant: (totalsRaw['coolant'] as num?)?.toInt() ?? 0,
        inspections: (totalsRaw['inspections'] as num?)?.toInt() ?? 0,
        openOffRoad: (totalsRaw['open_off_road'] as num?)?.toInt() ?? 0,
      ),
      sites: [
        for (final s in (json['sites'] as List<dynamic>? ?? const []))
          SiteSummaryMetrics.fromJson(s as Map<String, dynamic>),
      ],
    );
  }
}

@immutable
class AdminSummary {
  const AdminSummary({
    required this.dateFrom,
    required this.dateTo,
    required this.estate,
    required this.sites,
    required this.segments,
  });

  final String dateFrom;
  final String dateTo;
  final EstateTotals estate;
  final List<SiteSummaryMetrics> sites;
  final Map<String, SegmentSummary> segments;

  factory AdminSummary.fromJson(Map<String, dynamic> json) {
    final segs = <String, SegmentSummary>{};
    final rawSegs = json['segments'] as Map<String, dynamic>? ?? const {};
    for (final e in rawSegs.entries) {
      segs[e.key] = SegmentSummary.fromJson(
        e.key,
        e.value as Map<String, dynamic>,
      );
    }
    return AdminSummary(
      dateFrom: json['date_from']?.toString() ?? '',
      dateTo: json['date_to']?.toString() ?? '',
      estate: EstateTotals.fromJson(
        json['estate'] as Map<String, dynamic>? ?? const {},
      ),
      sites: [
        for (final s in (json['sites'] as List<dynamic>? ?? const []))
          SiteSummaryMetrics.fromJson(s as Map<String, dynamic>),
      ],
      segments: segs,
    );
  }
}

@immutable
class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    required this.action,
    required this.objectType,
    required this.objectId,
    required this.createdAt,
    this.actorId,
    this.actorUserId,
    this.actorName,
    this.before,
    this.after,
  });

  final String id;
  final String? actorId;
  final String? actorUserId;
  final String? actorName;
  final String action;
  final String objectType;
  final String objectId;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;
  final String createdAt;

  String get actorLabel {
    if (actorName != null && actorName!.isNotEmpty) {
      final id = actorUserId;
      return id == null || id.isEmpty ? actorName! : '$actorName ($id)';
    }
    return actorUserId ?? actorId ?? '—';
  }

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? asMap(Object? v) {
      if (v is Map<String, dynamic>) return v;
      return null;
    }

    return AuditLogEntry(
      id: json['id']?.toString() ?? '',
      actorId: json['actor_id']?.toString(),
      actorUserId: json['actor_user_id']?.toString(),
      actorName: json['actor_name']?.toString(),
      action: json['action']?.toString() ?? '',
      objectType: json['object_type']?.toString() ?? '',
      objectId: json['object_id']?.toString() ?? '',
      before: asMap(json['before']),
      after: asMap(json['after']),
      createdAt: json['created_at']?.toString() ?? '',
    );
  }
}

@immutable
class AuditLogPage {
  const AuditLogPage({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
  });

  final List<AuditLogEntry> items;
  final int page;
  final int pageSize;
  final int total;

  factory AuditLogPage.fromJson(Map<String, dynamic> json) {
    return AuditLogPage(
      items: [
        for (final i in (json['items'] as List<dynamic>? ?? const []))
          AuditLogEntry.fromJson(i as Map<String, dynamic>),
      ],
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 50,
      total: (json['total'] as num?)?.toInt() ?? 0,
    );
  }
}
