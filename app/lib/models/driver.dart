import 'package:flutter/foundation.dart';

@immutable
class Driver {
  const Driver({required this.id, required this.driverCode, required this.name});

  final String id;
  final String driverCode;
  final String name;

  factory Driver.fromJson(Map<String, dynamic> json) => Driver(
        id: json['id'] as String,
        driverCode: json['driver_code'] as String,
        name: json['name'] as String,
      );
}
