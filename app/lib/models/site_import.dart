import 'package:flutter/foundation.dart';

/// What a spreadsheet lands in.
///
/// Import formats vary site to site, so the *target* is fixed and known while
/// the *source* shape is whatever the site already keeps. An import profile is
/// the translation between the two.
enum ImportTarget {
  vehicles('Vehicles', 'Fleet master — registration numbers and specs'),
  defectSources('Defect sources', 'Dropdown list backing "Source of Defect"'),
  defectTypes('Defect types', 'Dropdown list backing "Type of Defect"'),
  serviceSchedule(
    'Service schedule',
    'Preventive-maintenance plans — service intervals by km and days',
  ),
  odometers('Odometer readings', 'Bulk odometer update for the fleet'),
  snagReport(
    'Snag report',
    'One monthly sheet — TYPE OF WORK routes each row to its register',
  ),
  workDone('Register · Daily Work Done', 'Historical backfill'),
  coolant('Register · Coolant Topping', 'Historical backfill'),
  driverComplaint('Register · Driver Complaints', 'Historical backfill'),
  breakdown('Register · Breakdown Report', 'Historical backfill'),
  // Retired in favour of Inspections, and kept only so a profile written
  // before the change still parses as itself. Never offered for a new one.
  pmSchedule('Register · PM Schedule (retired)', 'No longer importable');

  const ImportTarget(this.label, this.description);

  final String label;
  final String description;

  bool get isRegister => const <ImportTarget>{
        ImportTarget.workDone,
        ImportTarget.coolant,
        ImportTarget.driverComplaint,
        ImportTarget.breakdown,
      }.contains(this);

  /// Register id in `data/registers.dart`, for register targets.
  String? get registerId => switch (this) {
        ImportTarget.workDone => 'work',
        ImportTarget.coolant => 'coolant',
        ImportTarget.driverComplaint => 'complaint',
        ImportTarget.breakdown => 'breakdown',
        _ => null,
      };

  /// Offered when creating or editing a profile. `pmSchedule` is recognised
  /// but retired, so it is parsed and never proposed.
  static List<ImportTarget> get selectable => ImportTarget.values
      .where((ImportTarget t) => t != ImportTarget.pmSchedule)
      .toList(growable: false);

  static ImportTarget fromName(String name) => ImportTarget.values.firstWhere(
        (t) => t.name == name,
        orElse: () => ImportTarget.vehicles,
      );
}

/// One field the target expects, and whether a row is rejected without it.
@immutable
class TargetField {
  const TargetField({
    required this.key,
    required this.label,
    this.required = false,
    this.hint,
  });

  final String key;
  final String label;
  final bool required;

  /// Format note shown beside the mapping row, e.g. "yyyy-MM-dd".
  final String? hint;
}

/// Binds one source column to one target field.
@immutable
class ColumnMapping {
  const ColumnMapping({
    required this.targetKey,
    required this.sourceColumn,
    this.constantValue,
    this.dateFormat,
  });

  final String targetKey;

  /// Header text in the uploaded sheet. Empty when [constantValue] is used.
  final String sourceColumn;

  /// Literal applied to every row instead of reading a column — for sheets that
  /// omit a field the target requires (a vehicle list with no site column).
  final String? constantValue;

  /// Source date pattern when it is not ISO, e.g. `dd/MM/yyyy`.
  final String? dateFormat;

  bool get isConstant =>
      constantValue != null && constantValue!.trim().isNotEmpty;

  bool get isBound => isConstant || sourceColumn.trim().isNotEmpty;

  ColumnMapping copyWith({
    String? sourceColumn,
    String? constantValue,
    String? dateFormat,
    bool clearConstant = false,
  }) =>
      ColumnMapping(
        targetKey: targetKey,
        sourceColumn: sourceColumn ?? this.sourceColumn,
        constantValue: clearConstant ? null : (constantValue ?? this.constantValue),
        dateFormat: dateFormat ?? this.dateFormat,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'target_key': targetKey,
        'source_column': sourceColumn,
        'constant_value': constantValue,
        'date_format': dateFormat,
      };

