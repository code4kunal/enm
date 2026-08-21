import 'package:flutter/foundation.dart';

/// What a checklist line asks for.
enum ResponseType {
  okNotOk('ok_not_ok', 'OK / Not OK'),
  reading('reading', 'Reading'),
  note('note', 'Note');

  const ResponseType(this.wireName, this.label);

  final String wireName;
  final String label;

  static ResponseType fromWire(String? value) =>
      ResponseType.values.firstWhere(
        (r) => r.wireName == value,
        orElse: () => ResponseType.okNotOk,
      );
}

/// How one line came back.
enum CheckResult {
  ok('ok', 'OK'),
  notOk('not_ok', 'Not OK'),
  na('na', 'N/A');

  const CheckResult(this.wireName, this.label);

  final String wireName;
  final String label;

  static CheckResult fromWire(String? value) => CheckResult.values.firstWhere(
        (r) => r.wireName == value,
        orElse: () => CheckResult.ok,
      );
}

/// One line on a checklist.
@immutable
class ChecklistItem {
  const ChecklistItem({
    required this.id,
    required this.label,
    this.section = '',
    this.sortOrder = 0,
    this.responseType = ResponseType.okNotOk,
    this.isRequired = true,
  });

  final String id;

  /// Groups lines on the form: "Brakes", "Body", "HV system".
  final String section;
  final String label;
  final int sortOrder;
  final ResponseType responseType;
  final bool isRequired;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'section': section,
        'label': label,
        'sort_order': sortOrder,
        'response_type': responseType.wireName,
        'is_required': isRequired,
      };

  factory ChecklistItem.fromJson(Map<String, dynamic> json) => ChecklistItem(
        id: json['id'] as String? ?? '',
        section: json['section'] as String? ?? '',
        label: json['label'] as String,
        sortOrder: json['sort_order'] as int? ?? 0,
        responseType: ResponseType.fromWire(json['response_type'] as String?),
        isRequired: json['is_required'] as bool? ?? true,
      );
}

/// A site's checklist for one inspection type.
///
/// A daily inspection and a ten-day service are different jobs, so each has its
/// own list and its own form. [items] may legitimately be empty — a site that
/// has not written its checklist yet, which the form says out loud rather than
/// pretending otherwise.
@immutable
class Checklist {
  const Checklist({
    required this.siteCode,
    required this.workTypeId,
    required this.workTypeCode,
    required this.workTypeName,
    required this.name,
    this.variant,
    this.id = '',
    this.items = const <ChecklistItem>[],
    this.isActive = true,
    this.updatedAt,
  });

  final String id;
  final String siteCode;
  final int workTypeId;

  /// As written on the site's own sheet: `D.I`, `10 DAYS SERVICE`.
  final String workTypeCode;
  final String workTypeName;
  final String name;

  /// Which buses take this one — MBMT runs a 9M, a 12M AC and a 12M non-AC
  /// daily inspection. Null is the site's unscoped checklist.
  final String? variant;
  final List<ChecklistItem> items;
  final bool isActive;
  final String? updatedAt;

  bool get isEmpty => items.isEmpty;

  List<ChecklistItem> get required =>
      items.where((i) => i.isRequired).toList();

  /// Lines grouped by section, in form order.
  Map<String, List<ChecklistItem>> get bySection {
    final out = <String, List<ChecklistItem>>{};
    for (final item in items) {
      out.putIfAbsent(item.section, () => <ChecklistItem>[]).add(item);
    }
    return out;
  }

  Checklist copyWith({String? name, List<ChecklistItem>? items}) => Checklist(
        id: id,
        siteCode: siteCode,
        workTypeId: workTypeId,
        workTypeCode: workTypeCode,
        workTypeName: workTypeName,
        name: name ?? this.name,
        items: items ?? this.items,
        isActive: isActive,
        updatedAt: updatedAt,
      );

  factory Checklist.fromJson(Map<String, dynamic> json) => Checklist(
        id: json['id'] as String? ?? '',
        siteCode: json['site_code'] as String? ?? '',
        workTypeId: json['work_type_id'] as int,
        workTypeCode: json['work_type_code'] as String? ?? '',
        workTypeName: json['work_type_name'] as String? ?? '',
        name: json['name'] as String? ?? '',
        variant: json['variant'] as String?,
        items: <ChecklistItem>[
          for (final i in (json['items'] as List<dynamic>? ?? <dynamic>[]))
            ChecklistItem.fromJson(i as Map<String, dynamic>),
        ],
        isActive: json['is_active'] as bool? ?? true,
        updatedAt: json['updated_at'] as String?,
      );
}

/// One answered line.
@immutable
class InspectionResult {
  const InspectionResult({
    required this.itemId,
    required this.result,
    this.section = '',
    this.label = '',
    this.value,
    this.remark,
  });

  final String itemId;
  final String section;
  final String label;
  final CheckResult result;

  /// For a reading line.
  final String? value;
  final String? remark;

