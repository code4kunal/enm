import 'siteops_client.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:typed_data';

import '../../models/app_user.dart';
import '../../models/entry.dart';
import '../../models/checklist.dart';
import '../../models/inspection.dart';
import '../../models/report.dart';
import '../../models/site.dart';
import '../../models/site_config.dart';
import '../../models/site_import.dart';
import '../repositories.dart';
import 'api_client.dart';
import 'field_map.dart';
import 'siteops_client.dart';
import '../auth/ms_sso.dart';

/// Register id translation. The app uses the short ids from `registers.dart`;
/// the API uses the `Register` enum values.
const Map<String, String> _registerToWire = <String, String>{
  'work': 'work_done',
  'coolant': 'coolant',
  'complaint': 'driver_complaint',
  'breakdown': 'breakdown',
  'pm': 'pm_schedule',
};

final Map<String, String> _registerFromWire = <String, String>{
  for (final e in _registerToWire.entries) e.value: e.key,
};

// ─── Master data ──────────────────────────────────────────────────────────

class ApiMasterDataRepository implements MasterDataRepository {
  ApiMasterDataRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<String>> siteCodes() async =>
      itemsOf(await _api.get('/sites'))
          .where((j) => j['is_active'] as bool? ?? true)
          .map((j) => j['code'] as String)
          .toList();

