import '../models/register.dart';
import '../theme/tokens.dart';

/// The physical registers, column for column.
///
/// Field order and labels match the paper registers exactly — ground staff read
/// down the same sequence on screen as on the page.
///
/// PM Schedule Attention is not here: what it recorded — defects noticed during
/// preventive maintenance — is now an inspection against its own checklist, and
/// keeping both would mean two places to write the same thing.
const List<RegisterDef> kRegisters = <RegisterDef>[
  RegisterDef(
    id: 'work',
    code: 'WD',
    name: 'Daily Work Done',
    color: T.blue,
    fields: <FieldDef>[
      FieldDef(
        key: 'shift',
        label: 'Shift',
        type: FieldType.seg,
        segOptions: <String>['A', 'B', 'C'],
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'date',
        label: 'Date',
        type: FieldType.date,
        required: true,
        width: FieldWidth.half,
      ),
      FieldDef(key: 'bus', label: 'Bus No', type: FieldType.bus, required: true),
      FieldDef(
        key: 'defects',
        label: 'Reported Defects',
        type: FieldType.area,
        required: true,
        placeholder: 'e.g. AC not cooling, abnormal noise from rear axle',
      ),
      FieldDef(
        key: 'source',
        label: 'Source of Defect',
        type: FieldType.select,
        optionsFrom: MasterList.defectSources,
        master: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'defectType',
        label: 'Type of Defect',
        type: FieldType.select,
        optionsFrom: MasterList.defectTypes,
        master: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'attended',
        label: 'Attended Details',
        type: FieldType.area,
        placeholder: 'What was done to rectify',
      ),
      FieldDef(
        key: 'spares',
        label: 'Spare Parts Used',
        type: FieldType.text,
        placeholder: 'Part name & qty, or NIL',
      ),
      FieldDef(
        key: 'employee',
        label: 'Attended By',
        type: FieldType.select,
        optionsFrom: MasterList.staff,
        master: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'supervisor',
        label: 'Supervisor (Floor)',
        type: FieldType.select,
        optionsFrom: MasterList.staff,
        master: true,
        width: FieldWidth.half,
      ),
    ],
  ),
  RegisterDef(
    id: 'coolant',
    code: 'CT',
    name: 'Coolant Topping',
    color: T.green,
    fields: <FieldDef>[
      FieldDef(
        key: 'date',
        label: 'Date',
        type: FieldType.date,
        required: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'bus',
        label: 'Bus No',
        type: FieldType.bus,
        required: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'bcs',
        label: 'BCS Topping',
        type: FieldType.number,
        unit: 'litres',
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'tcs',
        label: 'TCS Topping',
        type: FieldType.number,
        unit: 'litres',
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'employee',
        label: 'Topped up by',
        type: FieldType.select,
        optionsFrom: MasterList.staff,
        master: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'supervisor',
        label: 'Supervisor (Floor)',
        type: FieldType.select,
        optionsFrom: MasterList.staff,
        master: true,
        width: FieldWidth.half,
      ),
    ],
  ),
  RegisterDef(
    id: 'complaint',
    code: 'DC',
    name: 'Driver Complaints',
    color: T.amber,
    fields: <FieldDef>[
      FieldDef(
        key: 'date',
        label: 'Date',
        type: FieldType.date,
        required: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'bus',
        label: 'Bus No',
        type: FieldType.bus,
        required: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'defectType',
        label: 'Type of Defect',
        type: FieldType.select,
        optionsFrom: MasterList.defectTypes,
        master: true,
      ),
      FieldDef(
        key: 'complaint',
        label: 'Driver Complaint Reported',
        type: FieldType.area,
        required: true,
        placeholder: 'As reported by the driver',
      ),
      FieldDef(
        key: 'action',
        label: 'Rectification Action Taken',
        type: FieldType.area,
        placeholder: 'Action taken',
      ),
      FieldDef(
        key: 'mechanic',
        label: 'Name of the Mechanic',
        type: FieldType.select,
        optionsFrom: MasterList.staff,
        master: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'supervisor',
        label: 'Supervisor (Floor)',
        type: FieldType.select,
        optionsFrom: MasterList.staff,
        master: true,
        width: FieldWidth.half,
      ),
    ],
  ),
  RegisterDef(
    id: 'breakdown',
    code: 'BD',
    name: 'Breakdown Report',
    color: T.red,
    fields: <FieldDef>[
      FieldDef(
        key: 'date',
        label: 'Date',
        type: FieldType.date,
        required: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'bus',
        label: 'Bus No',
        type: FieldType.bus,
        required: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'defectType',
        label: 'Type of Defect',
        type: FieldType.select,
        optionsFrom: MasterList.defectTypes,
        master: true,
      ),
      FieldDef(
        key: 'driver',
        label: 'Driver ID',
        type: FieldType.text,
        placeholder: 'e.g. DRV-2231',
        width: FieldWidth.third,
      ),
      FieldDef(
        key: 'route',
        label: 'Route',
        type: FieldType.text,
        placeholder: 'e.g. 7',
        width: FieldWidth.third,
      ),
      FieldDef(
        key: 'loc',
        label: 'Location of Breakdown',
        type: FieldType.text,
        placeholder: 'e.g. Kashimira signal, SV Road',
        width: FieldWidth.third,
      ),
      FieldDef(
        key: 'complaint',
        label: 'Complaint Reported by the Driver',
        type: FieldType.area,
        required: true,
        placeholder: 'As reported over phone / app',
      ),
      FieldDef(
        key: 't_bd',
        label: 'B/Down Time',
        type: FieldType.time,
        width: FieldWidth.third,
      ),
      FieldDef(
        key: 't_mech',
        label: 'Mechanic Reported Time',
        type: FieldType.time,
        width: FieldWidth.third,
      ),
      FieldDef(
        key: 't_att',
        label: 'Bus Attended Time',
        type: FieldType.time,
        width: FieldWidth.third,
      ),
      FieldDef(
        key: 'loss',
        label: 'Loss KM',
        type: FieldType.number,
        unit: 'km',
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'attended',
        label: 'Bus Attended Details',
        type: FieldType.area,
        placeholder: 'What was done on site',
      ),
      FieldDef(
        key: 'supervisor',
        label: 'Supervisor (Floor)',
        type: FieldType.select,
        optionsFrom: MasterList.staff,
        master: true,
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'remarks',
        label: 'Remarks',
        type: FieldType.text,
        placeholder: 'Optional',
        width: FieldWidth.half,
      ),
    ],
  ),
];

/// The breakdown register — the one register with an open/resolved lifecycle.
const String kBreakdownRegisterId = 'breakdown';

RegisterDef? registerById(String id) {
  for (final r in kRegisters) {
    if (r.id == id) return r;
  }
  return null;
}

/// Throws if [id] is not a known register. Use at call sites where the id came
/// from an entry that must have been created against a real register.
RegisterDef requireRegister(String id) {
  final r = registerById(id);
  if (r == null) throw ArgumentError.value(id, 'id', 'Unknown register');
  return r;
}

/// The register-filter value that means "show inspections instead".
///
/// A sentinel rather than a sixth register: inspections are not one, and the
/// list renders them differently.
const String kInspectionsFilter = 'inspections';
const String kPmDockingFilter = 'pm_docking';
const String kTenDayFilter = '10_day';
const String kDailyFilter = 'daily_inspection';

bool isInspectionFilter(String id) {
  return id == kInspectionsFilter ||
      id == kPmDockingFilter ||
      id == kTenDayFilter ||
      id == kDailyFilter;
}
