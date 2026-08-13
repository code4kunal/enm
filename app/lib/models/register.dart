import 'package:flutter/widgets.dart';

/// Input control a register column renders as.
enum FieldType {
  /// Free text, single line.
  text,

  /// Bus number — select backed by the bus master for the active site.
  bus,

  /// `yyyy-MM-dd` via the platform date picker.
  date,

  /// `HH:mm` via the platform time picker.
  time,

  /// Numeric with an optional unit suffix (litres / km).
  number,

  /// Multi-line notes.
  area,

  /// Select backed by a master list.
  select,

  /// Segmented toggle (Shift A / B / C).
  seg,
}

/// Master list a [FieldType.select] column draws its options from.
/// Which master list backs a `select` field.
///
/// [staff] is the site's own people — the mechanics and supervisors on its
/// roster — so "attended by" and "supervisor" are picked, not typed. Typed
/// names drift ("R.Sharma", "Rahul S") and stop matching each other.
enum MasterList { defectSources, defectTypes, staff }

/// Layout slot within the wrapped two-column form grid.
///
/// Mirrors the prototype's 100% / 48% / 31% widths. On mobile [full] and [half]
/// both collapse to full width, while [third] steps down to [half] so the
/// breakdown time triplet stays on one row.
enum FieldWidth { full, half, third }

@immutable
class FieldDef {
  const FieldDef({
    required this.key,
    required this.label,
    required this.type,
    this.width = FieldWidth.full,
    this.required = false,
    this.master = false,
    this.optionsFrom,
    this.segOptions = const <String>[],
    this.placeholder,
    this.unit,
    this.rows = 2,
  });

  final String key;
  final String label;
  final FieldType type;
  final FieldWidth width;

  /// Renders a red asterisk and participates in save validation.
  final bool required;

  /// Renders the blue `MASTER` badge — the value comes from master data rather
  /// than free text. Bus fields are implicitly master-backed.
  final bool master;

  /// Which master list feeds a [FieldType.select].
  final MasterList? optionsFrom;

  /// Inline options for a [FieldType.seg].
  final List<String> segOptions;

  final String? placeholder;

  /// Suffix shown beside a [FieldType.number] (e.g. `litres`, `km`).
  final String? unit;

  /// Line count for a [FieldType.area].
  final int rows;

  bool get isMasterBacked => master || type == FieldType.bus;
}

@immutable
class RegisterDef {
  const RegisterDef({
    required this.id,
    required this.code,
    required this.name,
    required this.color,
    required this.fields,
  });

  final String id;

  /// Two-letter code shown in the coloured square (WD, CT, DC, BD, PM).
  final String code;
  final String name;
  final Color color;
  final List<FieldDef> fields;

  FieldDef? field(String key) {
    for (final f in fields) {
      if (f.key == key) return f;
    }
    return null;
  }
}
