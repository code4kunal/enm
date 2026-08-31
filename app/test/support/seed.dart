import 'package:transvolt_em/models/app_user.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/models/site.dart';
import 'package:transvolt_em/models/site_config.dart';
import 'package:transvolt_em/utils/dates.dart';

/// Fixture data standing in for the master-data service and the entries, users
/// and sites APIs. All of it disappears once real repositories are wired in.

/// Any seeded account accepts this password in the offline demo.
const String kSeedPassword = 'Transvolt@123';

const List<({String code, String name, String address})> kSeedSiteSpecs =
    <({String code, String name, String address})>[
  (code: 'MBMT', name: 'Mira Bhayandar Municipal Transport', address: 'Mira Road (E), Thane'),
  (code: 'UMT', name: 'Ulhasnagar Municipal Transport', address: 'Ulhasnagar, Thane'),
  (code: 'NTSPL', name: 'Nashik Transport Services', address: 'Nashik, Maharashtra'),
  (code: 'Julwania', name: 'Julwania Charging Hub', address: 'Barwani, Madhya Pradesh'),
  (code: 'VECV', name: 'VECV Partner Depot', address: 'Pithampur, Madhya Pradesh'),
  (code: 'STAR', name: 'Star Logistics Depot', address: 'Bhiwandi, Thane'),
  (code: 'GTI', name: 'GTI Freight Terminal', address: 'Gandhidham, Gujarat'),
  (code: 'KANDLA', name: 'Kandla Port Depot', address: 'Kandla, Gujarat'),
];

List<String> get kSeedSites =>
    kSeedSiteSpecs.map((s) => s.code).toList(growable: false);

List<Site> buildSeedSites() => <Site>[
      for (final spec in kSeedSiteSpecs)
        Site(
          code: spec.code,
          name: spec.name,
          // KANDLA is onboarded but not yet commissioned — exercises the
          // "site exists, no traffic" state.
          isActive: spec.code != 'KANDLA',
          address: spec.address,
          commissionedOn: spec.code == 'KANDLA' ? null : Dates.today(-420),
        ),
    ];

const List<String> kSeedDefectSources = <String>[
  'Driver report',
  'Daily inspection',
  'PM schedule',
  'Breakdown',
  'Depot supervisor',
  'Other',
];

const List<String> kSeedDefectTypes = <String>[
  'Electrical / HV',
  'Electrical / LV',
  'AC & HVAC',
  'Brakes & air system',
  'Doors',
  'Suspension & axle',
  'Body & interior',
  'Tyres',
  'Cooling system',
  'Software / telematics',
  'Other',
];

List<MasterListItem> buildSeedMasterList(List<String> names) => <MasterListItem>[
      for (var i = 0; i < names.length; i++)
        MasterListItem(
          id: 'ml-${names[i].hashCode.toRadixString(36)}',
          name: names[i],
          isActive: true,
          sortOrder: i,
        ),
    ];

/// Fleet per site. The MH40 series runs out of Mira-Bhayandar; MH12 out of UMT.
List<Vehicle> buildSeedVehicles() {
  // odo/lastService are chosen to span the whole due ladder against the MBMT
  // plans: overdue, due soon, comfortable, and one never serviced.
  const fleet =
      <({String site, String reg, double kwh, int odo, int? lastKm, int lastDays})>[
    (site: 'MBMT', reg: 'MH40LY1894', kwh: 196, odo: 48200, lastKm: 40000, lastDays: 95),
    (site: 'MBMT', reg: 'MH40LY1721', kwh: 196, odo: 29800, lastKm: 20000, lastDays: 40),
    (site: 'MBMT', reg: 'MH40LY1650', kwh: 196, odo: 12100, lastKm: 10000, lastDays: 12),
    (site: 'MBMT', reg: 'MH40LY1802', kwh: 196, odo: 9700, lastKm: null, lastDays: 20),
    (site: 'MBMT', reg: 'MH40LY1688', kwh: 196, odo: 61500, lastKm: 60000, lastDays: 5),
    (site: 'MBMT', reg: 'MH40LY1733', kwh: 196, odo: 33400, lastKm: 30000, lastDays: 60),
    (site: 'UMT', reg: 'MH12ST4410', kwh: 250, odo: 15200, lastKm: 10000, lastDays: 30),
    (site: 'UMT', reg: 'MH12ST4415', kwh: 250, odo: 4300, lastKm: null, lastDays: 10),
  ];
  return <Vehicle>[
    for (var i = 0; i < fleet.length; i++)
      Vehicle(
        id: 'veh-${i + 1}',
        registrationNo: fleet[i].reg,
        siteCode: fleet[i].site,
        isActive: true,
        make: 'EKA',
        model: fleet[i].kwh >= 250 ? 'E12' : 'E9',
        batteryCapacityKwh: fleet[i].kwh,
        odometerKm: fleet[i].odo,
        odometerUpdatedAt: DateTime.now().toIso8601String(),
        lastServiceKm: fleet[i].lastKm,
        lastServiceOn:
            fleet[i].lastKm == null ? null : Dates.today(-fleet[i].lastDays),
        lastServiceCode: fleet[i].lastKm == null ? '' : 'S1',
      ),
  ];
}

