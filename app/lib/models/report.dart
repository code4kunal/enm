import 'package:flutter/foundation.dart';

/// One numbered line of the Daily Maintenance Report.
@immutable
class DmrLine {
  const DmrLine({
    required this.number,
    required this.label,
    required this.key,
    required this.derived,
    this.value,
    this.isDecimal = false,
  });

  final int number;
  final String label;

  /// The field name on the wire — what an edit sends back.
  final String key;

  /// False when nothing in the system observes it, so a person enters it.
  final bool derived;
  final double? value;
  final bool isDecimal;

  bool get isBlank => value == null;

  /// How the depot writes it: counts whole, quantities to one decimal, and a
  /// dash where nothing has been recorded — never a misleading zero.
  String get display {
    final v = value;
    if (v == null) return '—';
    return isDecimal ? v.toStringAsFixed(1) : v.round().toString();
  }

  factory DmrLine.fromJson(Map<String, dynamic> json) => DmrLine(
        number: json['number'] as int,
        label: json['label'] as String,
        key: json['key'] as String,
        derived: json['derived'] as bool? ?? true,
        value: (json['value'] as num?)?.toDouble(),
        isDecimal: json['is_decimal'] as bool? ?? false,
      );
}

/// One day of the report: derived lines computed, entered lines as stored.
@immutable
class DmrDay {
  const DmrDay({
    required this.siteCode,
    required this.reportDate,
    required this.lines,
    this.notes = '',
    this.isSnapshot = false,
    this.generatedAt,
  });

  final String siteCode;
  final String reportDate;
  final List<DmrLine> lines;
  final String notes;

  /// True once the day is frozen; until then the derived lines recompute.
  final bool isSnapshot;
  final String? generatedAt;

  static const empty = DmrDay(
    siteCode: '',
    reportDate: '',
    lines: <DmrLine>[],
  );

  List<DmrLine> get derived => lines.where((l) => l.derived).toList();

  List<DmrLine> get entered => lines.where((l) => !l.derived).toList();

  /// Entered lines still waiting on somebody — what the form nudges about.
  int get unanswered => entered.where((l) => l.isBlank).length;

  factory DmrDay.fromJson(Map<String, dynamic> json) => DmrDay(
        siteCode: json['site_code'] as String? ?? '',
        reportDate: json['report_date'] as String,
        lines: <DmrLine>[
          for (final l in (json['lines'] as List<dynamic>? ?? <dynamic>[]))
            DmrLine.fromJson(l as Map<String, dynamic>),
        ],
        notes: json['notes'] as String? ?? '',
        isSnapshot: json['is_snapshot'] as bool? ?? false,
        generatedAt: json['generated_at'] as String?,
      );
}

/// The month grid: parameters down the page, one column per day.
@immutable
class DmrMonth {
  const DmrMonth({
    required this.siteCode,
    required this.month,
    required this.dates,
    required this.lines,
    required this.values,
  });

  final String siteCode;
  final String month;
  final List<String> dates;
  final List<DmrLine> lines;

  /// line key -> one value per date, in [dates] order.
  final Map<String, List<double?>> values;

  static const empty = DmrMonth(
    siteCode: '',
    month: '',
    dates: <String>[],
    lines: <DmrLine>[],
    values: <String, List<double?>>{},
  );

  List<double?> valuesFor(String key) => values[key] ?? const <double?>[];

  factory DmrMonth.fromJson(Map<String, dynamic> json) => DmrMonth(
        siteCode: json['site_code'] as String? ?? '',
        month: json['month'] as String? ?? '',
        dates: List<String>.from(json['dates'] as List<dynamic>? ?? <dynamic>[]),
        lines: <DmrLine>[
          for (final l in (json['lines'] as List<dynamic>? ?? <dynamic>[]))
            DmrLine.fromJson(l as Map<String, dynamic>),
        ],
        values: <String, List<double?>>{
          for (final e in (json['values'] as Map<String, dynamic>? ??
                  <String, dynamic>{})
              .entries)
            e.key: <double?>[
              for (final v in (e.value as List<dynamic>))
                (v as num?)?.toDouble(),
            ],
        },
      );
}

/// How the report groups a defect or a breakdown.
enum DefectCategory {
  mechanical('mechanical', 'Mechanical'),
  electrical('electrical', 'Electrical'),
  body('body', 'Body'),
  ac('ac', 'AC'),
  its('its', 'ITS'),
  tyre('tyre', 'Tyre'),
  other('other', 'Other');

  const DefectCategory(this.wireName, this.label);

  final String wireName;
  final String label;

  static DefectCategory fromWire(String? value) =>
      DefectCategory.values.firstWhere(
        (c) => c.wireName == value,
        orElse: () => DefectCategory.other,
      );
}

