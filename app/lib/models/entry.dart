import 'package:flutter/foundation.dart';

/// Lifecycle of a register entry. Only breakdown entries are ever [open];
/// every other register writes [done] on save.
enum EntryStatus { open, done }

/// One row of one physical register, digitised.
///
/// [data] is deliberately a loose `key -> value` map keyed by [FieldDef.key]:
/// the five registers have disjoint column sets and the master-data service can
/// add columns without a schema migration in the client.
@immutable
class RegisterEntry {
  const RegisterEntry({
    required this.id,
    required this.registerId,
    required this.date,
    required this.time,
    required this.site,
    required this.enteredBy,
    required this.data,
    this.status = EntryStatus.done,
  });

  final String id;
  final String registerId;

  /// `yyyy-MM-dd`. Stored as a string so it sorts and compares lexically, the
  /// same way the register period filters work.
  final String date;

  /// `HH:mm` capture time.
  final String time;
  final String site;
  final String enteredBy;
  final Map<String, String> data;
  final EntryStatus status;

  String get busNumber => data['bus'] ?? '';

  bool get isOpen => status == EntryStatus.open;

  RegisterEntry copyWith({
    String? date,
    String? time,
    String? site,
    String? enteredBy,
    Map<String, String>? data,
    EntryStatus? status,
  }) {
    return RegisterEntry(
      id: id,
      registerId: registerId,
      date: date ?? this.date,
      time: time ?? this.time,
      site: site ?? this.site,
      enteredBy: enteredBy ?? this.enteredBy,
      data: data ?? this.data,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'registerId': registerId,
        'date': date,
        'time': time,
        'site': site,
        'enteredBy': enteredBy,
        'data': data,
        'status': status.name,
      };

  factory RegisterEntry.fromJson(Map<String, dynamic> json) {
    return RegisterEntry(
      id: json['id'] as String,
      registerId: json['registerId'] as String,
      date: json['date'] as String,
      time: json['time'] as String,
      site: json['site'] as String,
      enteredBy: json['enteredBy'] as String,
      data: Map<String, String>.from(json['data'] as Map),
      status: EntryStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => EntryStatus.done,
      ),
    );
  }
}