/// A commissioned site arrives with a service ladder; MBMT is the worked
/// example — a minor service every 10,000 km and a major every 40,000.
Map<String, SiteConfig> buildSeedConfigs() => <String, SiteConfig>{
      'MBMT': const SiteConfig(
        siteCode: 'MBMT',
        servicePlans: <ServicePlan>[
          ServicePlan(
            code: 'S1',
            name: 'Minor service',
            intervalKm: 10000,
            intervalDays: 90,
            notes: 'Filters, brake check, coolant top-up',
          ),
          ServicePlan(
            code: 'S2',
            name: 'Intermediate service',
            intervalKm: 20000,
            intervalDays: 180,
            notes: 'Adds suspension and axle inspection',
          ),
          ServicePlan(
            code: 'S3',
            name: 'Major service',
            intervalKm: 40000,
            intervalDays: 365,
            notes: 'Full driveline, HV pack health check',
          ),
        ],
        shifts: <ShiftWindow>[
          ShiftWindow(shift: 'A', start: '06:00', end: '14:00'),
          ShiftWindow(shift: 'B', start: '14:00', end: '22:00'),
          ShiftWindow(shift: 'C', start: '22:00', end: '06:00'),
        ],
        reminderLeadKm: 500,
        reminderLeadDays: 7,
        dockingSlotMinutes: 120,
        maxVehiclesInService: 2,
        odometerSync: OdometerSync(intervalMinutes: 60),
      ),
    };

const List<AppUser> kSeedUsers = <AppUser>[
  AppUser(
    id: 'u0',
    name: 'Priya Deshmukh',
    userId: 'TV1001',
    email: 'priya.deshmukh@transvolt.in',
    role: UserRole.superAdmin,
    sites: <String>[],
    active: true,
  ),
  AppUser(
    id: 'u1',
    name: 'Rahul Sharma',
    userId: 'TV4021',
    email: 'rahul.sharma@transvolt.in',
    role: UserRole.manager,
    sites: <String>['MBMT', 'UMT'],
    active: true,
  ),
  AppUser(
    id: 'u2',
    name: 'Sanjay Pawar',
    userId: 'TV4102',
    email: '',
    role: UserRole.supervisor,
    sites: <String>['MBMT'],
    active: true,
  ),
  AppUser(
    id: 'u3',
    name: 'Arif Khan',
    userId: 'TV3987',
    email: '',
    role: UserRole.executive,
    sites: <String>['MBMT'],
    active: true,
  ),
  AppUser(
    id: 'u4',
    name: 'Vikram Jadhav',
    userId: 'TV4230',
    email: '',
    role: UserRole.executive,
    sites: <String>['MBMT', 'NTSPL'],
    active: true,
  ),
  AppUser(
    id: 'u5',
    name: 'Manoj Patil',
    userId: 'TV3855',
    email: 'manoj.patil@transvolt.in',
    role: UserRole.supervisor,
    sites: <String>['UMT'],
    active: true,
  ),
  AppUser(
    id: 'u6',
    name: 'Deepak Rane',
    userId: 'TV3610',
    email: '',
    role: UserRole.executive,
    sites: <String>['KANDLA'],
    active: false,
  ),
  AppUser(
    id: 'platform-1',
    name: 'Platform Person',
    userId: 'PLATPERSON',
    email: '',
    role: UserRole.executive,
    sites: <String>['MBMT'],
    active: true,
    isPlatformManaged: true,
  ),
];

