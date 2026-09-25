import 'package:flutter/foundation.dart';

/// One person from the site's staff roster, with the id the backend needs
/// for an FK-backed pick — unlike the plain-name lists elsewhere in
/// [MasterDataRepository], which exist for free-text-equivalent single
/// selects that don't need to survive a round trip as an id.
@immutable
class StaffMember {
  const StaffMember({required this.id, required this.name});

  final String id;
  final String name;

  factory StaffMember.fromJson(Map<String, dynamic> json) => StaffMember(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}
