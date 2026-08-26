import 'dart:typed_data';

import 'package:transvolt_em/models/site.dart';
import 'package:transvolt_em/models/site_config.dart';
import 'package:transvolt_em/models/site_import.dart';
import 'package:transvolt_em/utils/dates.dart';
import 'package:transvolt_em/data/import_targets.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'csv_source.dart';
import 'fake_store.dart';

const Duration _latency = Duration(milliseconds: 220);

// ─── Sites ────────────────────────────────────────────────────────────────

class FakeSiteRepository implements SiteRepository {
  FakeSiteRepository(this._store);

  final FakeStore _store;

  @override
  Future<List<Site>> fetchSites() async {
    await Future<void>.delayed(_latency);
    return _store.visibleSites();
  }

  @override
  Future<Site> createSite({
    required String code,
    required String name,
    String timezone = 'Asia/Kolkata',
    String address = '',
    String? commissionedOn,
    String? siteopsSiteId,
    List<String> operatingCategories = const <String>['bus'],
  }) async {
    await Future<void>.delayed(_latency);
    final normalised = code.trim().toUpperCase();
    if (normalised.isEmpty || name.trim().isEmpty) {
      throw const ApiException('Site code and name are required');
    }
    if (await isCodeTaken(normalised)) {
      throw const ApiException('A site with that code already exists');
    }
    final site = Site(
      code: normalised,
      name: name.trim(),
      isActive: true,
      timezone: timezone,
      address: address.trim(),
      commissionedOn: commissionedOn,
      siteopsSiteId: siteopsSiteId,
    );
    _store.sites.add(site);
    return site;
  }

  @override
  Future<Site> updateSite(Site site) async {
    await Future<void>.delayed(_latency);
    final i = _store.sites.indexWhere((s) => s.code == site.code);
    if (i == -1) throw ApiException('Site ${site.code} not found');
    _store.sites[i] = site;
    return site;
  }

  @override
  Future<Site> setActive(String code, bool active) async {
    await Future<void>.delayed(_latency);
    final i = _store.sites.indexWhere((s) => s.code == code);
    if (i == -1) throw ApiException('Site $code not found');
    final updated = _store.sites[i].copyWith(isActive: active);
    _store.sites[i] = updated;
    return updated;
  }

  @override
  Future<bool> isCodeTaken(String code) async {
    final needle = code.trim().toUpperCase();
    return _store.sites.any((s) => s.code.toUpperCase() == needle);
  }
}

// ─── Vehicles ─────────────────────────────────────────────────────────────

class FakeVehicleRepository implements VehicleRepository {
  FakeVehicleRepository(this._store);

  final FakeStore _store;

  @override
  Future<List<Vehicle>> fetchVehicles({
    required String siteCode,
    bool includeInactive = false,
  }) async {
    await Future<void>.delayed(_latency);
    return _store.vehicles
        .where((v) => v.siteCode == siteCode)
        .where((v) => includeInactive || v.isActive)
        .toList()
      ..sort((a, b) => a.registrationNo.compareTo(b.registrationNo));
  }

  @override
  Future<Vehicle> createVehicle({
    required String siteCode,
    required String registrationNo,
    String make = '',
    String model = '',
    double? batteryCapacityKwh,
  }) async {
    await Future<void>.delayed(_latency);
    final reg = Vehicle.normalise(registrationNo);
    if (reg.isEmpty) {
      throw const ApiException('Registration number is required');
    }
    if (_store.vehicles.any((v) => v.registrationNo == reg)) {
      throw ApiException('$reg is already on the fleet');
    }
    final vehicle = Vehicle(
      id: _store.newId(),
      registrationNo: reg,
      siteCode: siteCode,
      isActive: true,
      make: make.trim(),
      model: model.trim(),
      batteryCapacityKwh: batteryCapacityKwh,
    );
    _store.vehicles.add(vehicle);
    return vehicle;
  }

  @override
  Future<Vehicle> updateVehicle(Vehicle vehicle) async {
    await Future<void>.delayed(_latency);
    final i = _store.vehicles.indexWhere((v) => v.id == vehicle.id);
    if (i == -1) throw ApiException('Vehicle ${vehicle.id} not found');
    _store.vehicles[i] = vehicle;
    return vehicle;
  }

  @override
  Future<Vehicle> setActive(String id, bool active) async {
    await Future<void>.delayed(_latency);
    final i = _store.vehicles.indexWhere((v) => v.id == id);
    if (i == -1) throw ApiException('Vehicle $id not found');
    final updated = _store.vehicles[i].copyWith(isActive: active);
    _store.vehicles[i] = updated;
    return updated;
  }

