import 'package:flutter/foundation.dart';

/// One material line a mechanic picked — search-and-tap, never free text.
/// Presence of any line is what opens a job card; see [JobCard].
@immutable
class MaterialLine {
  const MaterialLine({required this.sapMaterialNo, required this.qtyRequired});

  final String sapMaterialNo;
  final String qtyRequired;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sap_material_no': sapMaterialNo,
        'qty_required': qtyRequired,
      };
}

/// A row from the synced SAP material catalog — what the materials picker
/// searches, never a free-text entry.
@immutable
class SapMaterialOption {
  const SapMaterialOption({
    required this.sapMaterialNo,
    required this.description,
    required this.uom,
  });

  final String sapMaterialNo;
  final String description;
  final String uom;

  String get label => uom.isEmpty ? description : '$description ($uom)';

  factory SapMaterialOption.fromJson(Map<String, dynamic> json) =>
      SapMaterialOption(
        sapMaterialNo: json['sap_material_no'] as String? ?? '',
        description: json['description'] as String? ?? '',
        uom: json['uom'] as String? ?? '',
      );
}

enum JobCardStatus { draft, posted, issued, teco, error;

  static JobCardStatus fromWire(String? value) => JobCardStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => JobCardStatus.draft,
      );

  String get label => switch (this) {
        JobCardStatus.draft => 'Draft',
        JobCardStatus.posted => 'Posted',
        JobCardStatus.issued => 'Issued',
        JobCardStatus.teco => 'Closed',
        JobCardStatus.error => 'Error',
      };
}

@immutable
class JobCardComponentOut {
  const JobCardComponentOut({
    required this.sapMaterialNo,
    required this.qtyRequired,
    required this.qtyIssued,
  });

  final String sapMaterialNo;
  final num qtyRequired;
  final num qtyIssued;

  factory JobCardComponentOut.fromJson(Map<String, dynamic> json) =>
      JobCardComponentOut(
        sapMaterialNo: json['sap_material_no'] as String? ?? '',
        qtyRequired: json['qty_required'] as num? ?? 0,
        qtyIssued: json['qty_issued'] as num? ?? 0,
      );
}

@immutable
class JobCard {
  const JobCard({
    required this.id,
    required this.siteCode,
    required this.registrationNo,
    required this.source,
    required this.sourceId,
    required this.status,
    required this.sapNotificationNo,
    required this.sapOrderNo,
    required this.lastSapError,
    required this.components,
    required this.createdAt,
  });

  final String id;
  final String siteCode;
  final String registrationNo;
  final String source;
  final String sourceId;
  final JobCardStatus status;
  final String? sapNotificationNo;
  final String? sapOrderNo;
  final String? lastSapError;
  final List<JobCardComponentOut> components;
  final String createdAt;

  factory JobCard.fromJson(Map<String, dynamic> json) => JobCard(
        id: json['id'] as String,
        siteCode: json['site_code'] as String? ?? '',
        registrationNo: json['registration_no'] as String? ?? '',
        source: json['source'] as String? ?? '',
        sourceId: json['source_id'] as String? ?? '',
        status: JobCardStatus.fromWire(json['status'] as String?),
        sapNotificationNo: json['sap_notification_no'] as String?,
        sapOrderNo: json['sap_order_no'] as String?,
        lastSapError: json['last_sap_error'] as String?,
        components: <JobCardComponentOut>[
          for (final c in (json['components'] as List<dynamic>? ?? <dynamic>[]))
            JobCardComponentOut.fromJson(c as Map<String, dynamic>),
        ],
        createdAt: json['created_at'] as String? ?? '',
      );
}

@immutable
class JobCardReconException {
  const JobCardReconException({
    required this.id,
    required this.jobCardId,
    required this.sapOrderNo,
    required this.kind,
    required this.detail,
    required this.detectedAt,
  });

  final String id;
  final String? jobCardId;
  final String? sapOrderNo;
  final String kind;
  final String detail;
  final String detectedAt;

  String get kindLabel => switch (kind) {
        'sap_only' => 'SAP only',
        'enm_only' => 'ENM only',
        'qty_mismatch' => 'Quantity mismatch',
        'status_mismatch' => 'Status mismatch',
        _ => kind,
      };

  factory JobCardReconException.fromJson(Map<String, dynamic> json) =>
      JobCardReconException(
        id: json['id'] as String,
        jobCardId: json['job_card_id'] as String?,
        sapOrderNo: json['sap_order_no'] as String?,
        kind: json['kind'] as String? ?? '',
        detail: json['detail'] as String? ?? '',
        detectedAt: json['detected_at'] as String? ?? '',
      );
}

@immutable
class SapSyncStatus {
  const SapSyncStatus({
    required this.equipmentMatched,
    required this.materialsSynced,
    required this.flocsMatched,
    required this.syncedAt,
  });

  final int equipmentMatched;
  final int materialsSynced;
  final int flocsMatched;
  final String syncedAt;

  factory SapSyncStatus.fromJson(Map<String, dynamic> json) => SapSyncStatus(
        equipmentMatched: json['equipment_matched'] as int? ?? 0,
        materialsSynced: json['materials_synced'] as int? ?? 0,
        flocsMatched: json['flocs_matched'] as int? ?? 0,
        syncedAt: json['synced_at'] as String? ?? '',
      );
}
