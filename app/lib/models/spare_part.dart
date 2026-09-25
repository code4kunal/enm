import 'package:flutter/foundation.dart';

@immutable
class SparePart {
  const SparePart({required this.id, required this.partNo, required this.name});

  final String id;
  final String partNo;
  final String name;

  factory SparePart.fromJson(Map<String, dynamic> json) => SparePart(
        id: json['id'] as String,
        partNo: json['part_no'] as String,
        name: json['name'] as String,
      );
}