  @override
  Future<OdometerSyncResult> syncOdometers({required String siteCode}) async {
    await Future<void>.delayed(_latency);
    final now = DateTime.now();
    final stamp = now.toIso8601String();
    final readings = <OdometerReading>[];

    for (var i = 0; i < _store.vehicles.length; i++) {
      final v = _store.vehicles[i];
      if (v.siteCode != siteCode || !v.isActive) continue;

      // Stands in for a telematics feed: advance the odometer by a plausible
      // day's running so the maintenance queue actually moves in the demo.
      final advance = 120 + (v.registrationNo.hashCode.abs() % 160);
      final next = v.odometerKm + advance;
      _store.vehicles[i] =
          v.copyWith(odometerKm: next, odometerUpdatedAt: stamp);

      readings.add(
        OdometerReading(
          vehicleId: v.id,
          registrationNo: v.registrationNo,
          odometerKm: next,
          recordedAt: stamp,
        ),
      );
    }

    final config = _store.configs[siteCode];
    if (config != null) {
      _store.configs[siteCode] = config.copyWith(
        odometerSync: config.odometerSync.copyWith(lastSyncedAt: stamp),
      );
    }
    return OdometerSyncResult(readings: readings, syncedAt: stamp);
  }

  @override
  Future<Vehicle> setOdometer({
    required String vehicleId,
    required int odometerKm,
  }) async {
    await Future<void>.delayed(_latency);
    final i = _store.vehicles.indexWhere((v) => v.id == vehicleId);
    if (i == -1) throw ApiException('Vehicle $vehicleId not found');
    if (odometerKm < _store.vehicles[i].odometerKm) {
      // Odometers do not run backwards; a lower reading is a typo or a swapped
      // cluster, and either way a human has to look at it.
      throw const ApiException(
        'That reading is lower than the one on record. Odometers do not run '
        'backwards — check the value.',
      );
    }
    final updated = _store.vehicles[i].copyWith(
      odometerKm: odometerKm,
      odometerUpdatedAt: DateTime.now().toIso8601String(),
    );
    _store.vehicles[i] = updated;
    return updated;
  }

  @override
  Future<Vehicle> recordService({
    required String vehicleId,
    required String planCode,
    required int odometerKm,
    required String servicedOn,
  }) async {
    await Future<void>.delayed(_latency);
    final i = _store.vehicles.indexWhere((v) => v.id == vehicleId);
    if (i == -1) throw ApiException('Vehicle $vehicleId not found');
    final updated = _store.vehicles[i].copyWith(
      lastServiceKm: odometerKm,
      lastServiceOn: servicedOn,
      lastServiceCode: planCode,
      // A service reading is also the freshest odometer we have.
      odometerKm: odometerKm > _store.vehicles[i].odometerKm
          ? odometerKm
          : _store.vehicles[i].odometerKm,
      odometerUpdatedAt: DateTime.now().toIso8601String(),
    );
    _store.vehicles[i] = updated;
    return updated;
  }
}

// ─── Site config ──────────────────────────────────────────────────────────

class FakeSiteConfigRepository implements SiteConfigRepository {
  FakeSiteConfigRepository(this._store);

  final FakeStore _store;

  @override
  Future<SiteConfig> fetchConfig(String siteCode) async {
    await Future<void>.delayed(_latency);
    return _store.configs[siteCode] ?? SiteConfig.empty(siteCode);
  }

  @override
  Future<SiteConfig> saveConfig(SiteConfig config) async {
    await Future<void>.delayed(_latency);
    // The server is the authority even though the client checks first.
    final issues = config.validationIssues;
    if (issues.isNotEmpty) throw ApiException(issues.first);
    final saved = config.copyWith(updatedAt: Dates.today());
    _store.configs[config.siteCode] = saved;
    return saved;
  }
}

// ─── Imports ──────────────────────────────────────────────────────────────

class FakeImportRepository implements ImportRepository {
  FakeImportRepository(this._store);

  final FakeStore _store;

  /// Staged uploads awaiting commit, keyed by preview token.
  final Map<String, _StagedImport> _staged = <String, _StagedImport>{};

  @override
  Future<List<ImportProfile>> fetchProfiles(String siteCode) async {
    await Future<void>.delayed(_latency);
    return _store.profiles.where((p) => p.siteCode == siteCode).toList();
  }

  @override
  Future<ImportProfile> saveProfile(ImportProfile profile) async {
    await Future<void>.delayed(_latency);
    if (profile.name.trim().isEmpty) {
      throw const ApiException('Give the profile a name');
    }
    final i = _store.profiles.indexWhere((p) => p.id == profile.id);
    if (i == -1) {
      _store.profiles.add(profile);
    } else {
      _store.profiles[i] = profile;
    }
    return profile;
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    await Future<void>.delayed(_latency);
    _store.profiles.removeWhere((p) => p.id == profileId);
  }

  @override
  Future<SourceInspection> inspect({
    required String siteCode,
    required String fileName,
    required Uint8List bytes,
    String? sheetName,
    int headerRow = 1,
  }) async {
    await Future<void>.delayed(_latency);
    _assertCsv(fileName);

    final table = CsvSource.table(bytes, headerRow: headerRow);
    if (table.columns.isEmpty) {
      throw const ApiException('No header row found in that file');
    }
    return SourceInspection(
      fileName: fileName,
      // A CSV has exactly one sheet; xlsx handling is the server's job.
      sheetNames: const <String>['Sheet1'],
      columns: table.columns,
      sampleRows: table.rows.take(5).toList(),
      totalRows: table.rows.length,
    );
  }

