import 'package:flutter/foundation.dart';

import 'entry_photo.dart';
export 'entry_photo.dart';

/// Lifecycle of a register entry. Only breakdown entries are ever [open] or
/// [resolved]; every other register writes [done] on save.
enum EntryStatus { open, done, resolved }

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
    this.displayId = '',
    this.photos = const <EntryPhoto>[],
    this.linkedSessions = const <Map<String, dynamic>>[],
  });

  final String id;
  final String registerId;

  /// Human-readable, server-stamped ("BD-2026-000123"). Empty for
  /// synthetic/test entries that never round-tripped through the API.
  final String displayId;

  /// `yyyy-MM-dd`. Stored as a string so it sorts and compares lexically, the
  /// same way the register period filters work.
  final String date;

  /// `HH:mm` capture time.
  final String time;
  final String site;
  final String enteredBy;
  final Map<String, String> data;
  final EntryStatus status;

  final List<EntryPhoto> photos;

  /// The single-photo registers' own convenience view — the first (and,
  /// for them, only) photo, or null if none. Multi-photo registers
  /// (Breakdown, Driver Complaint, Work Done) use [photos] directly.
  String? get photoUrl => photos.isEmpty ? null : photos.first.url;

  /// Work Done sessions raised against this entry's ticket, breakdown only.
  /// Read-only display data — the server owns the linkage.
  final List<Map<String, dynamic>> linkedSessions;

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
      displayId: displayId,
      date: date ?? this.date,
      time: time ?? this.time,
      site: site ?? this.site,
      enteredBy: enteredBy ?? this.enteredBy,
      data: data ?? this.data,
      status: status ?? this.status,
      photos: photos,
      linkedSessions: linkedSessions,
    );
  }

  /// Separate from [copyWith] because the multi-photo endpoints always
  /// return the full updated list, and that's a different shape than
  /// "one field changed" — this just swaps it in wholesale.
  RegisterEntry withPhotos(List<EntryPhoto> photos) {
    return RegisterEntry(
      id: id,
      registerId: registerId,
      displayId: displayId,
      date: date,
      time: time,
      site: site,
      enteredBy: enteredBy,
      data: data,
      status: status,
      photos: photos,
      linkedSessions: linkedSessions,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'registerId': registerId,
        'displayId': displayId,
        'date': date,
        'time': time,
        'site': site,
        'enteredBy': enteredBy,
        'data': data,
        'status': status.name,
        'photos': photos
            .map((p) => <String, dynamic>{
                  'id': p.id,
                  'url': p.url,
                  'caption': p.caption,
                })
            .toList(),
        'linkedSessions': linkedSessions,
      };

  factory RegisterEntry.fromJson(Map<String, dynamic> json) {
    return RegisterEntry(
      id: json['id'] as String,
      registerId: json['registerId'] as String,
      displayId: json['displayId'] as String? ?? '',
      date: json['date'] as String,
      time: json['time'] as String,
      site: json['site'] as String,
      enteredBy: json['enteredBy'] as String,
      data: Map<String, String>.from(json['data'] as Map),
      status: EntryStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => EntryStatus.done,
      ),
      photos: (json['photos'] as List<dynamic>? ?? <dynamic>[])
          .map((p) => EntryPhoto.fromJson(Map<String, dynamic>.from(p as Map)))
          .toList(),
      linkedSessions: (json['linkedSessions'] as List<dynamic>? ?? <dynamic>[])
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList(),
    );
  }
}
