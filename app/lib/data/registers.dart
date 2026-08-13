import '../models/register.dart';
import '../theme/tokens.dart';

/// The five physical registers, column for column.
///
/// Field order and labels match the paper registers exactly — ground staff read
/// down the same sequence on screen as on the page.
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
        label: 'Name & No. of Employee',
        type: FieldType.text,
        placeholder: 'e.g. R. Sharma / 4021',
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
        type: FieldType.text,
        placeholder: 'Name / employee no.',
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
        type: FieldType.text,
        placeholder: 'Name / employee no.',
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
        key: 'driver',
        label: 'Driver ID',
        type: FieldType.text,
        placeholder: 'e.g. DRV-2231',
        width: FieldWidth.half,
      ),
      FieldDef(
        key: 'loc',
        label: 'Location of Breakdown',
        type: FieldType.text,
        placeholder: 'e.g. Kashimira signal, SV Road',
        width: FieldWidth.half,
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
        key: 'remarks',
        label: 'Remarks',
        type: FieldType.text,
        placeholder: 'Optional',
      ),
    ],
  ),
  RegisterDef(
    id: 'pm',
    code: 'PM',
    name: 'PM Schedule Attention',
    color: T.indigo,
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
        key: 'defects',
        label: 'Defects Noticed',
        type: FieldType.area,
        required: true,
        placeholder: 'During preventive maintenance',
      ),
      FieldDef(
        key: 'action',
        label: 'Action Taken',
        type: FieldType.area,
        placeholder: 'Action taken',
      ),
      FieldDef(
        key: 'balance',
        label: 'Reason for Balance Job (if any)',
        type: FieldType.text,
        placeholder: 'e.g. spare awaited, or NIL',
      ),
      FieldDef(
        key: 'spares',
        label: 'Spare Parts Used',
        type: FieldType.text,
        placeholder: 'Part name & qty, or NIL',
      ),
      FieldDef(
        key: 'employee',
        label: 'Name of Employees',
        type: FieldType.text,
        placeholder: 'Names / employee nos.',
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