  bool get failed => result == CheckResult.notOk;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'item_id': itemId,
        'result': result.wireName,
        if (value != null && value!.isNotEmpty) 'value': value,
        if (remark != null && remark!.isNotEmpty) 'remark': remark,
      };

  factory InspectionResult.fromJson(Map<String, dynamic> json) =>
      InspectionResult(
        itemId: json['item_id'] as String,
        section: json['section'] as String? ?? '',
        label: json['label'] as String? ?? '',
        result: CheckResult.fromWire(json['result'] as String?),
        value: json['value'] as String?,
        remark: json['remark'] as String?,
      );
}

/// One completed inspection.
@immutable
class InspectionEntry {
  const InspectionEntry({
    required this.id,
    required this.siteCode,
    required this.vehicleId,
    required this.registrationNo,
    required this.workTypeId,
    required this.workTypeCode,
    required this.workTypeName,
    required this.inspectedOn,
    this.entryTime,
    this.doneBy,
    this.supervisor,
    this.odometerKm,
    this.remarks,
    this.slotId,
    this.failedCount = 0,
    this.results = const <InspectionResult>[],
    this.createdBy = '',
  });

  final String id;
  final String siteCode;
  final String vehicleId;
  final String registrationNo;
  final int workTypeId;
  final String workTypeCode;
  final String workTypeName;
  final String inspectedOn;
  final String? entryTime;
  final String? doneBy;
  final String? supervisor;
  final int? odometerKm;
  final String? remarks;

  /// The booking this discharged, when it came off the calendar.
  final String? slotId;

  /// Lines that came back not OK — what a supervisor actually reads.
  final int failedCount;
  final List<InspectionResult> results;
  final String createdBy;

  bool get isClean => failedCount == 0;

  factory InspectionEntry.fromJson(Map<String, dynamic> json) => InspectionEntry(
        id: json['id'] as String,
        siteCode: json['site_code'] as String? ?? '',
        vehicleId: json['vehicle_id'] as String? ?? '',
        registrationNo: json['registration_no'] as String? ?? '',
        workTypeId: json['work_type_id'] as int? ?? 0,
        workTypeCode: json['work_type_code'] as String? ?? '',
        workTypeName: json['work_type_name'] as String? ?? '',
        inspectedOn: json['inspected_on'] as String,
        entryTime: json['entry_time'] as String?,
        doneBy: json['done_by'] as String?,
        supervisor: json['supervisor'] as String?,
        odometerKm: (json['odometer_km'] as num?)?.round(),
        remarks: json['remarks'] as String?,
        slotId: json['slot_id'] as String?,
        failedCount: json['failed_count'] as int? ?? 0,
        results: <InspectionResult>[
          for (final r in (json['results'] as List<dynamic>? ?? <dynamic>[]))
            InspectionResult.fromJson(r as Map<String, dynamic>),
        ],
        createdBy: json['created_by'] as String? ?? '',
      );
}

/// Category from SiteOps master checklist templates API
@immutable
class ChecklistCategory {
  const ChecklistCategory({
    required this.id,
    required this.name,
    this.orderIndex = 0,
    this.isActive = true,
    this.questionGroups = const <Map<String, dynamic>>[],
  });

  final String id;
  final String name;
  final int orderIndex;
  final bool isActive;
  final List<Map<String, dynamic>> questionGroups;

  factory ChecklistCategory.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['question_groups'] as List<dynamic>? ?? const [];
    return ChecklistCategory(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      orderIndex: (json['order_index'] as num?)?.toInt() ?? 0,
      isActive: json['is_active'] as bool? ?? true,
      questionGroups: rawGroups.cast<Map<String, dynamic>>(),
    );
  }

  /// Converts question_groups in SiteOps format into standard ChecklistItems.
  List<ChecklistItem> toChecklistItems() {
    final items = <ChecklistItem>[];
    int sortCounter = 0;
    for (final group in questionGroups) {
      final section = (group['category_label'] ?? '').toString();
      final questions = group['questions'] as List<dynamic>? ?? const [];
      for (final q in questions) {
        if (q is! Map<String, dynamic>) continue;
        final qId = (q['id'] ?? '').toString();
        final translations = q['translations'] as List<dynamic>? ?? const [];
        String textLabel = '';
        if (translations.isNotEmpty && translations.first is Map) {
          final trans = translations.first as Map<String, dynamic>;
          textLabel = (trans['content'] ?? trans['check_for'] ?? '').toString();
        }
        if (textLabel.isEmpty) {
          textLabel = 'Question ${sortCounter + 1}';
        }
        items.add(
          ChecklistItem(
            id: qId.isNotEmpty ? qId : 'q_$sortCounter',
            section: section,
            label: textLabel,
            sortOrder: (q['order_index'] as num?)?.toInt() ?? sortCounter,
            responseType: ResponseType.okNotOk,
            isRequired: true,
          ),
        );
        sortCounter++;
      }
    }
    return items;
  }
}
