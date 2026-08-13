import '../models/register.dart';
import '../models/site_import.dart';
import 'registers.dart';

/// The fields each import target accepts.
///
/// Register targets derive their fields from the register definitions, so a
/// column added to a paper register automatically becomes importable — there is
/// one definition of what a register holds, not two.
List<TargetField> targetFieldsFor(ImportTarget target) {
  final registerId = target.registerId;
  if (registerId != null) return _registerFields(registerId);

  switch (target) {
    case ImportTarget.vehicles:
      return const <TargetField>[
        TargetField(
          key: 'registration_no',
          label: 'Registration No',
          required: true,
          hint: 'MH40LY1894 — normalised to uppercase, spaces stripped',
        ),
        TargetField(key: 'make', label: 'Make'),
        TargetField(key: 'model', label: 'Model'),
        TargetField(
          key: 'battery_capacity_kwh',
          label: 'Battery capacity',
          hint: 'kWh, decimal',
        ),
        TargetField(
          key: 'is_active',
          label: 'Active',
          hint: 'yes/no, true/false, 1/0 — defaults to active',
        ),
      ];

    case ImportTarget.defectSources:
    case ImportTarget.defectTypes:
      return const <TargetField>[
        TargetField(key: 'name', label: 'Name', required: true),
        TargetField(key: 'sort_order', label: 'Sort order', hint: 'integer'),
        TargetField(key: 'is_active', label: 'Active', hint: 'yes/no'),
      ];

    case ImportTarget.serviceSchedule:
      return const <TargetField>[
        TargetField(
          key: 'code',
          label: 'Service code',
          required: true,
          hint: 'Short handle: S1, PM-A',
        ),
        TargetField(key: 'name', label: 'Service name', required: true),
        TargetField(
          key: 'interval_km',
          label: 'Interval (km)',
          hint: 'integer — 0 for a time-only service',
        ),
        TargetField(
          key: 'interval_days',
          label: 'Interval (days)',
          hint: 'integer — 0 for a distance-only service',
        ),
        TargetField(key: 'notes', label: 'Notes'),
        TargetField(key: 'is_active', label: 'Active', hint: 'yes/no'),
      ];

    case ImportTarget.odometers:
      return const <TargetField>[
        TargetField(
          key: 'registration_no',
          label: 'Registration No',
          required: true,
          hint: 'Must already exist in the site fleet',
        ),
        TargetField(
          key: 'odometer_km',
          label: 'Odometer',
          required: true,
          hint: 'km, integer',
        ),
        TargetField(
          key: 'recorded_at',
          label: 'Reading taken on',
          hint: 'yyyy-MM-dd — defaults to today',
        ),
      ];

    // Register targets are resolved above.
    case ImportTarget.workDone:
    case ImportTarget.coolant:
    case ImportTarget.driverComplaint:
    case ImportTarget.breakdown:
      return const <TargetField>[];
  }
}

List<TargetField> _registerFields(String registerId) {
  final register = requireRegister(registerId);
  return <TargetField>[
    for (final f in register.fields)
      TargetField(
        key: f.key,
        label: f.label,
        required: f.required,
        hint: _hintFor(f.type),
      ),
    // Historical rows carry their own author; without it the import is
    // attributed to whoever ran it.
    const TargetField(
      key: 'entered_by',
      label: 'Entered by',
      hint: 'Name / employee no. — defaults to the importing user',
    ),
  ];
}

String? _hintFor(FieldType type) => switch (type) {
      FieldType.date => 'yyyy-MM-dd, or set a source format below',
      FieldType.time => 'HH:mm',
      FieldType.number => 'decimal',
      FieldType.bus => 'Must already exist in the site fleet',
      FieldType.select => 'Must match an entry in the master list',
      FieldType.seg => 'A, B or C',
      FieldType.text || FieldType.area => null,
    };
