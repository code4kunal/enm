import 'dart:math';

import 'package:transvolt_em/models/app_user.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/models/site.dart';
import 'package:transvolt_em/models/site_config.dart';
import 'package:transvolt_em/models/site_import.dart';
import 'package:transvolt_em/utils/dates.dart';
import 'package:transvolt_em/data/registers.dart';
import 'package:transvolt_em/models/register.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'seed.dart';

/// One in-memory database shared by every fake repository.
///
/// Sharing matters: importing a vehicle list has to change what the entry form's
/// bus dropdown offers, and signing in as a manager has to narrow the site
/// roster. Independent stubs per repository would not reproduce either.
class FakeStore {
  FakeStore({bool seeded = true}) {
    if (!seeded) return;
    sites.addAll(buildSeedSites());
    vehicles.addAll(buildSeedVehicles());
    users.addAll(kSeedUsers);
    entries.addAll(buildSeedEntries());
    defectSources.addAll(buildSeedMasterList(kSeedDefectSources));
    defectTypes.addAll(buildSeedMasterList(kSeedDefectTypes));
    configs.addAll(buildSeedConfigs());
    for (final u in kSeedUsers) {
      // A platform-managed account has no local password — SiteOps owns the
      // credential, and the server stores `password_hash = NULL` for it.
      if (u.isPlatformManaged) continue;
      passwords[u.userId] = kSeedPassword;
    }
  }

  final List<Site> sites = <Site>[];
  final List<Vehicle> vehicles = <Vehicle>[];
  final List<AppUser> users = <AppUser>[];
  final List<RegisterEntry> entries = <RegisterEntry>[];
  final List<MasterListItem> defectSources = <MasterListItem>[];
  final List<MasterListItem> defectTypes = <MasterListItem>[];
  final Map<String, SiteConfig> configs = <String, SiteConfig>{};
  final List<ImportProfile> profiles = <ImportProfile>[];
  final List<ImportRun> runs = <ImportRun>[];

  /// Plaintext only because this is a stub; the server stores bcrypt hashes.
  final Map<String, String> passwords = <String, String>{};

  /// Who is signed in. Drives the same visibility scoping the server applies.
  AppUser? currentUser;

  String get currentUserName => currentUser?.name ?? 'System';

  final Random _rng = Random();