  factory ColumnMapping.fromJson(Map<String, dynamic> json) => ColumnMapping(
        targetKey: json['target_key'] as String,
        sourceColumn: json['source_column'] as String? ?? '',
        constantValue: json['constant_value'] as String?,
        dateFormat: json['date_format'] as String?,
      );
}

/// A saved, reusable translation from one site's spreadsheet shape to a target.
///
/// Sites send the same sheet every month, so the mapping is configured once and
/// replayed — that is the whole point of profiles over a one-shot wizard.
@immutable
class ImportProfile {
  const ImportProfile({
    required this.id,
    required this.siteCode,
    required this.name,
    required this.target,
    this.mappings = const <ColumnMapping>[],
    this.sheetName,
    this.headerRow = 1,
    this.skipRows = 0,
    this.lastRunAt,
  });

  final String id;
  final String siteCode;

  /// What the site calls this sheet: "MBMT monthly coolant register".
  final String name;
  final ImportTarget target;
  final List<ColumnMapping> mappings;

  /// Worksheet to read. Null means the first sheet.
  final String? sheetName;

  /// 1-based row holding the column headers.
  final int headerRow;

  /// Data rows to discard after the header — sub-header or units rows.
  final int skipRows;

  final String? lastRunAt;

  ColumnMapping? mappingFor(String targetKey) {
    for (final m in mappings) {
      if (m.targetKey == targetKey) return m;
    }
    return null;
  }

  /// Target fields that are required but still unbound.
  List<TargetField> missingRequired(List<TargetField> fields) => fields
      .where((f) => f.required && !(mappingFor(f.key)?.isBound ?? false))
      .toList();

  bool isComplete(List<TargetField> fields) => missingRequired(fields).isEmpty;

  ImportProfile copyWith({
    String? name,
    ImportTarget? target,
    List<ColumnMapping>? mappings,
    String? sheetName,
    int? headerRow,
    int? skipRows,
    String? lastRunAt,
  }) =>
      ImportProfile(
        id: id,
        siteCode: siteCode,
        name: name ?? this.name,
        target: target ?? this.target,
        mappings: mappings ?? this.mappings,
        sheetName: sheetName ?? this.sheetName,
        headerRow: headerRow ?? this.headerRow,
        skipRows: skipRows ?? this.skipRows,
        lastRunAt: lastRunAt ?? this.lastRunAt,
      );

  /// Replaces the binding for one target field, adding it if absent.
  ImportProfile withMapping(ColumnMapping mapping) {
    final next = mappings.where((m) => m.targetKey != mapping.targetKey).toList()
      ..add(mapping);
    return copyWith(mappings: next);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'site_code': siteCode,
        'name': name,
        'target': target.name,
        'mappings': mappings.map((m) => m.toJson()).toList(),
        'sheet_name': sheetName,
        'header_row': headerRow,
        'skip_rows': skipRows,
      };

  factory ImportProfile.fromJson(Map<String, dynamic> json) => ImportProfile(
        id: json['id'] as String,
        siteCode: json['site_code'] as String,
        name: json['name'] as String,
        target: ImportTarget.fromName(json['target'] as String),
        mappings: <ColumnMapping>[
          for (final m in (json['mappings'] as List<dynamic>? ?? <dynamic>[]))
            ColumnMapping.fromJson(m as Map<String, dynamic>),
        ],
        sheetName: json['sheet_name'] as String?,
        headerRow: json['header_row'] as int? ?? 1,
        skipRows: json['skip_rows'] as int? ?? 0,
        lastRunAt: json['last_run_at'] as String?,
      );
}

/// What the server found when it opened the uploaded file, before any mapping.
@immutable
class SourceInspection {
  const SourceInspection({
    required this.fileName,
    required this.sheetNames,
    required this.columns,
    required this.sampleRows,
    required this.totalRows,
  });

  final String fileName;
  final List<String> sheetNames;

  /// Header texts, in sheet order.
  final List<String> columns;

  /// First few data rows, column-keyed, for the mapping preview.
  final List<Map<String, String>> sampleRows;
  final int totalRows;