  @override
  Future<List<String>> vehicleNumbers({required String siteCode}) async {
    try {
      final json = await siteOpsClient.get(
        '/master/vehicles',
        query: <String, String>{
          'site_id': siteCode,
          'page_size': '100',
        },
      );
      final data = (json is Map ? json['data'] : json) as List<dynamic>? ?? [];
      return data
          .map((j) => (j as Map<String, dynamic>)['vehicle_no']?.toString() ?? '')
          .where((v) => v.isNotEmpty)
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  Future<List<String>> defectSources() async =>
      _names(await siteOpsClient.get('/master/defect-sources', query: const <String, String>{'pagination': 'false'}));

  @override
  Future<List<String>> defectTypes() async =>
      _names(await siteOpsClient.get('/master/defect-types', query: const <String, String>{'pagination': 'false'}));

  @override
  Future<List<String>> staff({required String siteCode}) async {
    final json = await _api.get(
      '/master/staff',
      query: <String, String>{'site': siteCode},
    );
    return itemsOf(json).map((j) => j['name'] as String).toList();
  }

  @override
  Future<List<MasterListItem>> masterList(MasterListKind kind) async {
    final json = await siteOpsClient.get(
      _masterPath(kind),
      query: const <String, String>{
        'include_inactive': 'true',
        'page_size': '10',
        'page': '1',
      },
    );
    final List<dynamic> list = (json is Map)
        ? (json['data'] ?? json['items'] ?? const <dynamic>[])
        : (json is List ? json : const <dynamic>[]);
    return list.cast<Map<String, dynamic>>().map(MasterListItem.fromJson).toList();
  }

  @override
  Future<MasterListItem> addMasterItem(MasterListKind kind, String name) async {
    final json = await siteOpsClient.post(
      _masterPath(kind),
      body: <String, dynamic>{'name': name.trim()},
    );
    final map = (json is Map && json.containsKey('data'))
        ? json['data'] as Map<String, dynamic>
        : json as Map<String, dynamic>;
    return MasterListItem.fromJson(map);
  }

  @override
  Future<MasterListItem> updateMasterItem(
    MasterListKind kind,
    MasterListItem item,
  ) async {
    final json = await siteOpsClient.put(
      '${_masterPath(kind)}/${item.id}',
      body: <String, dynamic>{
        'name': item.name,
        'is_active': item.isActive,
        'sort_order': item.sortOrder,
      },
    );
    final map = (json is Map && json.containsKey('data'))
        ? json['data'] as Map<String, dynamic>
        : json as Map<String, dynamic>;
    return MasterListItem.fromJson(map);
  }

  static String _masterPath(MasterListKind kind) =>
      kind == MasterListKind.defectSources
          ? '/master/defect-sources'
          : '/master/defect-types';

  /// Names for a dropdown. The server already filters inactive rows here; the
  /// flag is re-checked so a stale response cannot reintroduce a hidden value.
  static List<String> _names(dynamic json) {
    List<dynamic> list = [];
    if (json is List) {
      list = json;
    } else if (json is Map) {
      list = json['data'] ?? json['items'] ?? [];
    }
    return list
        .where((j) => (j as Map)['is_active'] as bool? ?? true)
        .map((j) => (j as Map)['name'] as String)
        .toList();
  }
}

// ─── Sites ────────────────────────────────────────────────────────────────

class ApiSiteRepository implements SiteRepository {
  ApiSiteRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<Site>> fetchSites() async =>
      itemsOf(await _api.get('/sites')).map(Site.fromJson).toList();

  @override
  Future<Site> createSite({
    required String code,
    required String name,
    String timezone = 'Asia/Kolkata',
    String address = '',
    String? commissionedOn,
  }) async {
    final json = await _api.post('/sites', body: <String, dynamic>{
      'code': code,
      'name': name,
      'timezone': timezone,
      'address': address,
      'commissioned_on': commissionedOn,
    });
    return Site.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Site> updateSite(Site site) async {
    final json = await _api.put('/sites/${site.code}', body: site.toJson());
    return Site.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Site> setActive(String code, bool active) async {
    final json = await _api.post(
      '/sites/$code/${active ? 'activate' : 'deactivate'}',
    );
    return Site.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<bool> isCodeTaken(String code) async {
    final sites = await fetchSites();
    final needle = code.trim().toUpperCase();
    return sites.any((s) => s.code.toUpperCase() == needle);
  }

}

// ─── Vehicles ─────────────────────────────────────────────────────────────

class ApiVehicleRepository implements VehicleRepository {
  ApiVehicleRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<Vehicle>> fetchVehicles({
    required String siteCode,
    bool includeInactive = false,
  }) async {
    final json = await _api.get(
      '/sites/$siteCode/vehicles',
      query: <String, String>{'include_inactive': '$includeInactive'},
    );
    return itemsOf(json).map(Vehicle.fromJson).toList();
  }

  @override
  Future<Vehicle> createVehicle({
    required String siteCode,
    required String registrationNo,
    String make = '',
    String model = '',
    double? batteryCapacityKwh,
  }) async {
    final json = await _api.post(
      '/sites/$siteCode/vehicles',
      body: <String, dynamic>{
        'registration_no': Vehicle.normalise(registrationNo),
        'make': make,
        'model': model,
        'battery_capacity_kwh': batteryCapacityKwh,
      },
    );
    return Vehicle.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Vehicle> updateVehicle(Vehicle vehicle) async {
    final json = await _api.put(
      '/sites/${vehicle.siteCode}/vehicles/${vehicle.id}',
      body: vehicle.toJson(),
    );
    return Vehicle.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Vehicle> setActive(String id, bool active) async {
    final json = await _api.post(
      '/vehicles/$id/${active ? 'activate' : 'deactivate'}',
    );
    return Vehicle.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<OdometerSyncResult> syncOdometers({required String siteCode}) async {
    final json = await _api.post('/sites/$siteCode/vehicles/odometer/sync');
    return OdometerSyncResult.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Vehicle> setOdometer({
    required String vehicleId,
    required int odometerKm,
  }) async {
    final json = await _api.put(
      '/vehicles/$vehicleId/odometer',
      body: <String, dynamic>{'odometer_km': odometerKm},
    );
    return Vehicle.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Vehicle> recordService({
    required String vehicleId,
    required String planCode,
    required int odometerKm,
    required String servicedOn,
  }) async {
    final json = await _api.post(
      '/vehicles/$vehicleId/services',
      body: <String, dynamic>{
        'plan_code': planCode,
        'odometer_km': odometerKm,
        'serviced_on': servicedOn,
      },
    );
    return Vehicle.fromJson(json as Map<String, dynamic>);
  }

}

// ─── Site config ──────────────────────────────────────────────────────────

class ApiSiteConfigRepository implements SiteConfigRepository {
  ApiSiteConfigRepository(this._api);

  final ApiClient _api;

  @override
  Future<SiteConfig> fetchConfig(String siteCode) async {
    final json = await _api.get('/sites/$siteCode/config');
    return SiteConfig.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<SiteConfig> saveConfig(SiteConfig config) async {
    final json = await _api.put(
      '/sites/${config.siteCode}/config',
      body: config.toJson(),
    );
    return SiteConfig.fromJson(json as Map<String, dynamic>);
  }

}

// ─── Imports ──────────────────────────────────────────────────────────────

class ApiImportRepository implements ImportRepository {
  ApiImportRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<ImportProfile>> fetchProfiles(String siteCode) async {
    return itemsOf(await _api.get('/sites/$siteCode/import-profiles'))
        .map(ImportProfile.fromJson)
        .toList();
  }

  @override
  Future<ImportProfile> saveProfile(ImportProfile profile) async {
    final base = '/sites/${profile.siteCode}/import-profiles';
    // A draft id is client-minted; the server assigns the real one on create.
    final json = profile.id.startsWith('draft-')
        ? await _api.post(base, body: profile.toJson())
        : await _api.put('$base/${profile.id}', body: profile.toJson());
    return ImportProfile.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    await _api.delete('/import-profiles/$profileId');
  }

  @override
  Future<SourceInspection> inspect({
    required String siteCode,
    required String fileName,
    required Uint8List bytes,
    String? sheetName,
    int headerRow = 1,
  }) async {
    final json = await _api.upload(
      '/sites/$siteCode/imports/inspect',
      field: 'file',
      fileName: fileName,
      bytes: bytes,
      fields: <String, String>{
        'header_row': '$headerRow',
        if (sheetName != null) 'sheet_name': sheetName,
      },
    );
    return SourceInspection.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<ImportPreview> preview({
    required ImportProfile profile,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final json = await _api.upload(
      '/sites/${profile.siteCode}/imports/preview',
      field: 'file',
      fileName: fileName,
      bytes: bytes,
      fields: <String, String>{
        'target': profile.target.name,
        'header_row': '${profile.headerRow}',
        'skip_rows': '${profile.skipRows}',
        if (profile.sheetName != null) 'sheet_name': profile.sheetName!,
        // Sent inline so an unsaved mapping can still be previewed.
        'mappings': _encodeMappings(profile),
      },
    );
    return ImportPreview.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<ImportRun> commit({
    required String siteCode,
    required String token,
  }) async {
    final json = await _api.post(
      '/sites/$siteCode/imports/commit',
      body: <String, dynamic>{'token': token},
    );
    return ImportRun.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<ImportRun>> fetchRuns(String siteCode) async {
    return itemsOf(await _api.get('/sites/$siteCode/imports'))
        .map(ImportRun.fromJson)
        .toList();
  }

  /// Sent as a JSON string inside the multipart body so an unsaved mapping can
  /// still be previewed.
  static String _encodeMappings(ImportProfile profile) => jsonEncode(
        profile.mappings.where((m) => m.isBound).map((m) => m.toJson()).toList(),
      );

}

// ─── Entries ──────────────────────────────────────────────────────────────

class ApiEntryRepository implements EntryRepository {
  ApiEntryRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<RegisterEntry>> fetchEntries({required String site}) async {
    final json = await _api.get(
      '/entries',
      query: <String, String>{
        'site': site,
        'page_size': '200',
      },
    );
    return itemsOf(json).map(_fromWire).toList();
  }

  @override
  Future<RegisterEntry> createEntry(RegisterEntry entry) async {
    final json = await _api.post('/entries', body: <String, dynamic>{
      'register': _registerToWire[entry.registerId],
      'site': entry.site,
      'date': entry.date,
      'entry_time': entry.time,
      'data': RegisterFieldMap.toWire(entry.registerId, entry.data),
    });
    return _fromWire(json as Map<String, dynamic>);
  }

  @override
  Future<RegisterEntry> updateEntry(RegisterEntry entry) async {
    final json = await _api.put(
      '/entries/${entry.id}',
      body: <String, dynamic>{
        'date': entry.date,
        'data': RegisterFieldMap.toWire(entry.registerId, entry.data),
      },
    );
    return _fromWire(json as Map<String, dynamic>);
  }

  @override
  Future<RegisterEntry> setStatus(String entryId, EntryStatus status) async {
    if (status != EntryStatus.done) {
      throw const ApiException('Only resolving a breakdown is supported');
    }
    final json = await _api.post('/entries/$entryId/resolve');
    return _fromWire(json as Map<String, dynamic>);
  }

  RegisterEntry _fromWire(Map<String, dynamic> json) {
    final createdBy = json['created_by'];
    final registerId = _registerFromWire[json['register'] as String] ?? 'work';

    // The API's data object uses each register's own column names; translate
    // it back into the keys the form and the register definitions use.
    final data = RegisterFieldMap.fromWire(
      registerId,
      json['data'] as Map<String, dynamic>? ?? <String, dynamic>{},
    );
    final busNo = json['bus_no'] as String?;
    if (busNo != null && !data.containsKey('bus')) data['bus'] = busNo;

    return RegisterEntry(
      id: json['id'] as String,
      registerId: registerId,
      date: json['date'] as String,
      time: (json['entry_time'] as String? ?? '00:00').substring(0, 5),
      site: json['site'] as String,
      // Who did the work, per the register — not the account that typed it.
      // The server resolves it and falls back to the author itself.
      enteredBy: (json['entered_by'] as String?)?.trim().isNotEmpty ?? false
          ? json['entered_by'] as String
          : (createdBy is Map<String, dynamic>
              ? (createdBy['name'] as String? ?? '')
              : (createdBy?.toString() ?? '')),
      data: data,
      // The API distinguishes done from resolved; the tracker only cares
      // whether a breakdown is still open.
      status: (json['status'] as String?) == 'open'
          ? EntryStatus.open
          : EntryStatus.done,
    );
  }
}

// ─── Users ────────────────────────────────────────────────────────────────

class ApiUserRepository implements UserRepository {
  ApiUserRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<AppUser>> fetchUsers() async {
    final json = await _api.get(
      '/admin/users',
      query: const <String, String>{'page_size': '200'},
    );
    return itemsOf(json).map(_userFromWire).toList();
  }

  @override
  Future<({AppUser user, String temporaryPassword})> createUser({
    required String name,
    required String userId,
    required String email,
    required UserRole role,
    required List<String> sites,
    String? password,
  }) async {
    final json = await _api.post('/admin/users', body: <String, dynamic>{
      'name': name,
      'user_id': userId,
      'email': email.isEmpty ? null : email,
      'role': role.wireName,
      'site_access': sites,
      if (password != null && password.isNotEmpty) 'temp_password': password,
    }) as Map<String, dynamic>;

    return (
      user: _userFromWire(json),
      // The server echoes the generated password exactly once.
      temporaryPassword:
          json['temp_password'] as String? ?? password ?? '(sent to the user)',
    );
  }

  @override
  Future<AppUser> updateUser(AppUser user) async {
    final json = await _api.put(
      '/admin/users/${user.id}',
      body: <String, dynamic>{
        'name': user.name,
        'user_id': user.userId,
        'email': user.email.isEmpty ? null : user.email,
        'role': user.role.wireName,
        if (!user.governsAllSites) 'site_access': user.sites,
      },
    );
    return _userFromWire(json as Map<String, dynamic>);
  }

  @override
  Future<AppUser> setActive(String id, bool active) async {
    final json = await _api.post(
      '/admin/users/$id/${active ? 'activate' : 'deactivate'}',
    );
    return _userFromWire(json as Map<String, dynamic>);
  }

  @override
  Future<String> resetPassword(String id, {String? password}) async {
    final json = await _api.post(
      '/admin/users/$id/reset-password',
      body: password == null || password.isEmpty
          ? null
          : <String, dynamic>{'temp_password': password},
    );
    if (json is Map<String, dynamic>) {
      return json['temp_password'] as String? ??
          json['password'] as String? ??
          password ??
          '(sent to the user)';
    }
    return password ?? '(sent to the user)';
  }

  @override
  Future<bool> isUserIdTaken(String userId, {String? exceptId}) async {
    // The server enforces uniqueness; this only pre-empts the round trip.
    final users = await fetchUsers();
    final needle = userId.trim().toUpperCase();
    return users
        .any((u) => u.userId.toUpperCase() == needle && u.id != exceptId);
  }

  AppUser _userFromWire(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        userId: json['user_id'] as String,
        email: json['email'] as String? ?? '',
        role: UserRole.fromWire(json['role'] as String?),
        sites: List<String>.from(
          json['site_access'] as List<dynamic>? ?? <dynamic>[],
        ),
        active: json['is_active'] as bool? ?? true,
        mustResetPassword: json['must_reset_password'] as bool? ?? false,
      );
}

// ─── Auth ─────────────────────────────────────────────────────────────────

class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository(this._api, {MicrosoftSignIn? sso})
      : _sso = sso ?? MicrosoftSignIn(_api);

  final ApiClient _api;
  final MicrosoftSignIn _sso;

  @override
  Future<SsoConfig> ssoConfig() => _sso.config();

  @override
  Future<void> beginMicrosoftSignIn(SsoConfig config) => _sso.begin(config);

  @override
  Future<AppUser?> completeMicrosoftSignIn(SsoConfig config) async {
    final idToken = await _sso.complete(config);
    if (idToken == null) return null;
    final json = await _api.post(
      '/auth/sso',
      body: <String, dynamic>{'ms_id_token': idToken},
    ) as Map<String, dynamic>;

    await _api.setTokens(
      json['access_token'] as String?,
      json['refresh_token'] as String?,
    );
    return ApiUserRepository(_api)
        ._userFromWire(json['user'] as Map<String, dynamic>);
  }

  @override
  Future<AppUser> signInWithCredentials({
    required String userId,
    required String password,
  }) async {
    final response = await http.post(
      Uri.parse('${SiteOpsConfig.baseUrl}/auth/login'),
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{
        'username': userId.trim(),
        'password': password,
      },
    );

    if (response.statusCode >= 400) {
      try {
        final errJson = jsonDecode(response.body) as Map<String, dynamic>;
        throw ApiException(errJson['message'] as String? ?? 'Login failed');
      } catch (e) {
        if (e is ApiException) rethrow;
        throw ApiException('HTTP ${response.statusCode}: ${response.reasonPhrase}');
      }
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>;

    final access = data['access_token'] as String?;
    final refresh = data['refresh_token'] as String?;
    await _api.setTokens(access, refresh);

    final siteopsRole = (data['roles'] as List<dynamic>?)?.firstOrNull?.toString() ?? 'executive';
    final String mappedRole = (siteopsRole == 'admin') ? 'super_admin' : siteopsRole;

    return AppUser(
      id: data['user_id'] as String? ?? 'siteops_user_id',
      name: data['full_name'] as String? ?? data['username'] as String? ?? 'SiteOps User',
      userId: (data['username'] as String? ?? userId).toUpperCase(),
      email: data['email'] as String? ?? '',
      role: UserRole.fromWire(mappedRole),
      sites: List<String>.from(data['site_ids'] as List<dynamic>? ?? <dynamic>[]),
      active: true,
      mustResetPassword: false,
    );
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _api.post('/auth/change-password', body: <String, dynamic>{
      'current_password': currentPassword,
      'new_password': newPassword,
    });
  }

  @override
  Future<void> signOut() async {
    try {
      await _api.post('/auth/logout');
    } on ApiException {
      // A dead session is still a successful sign-out from the user's side.
    }
    await _api.clearTokens();
  }
}

// ─── Inspection schedule ──────────────────────────────────────────────────

class ApiInspectionRepository implements InspectionRepository {
  ApiInspectionRepository(this._api);

  final ApiClient _api;

  @override
  Future<InspectionCalendar> fetchCalendar({
    required String siteCode,
    required String from,
    required String to,
  }) async {
    final json = await _api.get(
      '/sites/$siteCode/inspections/calendar',
      query: <String, String>{'from': from, 'to': to},
    );
    return InspectionCalendar.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<GenerationResult> generate(String siteCode) async {
    final json = await _api.post('/sites/$siteCode/inspections/generate');
    return GenerationResult.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<InspectionSlot> createSlot({
    required String siteCode,
    required String vehicleId,
    required int workTypeId,
    required String scheduledOn,
    String notes = '',
  }) async {
    final json = await _api.post(
      '/sites/$siteCode/inspections/slots',
      body: <String, dynamic>{
        'vehicle_id': vehicleId,
        'work_type_id': workTypeId,
        'scheduled_on': scheduledOn,
        'notes': notes,
      },
    );
    return InspectionSlot.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<InspectionSlot> updateSlot(
    InspectionSlot slot, {
    String? scheduledOn,
    SlotStatus? status,
    String? notes,
  }) async {
    final json = await _api.put(
      '/inspection-slots/${slot.id}',
      body: <String, dynamic>{
        if (scheduledOn != null) 'scheduled_on': scheduledOn,
        if (status != null) 'status': status.name,
        if (notes != null) 'notes': notes,
      },
    );
    return InspectionSlot.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> deleteSlot(String slotId) =>
      _api.delete('/inspection-slots/$slotId');

  @override
  Future<List<InspectionPlan>> fetchPlans(String siteCode) async =>
      itemsOf(await _api.get('/sites/$siteCode/inspections/plans'))
          .map(InspectionPlan.fromJson)
          .toList();

  @override
  Future<List<InspectionPlan>> savePlans(
    String siteCode,
    List<InspectionPlan> plans,
  ) async {
    final json = await _api.put(
      '/sites/$siteCode/inspections/plans',
      body: <String, dynamic>{
        'items': plans.map((p) => p.toJson()).toList(),
      },
    );
    return itemsOf(json).map(InspectionPlan.fromJson).toList();
  }

  @override
  Future<List<SiteAlert>> fetchAlerts(
    String siteCode, {
    String status = 'open',
  }) async =>
      itemsOf(await _api.get(
        '/sites/$siteCode/alerts',
        query: <String, String>{'status': status},
      )).map(SiteAlert.fromJson).toList();

  @override
  Future<SiteAlert> acknowledgeAlert(String alertId) async {
    final json = await _api.post('/alerts/$alertId/acknowledge');
    return SiteAlert.fromJson(json as Map<String, dynamic>);
  }
}

// ─── Checklists and inspections ───────────────────────────────────────────

class ApiChecklistRepository implements ChecklistRepository {
  ApiChecklistRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<Checklist>> fetchChecklists(String siteCode) async =>
      itemsOf(await _api.get('/sites/$siteCode/checklists'))
          .map(Checklist.fromJson)
          .toList();

  @override
  Future<Checklist> saveChecklist(String siteCode, Checklist checklist) async {
    final json = await _api.put(
      '/sites/$siteCode/checklists/${checklist.workTypeId}',
      body: <String, dynamic>{
        'name': checklist.name,
        'items': checklist.items.map((i) => i.toJson()).toList(),
      },
    );
    return Checklist.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<InspectionEntry> recordInspection({
    required String siteCode,
    required String vehicleId,
    required int workTypeId,
    required String inspectedOn,
    String? entryTime,
    String? doneBy,
    String? supervisor,
    int? odometerKm,
    String? remarks,
    required List<InspectionResult> results,
  }) async {
    final json = await _api.post(
      '/sites/$siteCode/inspections',
      body: <String, dynamic>{
        'vehicle_id': vehicleId,
        'work_type_id': workTypeId,
        'inspected_on': inspectedOn,
        if (entryTime != null && entryTime.isNotEmpty) 'entry_time': entryTime,
        if (doneBy != null && doneBy.isNotEmpty) 'done_by': doneBy,
        if (supervisor != null && supervisor.isNotEmpty) 'supervisor': supervisor,
        if (odometerKm != null) 'odometer_km': odometerKm,
        if (remarks != null && remarks.isNotEmpty) 'remarks': remarks,
        'results': results.map((r) => r.toJson()).toList(),
      },
    );
    return InspectionEntry.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<InspectionEntry>> fetchInspections(
    String siteCode, {
    int? workTypeId,
  }) async =>
      itemsOf(await _api.get(
        '/sites/$siteCode/inspections',
        query: <String, String>{
          if (workTypeId != null) 'work_type_id': '$workTypeId',
        },
      )).map(InspectionEntry.fromJson).toList();

  @override
  Future<List<InspectionEntry>> todaysInspections(String siteCode) async =>
      itemsOf(await _api.get('/sites/$siteCode/inspections/today'))
          .map(InspectionEntry.fromJson)
          .toList();
}

// ─── Reports ──────────────────────────────────────────────────────────────

class ApiReportRepository implements ReportRepository {
  ApiReportRepository(this._api);

  final ApiClient _api;

  @override
  Future<DmrDay> fetchDmr({
    required String siteCode,
    required String date,
  }) async {
    final json = await _api.get(
      '/sites/$siteCode/reports/dmr',
      query: <String, String>{'date': date},
    );
    return DmrDay.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<DmrDay> saveDmrEntered({
    required String siteCode,
    required String date,
    required Map<String, int?> values,
    String? notes,
  }) async {
    final json = await _api.put(
      '/sites/$siteCode/reports/dmr',
      query: <String, String>{'date': date},
      body: <String, dynamic>{
        ...values,
        if (notes != null) 'notes': notes,
      },
    );
    return DmrDay.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<DmrDay> snapshotDmr({
    required String siteCode,
    required String date,
  }) async {
    final json = await _api.post(
      '/sites/$siteCode/reports/dmr/snapshot',
      query: <String, String>{'date': date},
    );
    return DmrDay.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<DmrMonth> fetchDmrMonth({
    required String siteCode,
    required String month,
  }) async {
    final json = await _api.get(
      '/sites/$siteCode/reports/dmr/month',
      query: <String, String>{'month': month},
    );
    return DmrMonth.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<OffRoadCase>> fetchOffRoad({
    required String siteCode,
    required String date,
  }) async =>
      itemsOf(await _api.get(
        '/sites/$siteCode/reports/off-road',
        query: <String, String>{'date': date},
      )).map(OffRoadCase.fromJson).toList();

  @override
  Future<OffRoadCase> saveOffRoad({
    required String siteCode,
    required String vehicleId,
    required String issue,
    required DefectCategory category,
    String? offRoadSince,
    String? actionTaken,
    int? expectedDays,
    String? spareParts,
    String? remarks,
    bool awaitingVendor = false,
  }) async {
    final json = await _api.post(
      '/sites/$siteCode/reports/off-road',
      body: <String, dynamic>{
        'vehicle_id': vehicleId,
        'issue': issue,
        'category': category.wireName,
        if (offRoadSince != null) 'off_road_since': offRoadSince,
        if (actionTaken != null && actionTaken.isNotEmpty)
          'action_taken': actionTaken,
        if (expectedDays != null) 'expected_days': expectedDays,
        if (spareParts != null && spareParts.isNotEmpty)
          'spare_parts_required': spareParts,
        if (remarks != null && remarks.isNotEmpty) 'remarks': remarks,
        'awaiting_vendor': awaitingVendor,
      },
    );
    return OffRoadCase.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<OffRoadCase> closeOffRoad({
    required String caseId,
    required String returnedOn,
  }) async {
    final json = await _api.post(
      '/off-road/$caseId/close',
      body: <String, dynamic>{'returned_on': returnedOn},
    );
    return OffRoadCase.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<InvestigationDay> fetchInvestigations({
    required String siteCode,
    required String date,
  }) async {
    final json = await _api.get(
      '/sites/$siteCode/reports/investigations',
      query: <String, String>{'date': date},
    );
    return InvestigationDay.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Investigation> openInvestigation(String entryId) async {
    final json = await _api.get('/breakdowns/$entryId/investigation');
    return Investigation.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Investigation> saveInvestigation(
    String entryId, {
    String? findings,
    String? investigationAction,
    String? lastPmFindings,
    String? relatedComplaints,
  }) async {
    final json = await _api.put(
      '/breakdowns/$entryId/investigation',
      body: <String, dynamic>{
        if (findings != null) 'findings': findings,
        if (investigationAction != null)
          'investigation_action': investigationAction,
        if (lastPmFindings != null) 'last_pm_findings': lastPmFindings,
        if (relatedComplaints != null) 'related_complaints': relatedComplaints,
      },
    );
    return Investigation.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<ChartKind>> fetchChartKinds() async =>
      (await _api.get('/reports/control-charts') as List<dynamic>)
          .map((e) => ChartKind.fromJson(e as Map<String, dynamic>))
          .toList();

  @override
  Future<ControlChart> fetchControlChart({
    required String siteCode,
    required String kind,
    required String fromDate,
    required String toDate,
  }) async {
    final json = await _api.get(
      '/sites/$siteCode/reports/control-charts/$kind',
      query: <String, String>{'from': fromDate, 'to': toDate},
    );
    return ControlChart.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<UnitType>> fetchUnitTypes() async =>
      (await _api.get('/unit-types') as List<dynamic>)
          .map((e) => UnitType.fromJson(e as Map<String, dynamic>))
          .toList();

  @override
  Future<List<FittedUnit>> fetchUnitFailures({
    required String siteCode,
    required String month,
  }) async =>
      itemsOf(await _api.get(
        '/sites/$siteCode/reports/unit-failures',
        query: <String, String>{'month': month},
      )).map(FittedUnit.fromJson).toList();

  @override
  Future<List<FittedUnit>> fetchFittedUnits({
    required String siteCode,
    required String vehicleId,
  }) async =>
      itemsOf(await _api.get(
        '/sites/$siteCode/units',
        query: <String, String>{'vehicle_id': vehicleId},
      )).map(FittedUnit.fromJson).toList();

  @override
  Future<FittedUnit> fitUnit({
    required String siteCode,
    required String vehicleId,
    required int unitTypeId,
    required String fittedOn,
    String? unitNo,
    int? fittedOdometerKm,
    String? remarks,
  }) async {
    final json = await _api.post(
      '/sites/$siteCode/units',
      body: <String, dynamic>{
        'vehicle_id': vehicleId,
        'unit_type_id': unitTypeId,
        'fitted_on': fittedOn,
        if (unitNo != null && unitNo.isNotEmpty) 'unit_no': unitNo,
        if (fittedOdometerKm != null) 'fitted_odometer_km': fittedOdometerKm,
        if (remarks != null && remarks.isNotEmpty) 'remarks': remarks,
      },
    );
    return FittedUnit.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<FittedUnit> removeUnit(
    String unitId, {
    required String removedOn,
    int? removedOdometerKm,
    String? removalReason,
    String? remarks,
  }) async {
    final json = await _api.post(
      '/units/$unitId/remove',
      body: <String, dynamic>{
        'removed_on': removedOn,
        if (removedOdometerKm != null) 'removed_odometer_km': removedOdometerKm,
        if (removalReason != null && removalReason.isNotEmpty)
          'removal_reason': removalReason,
        if (remarks != null && remarks.isNotEmpty) 'remarks': remarks,
      },
    );
    return FittedUnit.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<BusHistory> fetchBusHistory({
    required String siteCode,
    required String vehicleId,
    required String toMonth,
  }) async {
    final json = await _api.get(
      '/sites/$siteCode/reports/bus-history/$vehicleId',
      query: <String, String>{'to': toMonth},
    );
    return BusHistory.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<ReportFile> downloadReport(
    ReportDoc doc, {
    required String siteCode,
    String? date,
    String? month,
    String? chartKind,
    String? fromDate,
    String? toDate,
    String? vehicleId,
  }) async {
    final site = '/sites/$siteCode/reports';
    final (String path, Map<String, String> query) = switch (doc) {
      ReportDoc.dmrDay => ('$site/dmr/day/export', <String, String>{
          if (date != null) 'date': date,
        }),
      ReportDoc.dmrMonth => ('$site/dmr/export', <String, String>{
          if (month != null) 'month': month,
          'format': 'pdf',
        }),
      ReportDoc.controlChart => (
          '$site/control-charts/${chartKind ?? ''}/export',
          <String, String>{
            if (fromDate != null) 'from': fromDate,
            if (toDate != null) 'to': toDate,
            'format': 'pdf',
          }
        ),
      ReportDoc.offRoad => ('$site/off-road/export', <String, String>{
          if (date != null) 'date': date,
        }),
      ReportDoc.investigations => ('$site/investigations/export', <String, String>{
          if (date != null) 'date': date,
        }),
      ReportDoc.unitFailures => ('$site/unit-failures/export', <String, String>{
          if (month != null) 'month': month,
          'format': 'pdf',
        }),
      ReportDoc.busHistory => (
          '$site/bus-history/${vehicleId ?? ''}/export',
          <String, String>{if (month != null) 'to': month},
        ),
    };

    return ReportFile(
      name: _pdfName(doc, siteCode, date ?? month ?? ''),
      bytes: await _api.download(path, query: query),
    );
  }

  /// The server sets the real filename on the response; this is what the
  /// share sheet shows if the platform needs a name up front.
  static String _pdfName(ReportDoc doc, String site, String period) {
    final kind = switch (doc) {
      ReportDoc.dmrDay => 'dmr',
      ReportDoc.dmrMonth => 'dmr-month',
      ReportDoc.controlChart => 'control-chart',
      ReportDoc.offRoad => 'off-road',
      ReportDoc.investigations => 'investigations',
      ReportDoc.unitFailures => 'unit-failures',
      ReportDoc.busHistory => 'bus-history',
    };
    final stem = <String>[site, kind, period].where((p) => p.isNotEmpty).join('-');
    return '${stem.toLowerCase()}.pdf';
  }
}