/// A bus off the road, from the day it went down to the day it ran again.
@immutable
class OffRoadCase {
  const OffRoadCase({
    required this.id,
    required this.vehicleId,
    required this.registrationNo,
    required this.issue,
    required this.category,
    required this.offRoadSince,
    this.model = '',
    this.odometerKm,
    this.actionTaken,
    this.expectedDays,
    this.expectedReadyOn,
    this.returnedOn,
    this.spareParts,
    this.remarks,
    this.awaitingVendor = false,
    this.daysDown = 0,
    this.isHeld = false,
  });

  final String id;
  final String vehicleId;
  final String registrationNo;
  final String model;
  final int? odometerKm;
  final String issue;
  final String? actionTaken;
  final DefectCategory category;
  final String offRoadSince;
  final int? expectedDays;
  final String? expectedReadyOn;

  /// Null while the bus is still down.
  final String? returnedOn;
  final String? spareParts;
  final String? remarks;

  /// Waiting on someone else — EKA, Octillion, JTAC. Why a day slipped.
  final bool awaitingVendor;

  /// How long it has been down as at the date asked for.
  final int daysDown;

  /// Down longer than the report's threshold.
  final bool isHeld;

  bool get isOpen => returnedOn == null;

  /// True once the promised return date has passed and it is still down.
  bool overdueAgainst(String today) =>
      isOpen &&
      expectedReadyOn != null &&
      expectedReadyOn!.compareTo(today) < 0;

  factory OffRoadCase.fromJson(Map<String, dynamic> json) => OffRoadCase(
        id: json['id'] as String,
        vehicleId: json['vehicle_id'] as String? ?? '',
        registrationNo: json['registration_no'] as String? ?? '',
        model: json['model'] as String? ?? '',
        odometerKm: (json['odometer_km'] as num?)?.round(),
        issue: json['issue'] as String? ?? '',
        actionTaken: json['action_taken'] as String?,
        category: DefectCategory.fromWire(json['category'] as String?),
        offRoadSince: json['off_road_since'] as String,
        expectedDays: json['expected_days'] as int?,
        expectedReadyOn: json['expected_ready_on'] as String?,
        returnedOn: json['returned_on'] as String?,
        spareParts: json['spare_parts_required'] as String?,
        remarks: json['remarks'] as String?,
        awaitingVendor: json['awaiting_vendor'] as bool? ?? false,
        daysDown: json['days_down'] as int? ?? 0,
        isHeld: json['is_held'] as bool? ?? false,
      );
}

/// Annexure-V: the root-cause follow-up to one breakdown.
@immutable
class Investigation {
  const Investigation({
    required this.entryId,
    required this.registrationNo,
    required this.entryDate,
    this.model = '',
    this.odometerKm,
    this.driverId,
    this.defectType = '',
    this.breakdownReason = '',
    this.location,
    this.breakdownTime,
    this.mechanicReportedTime,
    this.attendedTime,
    this.lossKm,
    this.attendedDetails,
    this.findings,
    this.lastPmOn,
    this.lastPmFindings,
    this.relatedComplaints,
    this.investigationAction,
    this.isComplete = false,
    this.updatedBy = '',
  });

  final String entryId;
  final String registrationNo;
  final String model;
  final int? odometerKm;
  final String? driverId;
  final String defectType;
  final String breakdownReason;
  final String? location;
  final String? breakdownTime;
  final String? mechanicReportedTime;
  final String? attendedTime;
  final double? lossKm;
  final String? attendedDetails;
  final String entryDate;

  /// The investigation itself — what was found and what was done about it.
  final String? findings;

  /// Answered from the inspection history rather than looked up by hand.
  final String? lastPmOn;
  final String? lastPmFindings;
  final String? relatedComplaints;
  final String? investigationAction;

  /// A finding and an action. Without both it is a placeholder.
  final bool isComplete;
  final String updatedBy;

  factory Investigation.fromJson(Map<String, dynamic> json) => Investigation(
        entryId: json['entry_id'] as String,
        registrationNo: json['registration_no'] as String? ?? '',
        model: json['model'] as String? ?? '',
        odometerKm: (json['odometer_km'] as num?)?.round(),
        driverId: json['driver_id'] as String?,
        defectType: json['defect_type'] as String? ?? '',
        breakdownReason: json['breakdown_reason'] as String? ?? '',
        location: json['location'] as String?,
        breakdownTime: json['breakdown_time'] as String?,
        mechanicReportedTime: json['mechanic_reported_time'] as String?,
        attendedTime: json['attended_time'] as String?,
        lossKm: (json['loss_km'] as num?)?.toDouble(),
        attendedDetails: json['attended_details'] as String?,
        entryDate: json['entry_date'] as String,
        findings: json['findings'] as String?,
        lastPmOn: json['last_pm_on'] as String?,
        lastPmFindings: json['last_pm_findings'] as String?,
        relatedComplaints: json['related_complaints'] as String?,
        investigationAction: json['investigation_action'] as String?,
        isComplete: json['is_complete'] as bool? ?? false,
        updatedBy: json['updated_by'] as String? ?? '',
      );
}