  factory SourceInspection.fromJson(Map<String, dynamic> json) =>
      SourceInspection(
        fileName: json['file_name'] as String,
        sheetNames: List<String>.from(json['sheet_names'] as List<dynamic>),
        columns: List<String>.from(json['columns'] as List<dynamic>),
        sampleRows: <Map<String, String>>[
          for (final r in (json['sample_rows'] as List<dynamic>? ?? <dynamic>[]))
            Map<String, String>.from(r as Map),
        ],
        totalRows: json['total_rows'] as int? ?? 0,
      );
}

/// Why one row cannot be imported.
@immutable
class RowError {
  const RowError({
    required this.rowNumber,
    required this.field,
    required this.message,
  });

  /// 1-based row in the source sheet, so the user can find it in Excel.
  final int rowNumber;
  final String field;
  final String message;

  factory RowError.fromJson(Map<String, dynamic> json) => RowError(
        rowNumber: json['row_number'] as int,
        field: json['field'] as String? ?? '',
        message: json['message'] as String,
      );
}

/// A dry run: every row mapped and validated, nothing written.
///
/// The user commits only after seeing this, and a commit reuses the same token
/// so what was previewed is exactly what lands.
@immutable
class ImportPreview {
  const ImportPreview({
    required this.token,
    required this.fileName,
    required this.target,
    required this.rows,
    required this.errors,
    required this.totalRows,
    this.newCount = 0,
    this.updateCount = 0,
  });

  /// Server-side handle for the staged upload; pass it back to commit.
  final String token;
  final String fileName;
  final ImportTarget target;

  /// Mapped, validated rows in target-field terms.
  final List<Map<String, String>> rows;
  final List<RowError> errors;
  final int totalRows;

  /// Rows that would create vs. overwrite an existing record.
  final int newCount;
  final int updateCount;

  int get acceptedCount => rows.length;

  int get rejectedCount => errors.map((e) => e.rowNumber).toSet().length;

  bool get hasErrors => errors.isNotEmpty;

  bool get canCommit => rows.isNotEmpty;

  Set<int> get rejectedRowNumbers =>
      errors.map((e) => e.rowNumber).toSet();

  factory ImportPreview.fromJson(Map<String, dynamic> json) => ImportPreview(
        token: json['token'] as String,
        fileName: json['file_name'] as String,
        target: ImportTarget.fromName(json['target'] as String),
        rows: <Map<String, String>>[
          for (final r in (json['rows'] as List<dynamic>? ?? <dynamic>[]))
            Map<String, String>.from(r as Map),
        ],
        errors: <RowError>[
          for (final e in (json['errors'] as List<dynamic>? ?? <dynamic>[]))
            RowError.fromJson(e as Map<String, dynamic>),
        ],
        totalRows: json['total_rows'] as int? ?? 0,
        newCount: json['new_count'] as int? ?? 0,
        updateCount: json['update_count'] as int? ?? 0,
      );
}

/// The outcome of a committed import, kept as site history.
@immutable
class ImportRun {
  const ImportRun({
    required this.id,
    required this.siteCode,
    required this.profileName,
    required this.target,
    required this.fileName,
    required this.rowsAccepted,
    required this.rowsRejected,
    required this.runAt,
    required this.runBy,
  });

  final String id;
  final String siteCode;
  final String profileName;
  final ImportTarget target;
  final String fileName;
  final int rowsAccepted;
  final int rowsRejected;
  final String runAt;
  final String runBy;

  factory ImportRun.fromJson(Map<String, dynamic> json) => ImportRun(
        id: json['id'] as String,
        siteCode: json['site_code'] as String,
        profileName: json['profile_name'] as String,
        target: ImportTarget.fromName(json['target'] as String),
        fileName: json['file_name'] as String,
        rowsAccepted: json['rows_accepted'] as int? ?? 0,
        rowsRejected: json['rows_rejected'] as int? ?? 0,
        runAt: json['run_at'] as String,
        runBy: json['run_by'] as String? ?? '',
      );
}