  @override
  Future<ImportPreview> preview({
    required ImportProfile profile,
    required String fileName,
    required Uint8List bytes,
  }) async {
    await Future<void>.delayed(_latency);
    _assertCsv(fileName);

    final fields = targetFieldsFor(profile.target);
    final missing = profile.missingRequired(fields);
    if (missing.isNotEmpty) {
      throw ApiException(
        'Map the required field${missing.length > 1 ? 's' : ''}: '
        '${missing.map((f) => f.label).join(', ')}',
      );
    }

    final table = CsvSource.table(
      bytes,
      headerRow: profile.headerRow,
      skipRows: profile.skipRows,
    );

    final rows = <Map<String, String>>[];
    final errors = <RowError>[];
    var newCount = 0;
    var updateCount = 0;

    final existingVehicles = _store.vehicles
        .where((v) => v.siteCode == profile.siteCode)
        .map((v) => v.registrationNo)
        .toSet();

    for (final source in table.rows) {
      final rowNumber = int.tryParse(source[r'$row'] ?? '') ?? 0;
      final mapped = <String, String>{};
      var rowRejected = false;

      for (final field in fields) {
        final mapping = profile.mappingFor(field.key);
        final raw = mapping == null
            ? ''
            : (mapping.isConstant
                ? mapping.constantValue!.trim()
                : (source[mapping.sourceColumn] ?? '').trim());

        if (field.required && raw.isEmpty) {
          errors.add(RowError(
            rowNumber: rowNumber,
            field: field.label,
            message: 'Required value is blank',
          ));
          rowRejected = true;
          continue;
        }
        if (raw.isNotEmpty) mapped[field.key] = raw;
      }

      if (rowRejected) continue;

      // Target-specific checks that mirror the server's rules.
      final regKey = mapped['registration_no'] ?? mapped['bus'];
      if (regKey != null) {
        final normalised = Vehicle.normalise(regKey);
        mapped[mapped.containsKey('registration_no') ? 'registration_no' : 'bus'] =
            normalised;

        if (profile.target == ImportTarget.vehicles) {
          existingVehicles.contains(normalised) ? updateCount++ : newCount++;
        } else if (!existingVehicles.contains(normalised)) {
          // Register rows and docking slots may only reference a known vehicle.
          errors.add(RowError(
            rowNumber: rowNumber,
            field: 'Bus No',
            message: '$normalised is not on the ${profile.siteCode} fleet',
          ));
          continue;
        }
      } else if (profile.target != ImportTarget.vehicles) {
        newCount++;
      }

      final dateValue = mapped['date'];
      if (dateValue != null && !_looksIsoDate(dateValue)) {
        errors.add(RowError(
          rowNumber: rowNumber,
          field: 'Date',
          message: 'Expected yyyy-MM-dd, got "$dateValue"',
        ));
        continue;
      }

      mapped[r'$row'] = '$rowNumber';
      rows.add(mapped);
    }

    final token = _store.newId();
    _staged[token] = _StagedImport(profile: profile, fileName: fileName, rows: rows);

    return ImportPreview(
      token: token,
      fileName: fileName,
      target: profile.target,
      rows: rows,
      errors: errors,
      totalRows: table.rows.length,
      newCount: newCount,
      updateCount: updateCount,
    );
  }

  @override
  Future<ImportRun> commit({
    required String siteCode,
    required String token,
  }) async {
    await Future<void>.delayed(_latency);
    final staged = _staged.remove(token);
    if (staged == null) {
      throw const ApiException('That preview has expired — re-upload the file');
    }

    _store.applyImport(staged.profile, staged.rows);

    final run = ImportRun(
      id: _store.newId(),
      siteCode: siteCode,
      profileName: staged.profile.name,
      target: staged.profile.target,
      fileName: staged.fileName,
      rowsAccepted: staged.rows.length,
      rowsRejected: 0,
      runAt: Dates.today(),
      runBy: _store.currentUserName,
    );
    _store.runs.insert(0, run);

    final i = _store.profiles.indexWhere((p) => p.id == staged.profile.id);
    if (i != -1) {
      _store.profiles[i] =
          _store.profiles[i].copyWith(lastRunAt: run.runAt);
    }
    return run;
  }

  @override
  Future<List<ImportRun>> fetchRuns(String siteCode) async {
    await Future<void>.delayed(_latency);
    return _store.runs.where((r) => r.siteCode == siteCode).toList();
  }

  void _assertCsv(String fileName) {
    if (!fileName.toLowerCase().endsWith('.csv')) {
      throw const ApiException(
        'The offline demo reads .csv only. Excel parsing runs on the server — '
        'point the app at the API to import .xlsx.',
      );
    }
  }

  static bool _looksIsoDate(String v) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v);
}

class _StagedImport {
  const _StagedImport({
    required this.profile,
    required this.fileName,
    required this.rows,
  });

  final ImportProfile profile;
  final String fileName;
  final List<Map<String, String>> rows;
}