  String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rng.nextInt(1 << 20).toRadixString(36)}';

  /// Sites the signed-in user may see. Super admins see every site.
  List<Site> visibleSites() {
    final user = currentUser;
    final ordered = List<Site>.of(sites)
      ..sort((a, b) => a.code.compareTo(b.code));
    if (user == null) return const <Site>[];
    if (user.governsAllSites) return _withRollups(ordered);
    return _withRollups(ordered.where((s) => user.sites.contains(s.code)).toList());
  }

  List<Site> _withRollups(List<Site> input) => <Site>[
        for (final s in input)
          s.copyWith(
            vehicleCount:
                vehicles.where((v) => v.siteCode == s.code && v.isActive).length,
            userCount: users
                .where((u) => !u.governsAllSites && u.sites.contains(s.code))
                .length,
          ),
      ];

  /// Users the signed-in user may administer: everyone for a super admin, and
  /// only users sharing one of the caller's sites otherwise.
  List<AppUser> visibleUsers() {
    final user = currentUser;
    if (user == null) return const <AppUser>[];
    if (user.governsAllSites) return List<AppUser>.of(users);
    return users
        .where((u) => u.sites.any((code) => user.sites.contains(code)))
        .toList();
  }

  MasterListItem? findMasterItem(List<MasterListItem> list, String name) {
    final needle = name.trim().toLowerCase();
    for (final item in list) {
      if (item.name.toLowerCase() == needle) return item;
    }
    return null;
  }

  /// Writes a committed import into the store.
  ///
  /// Deliberately upsert-by-natural-key rather than blind insert: sites resend
  /// the same monthly sheet, and a re-run must not double the fleet.
  void applyImport(ImportProfile profile, List<Map<String, String>> rows) {
    switch (profile.target) {
      case ImportTarget.vehicles:
        for (final row in rows) {
          final reg = row['registration_no'];
          if (reg == null || reg.isEmpty) continue;
          final i = vehicles.indexWhere((v) => v.registrationNo == reg);
          final vehicle = Vehicle(
            id: i == -1 ? newId() : vehicles[i].id,
            registrationNo: reg,
            siteCode: profile.siteCode,
            isActive: _bool(row['is_active'], fallback: true),
            make: row['make'] ?? (i == -1 ? '' : vehicles[i].make),
            model: row['model'] ?? (i == -1 ? '' : vehicles[i].model),
            batteryCapacityKwh: double.tryParse(
                  row['battery_capacity_kwh'] ?? '',
                ) ??
                (i == -1 ? null : vehicles[i].batteryCapacityKwh),
          );
          i == -1 ? vehicles.add(vehicle) : vehicles[i] = vehicle;
        }

      case ImportTarget.defectSources:
        _applyMasterList(defectSources, rows);

      case ImportTarget.defectTypes:
        _applyMasterList(defectTypes, rows);

      case ImportTarget.serviceSchedule:
        final current =
            configs[profile.siteCode] ?? SiteConfig.empty(profile.siteCode);
        final plans = List<ServicePlan>.of(current.servicePlans);
        for (final row in rows) {
          final code = (row['code'] ?? '').trim();
          if (code.isEmpty) continue;
          final i = plans.indexWhere(
            (p) => p.code.toUpperCase() == code.toUpperCase(),
          );
          final plan = ServicePlan(
            code: code,
            name: row['name'] ?? code,
            intervalKm: int.tryParse(row['interval_km'] ?? '') ?? 0,
            intervalDays: int.tryParse(row['interval_days'] ?? '') ?? 0,
            isActive: _bool(row['is_active'], fallback: true),
            notes: row['notes'] ?? '',
          );
          i == -1 ? plans.add(plan) : plans[i] = plan;
        }
        configs[profile.siteCode] = current.copyWith(servicePlans: plans);

      case ImportTarget.odometers:
        for (final row in rows) {
          final reg = row['registration_no'];
          final reading = int.tryParse(row['odometer_km'] ?? '');
          if (reg == null || reading == null) continue;
          final i = vehicles.indexWhere((v) => v.registrationNo == reg);
          if (i == -1) continue;
          // Never move an odometer backwards on a bulk import; a lower figure
          // is a stale sheet, not a correction.
          if (reading < vehicles[i].odometerKm) continue;
          vehicles[i] = vehicles[i].copyWith(
            odometerKm: reading,
            odometerUpdatedAt: row['recorded_at'] ?? Dates.today(),
          );
        }

      // The snag report routes each row by TYPE OF WORK against the
      // work-type master, which only the server holds — the offline demo has
      // no way to decide which register a row becomes. `pmSchedule` is
      // retired. Both are recognised here so the switch stays exhaustive and
      // a new target cannot be added without someone deciding what it means.
      case ImportTarget.snagReport:
      case ImportTarget.pmSchedule:
        break;

      case ImportTarget.workDone:
      case ImportTarget.coolant:
      case ImportTarget.driverComplaint:
      case ImportTarget.breakdown:
        final registerId = profile.target.registerId!;
        for (final row in rows) {
          final data = Map<String, String>.of(row)
            ..remove(r'$row')
            ..remove('entered_by');
          entries.insert(
            0,
            RegisterEntry(
              id: newId(),
              registerId: registerId,
              date: row['date'] ?? Dates.today(),
              time: row['t_bd'] ?? '00:00',
              site: profile.siteCode,
              enteredBy: row['entered_by'] ?? currentUserName,
              data: data,
              // Backfilled breakdowns are historical; they land resolved rather
              // than lighting up the open-breakdown banner.
              status: EntryStatus.done,
            ),
          );
        }
    }
  }

  void _applyMasterList(
    List<MasterListItem> list,
    List<Map<String, String>> rows,
  ) {
    for (final row in rows) {
      final name = (row['name'] ?? '').trim();
      if (name.isEmpty) continue;
      final existing = findMasterItem(list, name);
      final item = MasterListItem(
        id: existing?.id ?? newId(),
        name: name,
        isActive: _bool(row['is_active'], fallback: true),
        sortOrder: int.tryParse(row['sort_order'] ?? '') ??
            existing?.sortOrder ??
            list.length,
      );
      final i = list.indexWhere((m) => m.id == item.id);
      i == -1 ? list.add(item) : list[i] = item;
    }
  }

  static bool _bool(String? raw, {required bool fallback}) {
    if (raw == null || raw.trim().isEmpty) return fallback;
    return const <String>{'yes', 'true', '1', 'y', 'active'}
        .contains(raw.trim().toLowerCase());
  }

}

/// Entries scoped and sorted the way the API returns them.
List<RegisterEntry> scopedEntries(FakeStore store, String site) {
  final scoped = store.entries.where((e) => e.site == site).toList()
    ..sort((a, b) {
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.time.compareTo(a.time);
    });
  return scoped;
}

/// Active registration numbers for a site's entry dropdown.
List<String> activeVehicleNumbers(FakeStore store, String site) {
  final list = store.vehicles
      .where((v) => v.siteCode == site && v.isActive)
      .map((v) => v.registrationNo)
      .toList()
    ..sort();
  return list;
}

/// Guards a register write against a value that is not on a master list.
void assertMasterValue(FakeStore store, RegisterEntry entry) {
  final register = registerById(entry.registerId);
  if (register == null) return;
  for (final field in register.fields) {
    final value = entry.data[field.key];
    if (value == null || value.isEmpty) continue;
    if (field.optionsFrom == null) continue;
    if (field.optionsFrom == MasterList.staff) {
      // Staff come from the site's roster, not an editable dropdown list.
      final known = store.users.any(
        (u) => u.active && u.name == value && u.canAccess(entry.site),
      );
      if (!known) {
        throw ApiException('"$value" is not on the ${field.label} master list');
      }
      continue;
    }
    final list = field.optionsFrom == MasterList.defectSources
        ? store.defectSources
        : store.defectTypes;
    if (store.findMasterItem(list, value) == null) {
      throw ApiException('"$value" is not on the ${field.label} master list');
    }
  }
}