/// Dates are generated relative to "now" so the Today / Last 7 days / This
/// month filters always have something to show.
List<RegisterEntry> buildSeedEntries() {
  var counter = 0;
  RegisterEntry mk(
    String registerId,
    int dayOffset,
    String time,
    String site,
    String by,
    Map<String, String> data, {
    EntryStatus status = EntryStatus.done,
  }) {
    counter++;
    return RegisterEntry(
      id: 'seed-$counter',
      registerId: registerId,
      date: Dates.today(dayOffset),
      time: time,
      site: site,
      enteredBy: by,
      data: data,
      status: status,
    );
  }

  return <RegisterEntry>[
    mk('work', 0, '07:40', 'MBMT', 'R. Sharma / 4021', <String, String>{
      'shift': 'A',
      'bus': 'MH40LY1894',
      'defects': 'AC not cooling in saloon area',
      'source': 'Driver report',
      'defectType': 'AC & HVAC',
      'attended': 'Condenser fan fuse replaced, gas pressure checked OK',
      'spares': 'Fuse 20A x1',
      'employee': 'R. Sharma / 4021',
    }),
    mk('coolant', 0, '08:15', 'MBMT', 'S. Pawar / 4102', <String, String>{
      'bus': 'MH40LY1721',
      'bcs': '1.5',
      'tcs': '0.5',
      'employee': 'S. Pawar / 4102',
    }),
    mk('complaint', 0, '09:05', 'MBMT', 'A. Khan / 3987', <String, String>{
      'bus': 'MH40LY1650',
      'defectType': 'Body & interior',
      'complaint': 'Wiper blade not clearing on driver side',
      'action': 'Wiper blade replaced',
      'mechanic': 'A. Khan / 3987',
    }),
    mk(
      'breakdown',
      0,
      '06:55',
      'MBMT',
      'V. Jadhav / 4230',
      <String, String>{
        'bus': 'MH40LY1802',
        'driver': 'DRV-2231',
        'loc': 'Kashimira signal, SV Road',
        'complaint': 'Bus not taking traction after halt',
        't_bd': '06:32',
        't_mech': '06:50',
        't_att': '07:35',
        'loss': '18',
        'attended': 'HV interlock fault reset, bus moved on own power',
        'remarks': 'Monitor for repeat',
      },
      status: EntryStatus.open,
    ),
    mk('breakdown', -1, '14:20', 'MBMT', 'V. Jadhav / 4230', <String, String>{
      'bus': 'MH40LY1688',
      'driver': 'DRV-2114',
      'loc': 'Bhayandar station road',
      'complaint': 'Air pressure not building',
      't_bd': '13:58',
      't_mech': '14:10',
      't_att': '14:55',
      'loss': '11',
      'attended': 'Compressor unloader valve cleaned',
      'remarks': '',
    }),
    mk('pm', -1, '11:30', 'MBMT', 'Team B', <String, String>{
      'bus': 'MH40LY1721',
      'defectType': 'Brakes & air system',
      'defects': 'Brake pad wear near limit, coolant level low',
      'action': 'Pads replaced, coolant topped',
      'balance': 'NIL',
      'spares': 'Brake pad set x1',
      'employee': 'S. Pawar, A. Khan',
    }),
    mk('work', -1, '16:10', 'UMT', 'M. Patil / 3855', <String, String>{
      'shift': 'B',
      'bus': 'MH12ST4410',
      'defects': 'Door 2 sensor intermittent',
      'source': 'Daily inspection',
      'defectType': 'Doors',
      'attended': 'Sensor connector re-seated',
      'spares': 'NIL',
      'employee': 'M. Patil / 3855',
    }),
    mk('work', -2, '10:05', 'MBMT', 'A. Khan / 3987', <String, String>{
      'shift': 'A',
      'bus': 'MH40LY1733',
      'defects': 'Saloon light flickering',
      'source': 'Daily inspection',
      'defectType': 'Electrical / LV',
      'attended': 'LED strip driver replaced',
      'spares': 'LED driver x1',
      'employee': 'A. Khan / 3987',
    }),
    mk('work', -4, '15:30', 'MBMT', 'R. Sharma / 4021', <String, String>{
      'shift': 'B',
      'bus': 'MH40LY1650',
      'defects': 'Air leak near front axle',
      'source': 'Driver report',
      'defectType': 'Brakes & air system',
      'attended': 'Air hose clamp tightened, leak arrested',
      'spares': 'NIL',
      'employee': 'R. Sharma / 4021',
    }),
    mk('coolant', -2, '08:40', 'MBMT', 'S. Pawar / 4102', <String, String>{
      'bus': 'MH40LY1894',
      'bcs': '2',
      'tcs': '1',
      'employee': 'S. Pawar / 4102',
    }),
    mk('coolant', -8, '09:10', 'MBMT', 'S. Pawar / 4102', <String, String>{
      'bus': 'MH40LY1802',
      'bcs': '1',
      'tcs': '0.5',
      'employee': 'S. Pawar / 4102',
    }),
    mk('coolant', -18, '08:20', 'MBMT', 'V. Jadhav / 4230', <String, String>{
      'bus': 'MH40LY1688',
      'bcs': '2.5',
      'tcs': '1',
      'employee': 'V. Jadhav / 4230',
    }),
    mk('complaint', -3, '11:45', 'MBMT', 'A. Khan / 3987', <String, String>{
      'bus': 'MH40LY1721',
      'defectType': 'AC & HVAC',
      'complaint': 'Cabin blower noisy at high speed',
      'action': 'Blower motor bearing greased',
      'mechanic': 'A. Khan / 3987',
    }),
    mk('complaint', -10, '17:20', 'MBMT', 'R. Sharma / 4021', <String, String>{
      'bus': 'MH40LY1894',
      'defectType': 'Body & interior',
      'complaint': 'Driver seat backrest loose',
      'action': 'Seat recliner bolt replaced',
      'mechanic': 'R. Sharma / 4021',
    }),
    mk('breakdown', -6, '12:35', 'MBMT', 'V. Jadhav / 4230', <String, String>{
      'bus': 'MH40LY1733',
      'driver': 'DRV-2098',
      'loc': 'Ghodbunder Road, near Kajupada',
      'complaint': 'Sudden power loss, restricted mode',
      't_bd': '12:04',
      't_mech': '12:20',
      't_att': '13:10',
      'loss': '22',
      'attended': 'BMS fault cleared, cell voltages verified',
      'remarks': 'Escalated to OEM',
    }),
    mk('breakdown', -16, '18:05', 'MBMT', 'A. Khan / 3987', <String, String>{
      'bus': 'MH40LY1650',
      'driver': 'DRV-2231',
      'loc': 'Mira Road station stop',
      'complaint': 'Door 1 not closing',
      't_bd': '17:42',
      't_mech': '17:55',
      't_att': '18:25',
      'loss': '6',
      'attended': 'Door limit switch adjusted',
      'remarks': '',
    }),
    mk('pm', -5, '10:50', 'MBMT', 'Team A', <String, String>{
      'bus': 'MH40LY1894',
      'defectType': 'Cooling system',
      'defects': 'Radiator fins clogged, low coolant',
      'action': 'Radiator cleaned, coolant topped',
      'balance': 'NIL',
      'spares': 'Coolant 3L',
      'employee': 'R. Sharma, S. Pawar',
    }),
    mk('pm', -14, '12:15', 'MBMT', 'Team B', <String, String>{
      'bus': 'MH40LY1802',
      'defectType': 'Suspension & axle',
      'defects': 'Rear bush wear noticed',
      'action': 'Marked for replacement',
      'balance': 'Spare bush awaited from CWH',
      'spares': 'NIL',
      'employee': 'A. Khan, V. Jadhav',
    }),
    mk('pm', -25, '09:35', 'MBMT', 'Team A', <String, String>{
      'bus': 'MH40LY1688',
      'defectType': 'Tyres',
      'defects': 'Front tyre uneven wear',
      'action': 'Tyre rotation done, alignment checked',
      'balance': 'NIL',
      'spares': 'NIL',
      'employee': 'S. Pawar',
    }),
    mk('work', -35, '08:55', 'MBMT', 'R. Sharma / 4021', <String, String>{
      'shift': 'A',
      'bus': 'MH40LY1721',
      'defects': 'HVAC filter choked',
      'source': 'PM schedule',
      'defectType': 'AC & HVAC',
      'attended': 'Filter cleaned and refitted',
      'spares': 'NIL',
      'employee': 'R. Sharma / 4021',
    }),
  ];
}