// ─── Annexure-IV control charts ───────────────────────────────────────────

/// What the depot colours a block on a control chart.
enum CellMark {
  plain,
  /// A PM was attended that day — shaded on the coolant and energy charts.
  pm,
  /// A docking, which the P.M schedule chart marks red.
  docking,
  /// A breakdown, which the complaints chart marks red.
  breakdown;

  static CellMark parse(String? raw) => CellMark.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => CellMark.plain,
      );
}

/// One block: what happened, and how it is coloured.
class ChartCell {
  const ChartCell({
    this.value = '',
    this.mark = CellMark.plain,
    this.title = '',
  });

  /// What the block shows — already short enough to read in one.
  final String value;
  final CellMark mark;

  /// The full text when [value] had to be shortened to fit. Empty when the two
  /// would be the same.
  final String title;

  /// A blank block is one where nothing happened — no topping, no inspection,
  /// no complaint. It is as much of the chart as a filled one.
  bool get isEmpty => value.isEmpty && mark == CellMark.plain;

  factory ChartCell.fromJson(Map<String, dynamic> json) => ChartCell(
        value: json['value'] as String? ?? '',
        mark: CellMark.parse(json['mark'] as String?),
        title: json['title'] as String? ?? '',
      );
}

/// One bus, across every day in the window.
class ChartRow {
  const ChartRow({
    required this.vehicleId,
    required this.registrationNo,
    required this.cells,
  });

  final String vehicleId;
  final String registrationNo;
  final List<ChartCell> cells;

  factory ChartRow.fromJson(Map<String, dynamic> json) => ChartRow(
        vehicleId: json['vehicle_id'] as String? ?? '',
        registrationNo: json['registration_no'] as String? ?? '',
        cells: <ChartCell>[
          for (final c in (json['cells'] as List<dynamic>? ?? <dynamic>[]))
            ChartCell.fromJson(c as Map<String, dynamic>),
        ],
      );
}

/// A chart the site offers, ahead of asking for its grid.
class ChartKind {
  const ChartKind({
    required this.kind,
    required this.title,
    this.legend = '',
    this.unit = '',
    this.available = true,
    this.unavailableReason = '',
  });

  /// The wire value: `coolantTopping`, `pmSchedule`, and so on.
  final String kind;
  final String title;
  final String legend;
  final String unit;

  /// False when nothing in the system can answer it. The pane says why rather
  /// than drawing an empty grid that reads as a fleet nobody serviced.
  final bool available;
  final String unavailableReason;

  factory ChartKind.fromJson(Map<String, dynamic> json) => ChartKind(
        kind: json['kind'] as String,
        title: json['title'] as String? ?? '',
        legend: json['legend'] as String? ?? '',
        unit: json['unit'] as String? ?? '',
        available: json['available'] as bool? ?? true,
        unavailableReason: json['unavailable_reason'] as String? ?? '',
      );
}

/// One control chart: the fleet down, the days across.
class ControlChart extends ChartKind {
  const ControlChart({
    required super.kind,
    required super.title,
    super.legend,
    super.unit,
    super.available,
    super.unavailableReason,
    this.siteCode = '',
    this.fromDate = '',
    this.toDate = '',
    this.dates = const <String>[],
    this.rows = const <ChartRow>[],
    this.filled = 0,
  });

  final String siteCode;
  final String fromDate;
  final String toDate;
  final List<String> dates;
  final List<ChartRow> rows;

  /// How many blocks carry anything — whether the chart is being kept up at
  /// all, which is the first thing to read off it.
  final int filled;

  static const ControlChart empty = ControlChart(kind: '', title: '');

  factory ControlChart.fromJson(Map<String, dynamic> json) => ControlChart(
        kind: json['kind'] as String,
        title: json['title'] as String? ?? '',
        legend: json['legend'] as String? ?? '',
        unit: json['unit'] as String? ?? '',
        available: json['available'] as bool? ?? true,
        unavailableReason: json['unavailable_reason'] as String? ?? '',
        siteCode: json['site_code'] as String? ?? '',
        fromDate: json['from_date'] as String? ?? '',
        toDate: json['to_date'] as String? ?? '',
        dates: <String>[
          for (final d in (json['dates'] as List<dynamic>? ?? <dynamic>[]))
            d as String,
        ],
        rows: <ChartRow>[
          for (final r in (json['rows'] as List<dynamic>? ?? <dynamic>[]))
            ChartRow.fromJson(r as Map<String, dynamic>),
        ],
        filled: (json['filled'] as num?)?.round() ?? 0,
      );
}
