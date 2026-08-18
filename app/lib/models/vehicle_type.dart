class VehicleType {
  const VehicleType({required this.id, required this.type});

  final String id;
  final String type;

  factory VehicleType.fromJson(Map<String, dynamic> json) => VehicleType(
        id: (json['id'] ?? '').toString(),
        type: (json['type'] ?? json['name'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {'type': type};
}
