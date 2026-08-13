import 'dart:convert';
import 'dart:typed_data';

import '../../models/app_user.dart';
import '../../models/entry.dart';
import '../../models/site.dart';
import '../../models/site_config.dart';
import '../../models/site_import.dart';
import '../repositories.dart';
import 'api_client.dart';
import 'field_map.dart';

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
  Future<List<String>> siteCodes() async {
    final path = _api.capabilities.siteManagement ? '/sites' : '/master/depots';
    return itemsOf(await _api.get(path))
        .where((j) => j['is_active'] as bool? ?? true)
        .map((j) => j['code'] as String)
        .toList();
  }

  @override
  Future<List<String>> vehicleNumbers({required String siteCode}) async {
    if (_api.capabilities.siteManagement) {
      final json = await _api.get('/sites/$siteCode/vehicles',
          query: const <String, String>{'active': 'true'});
      return itemsOf(json).map((j) => j['registration_no'] as String).toList();
    }
    final json = await _api.get(
      '/master/buses',
      query: <String, String>{_api.capabilities.scopeParam: siteCode},
    );
    return itemsOf(json)
        .where((j) => j['is_active'] as bool? ?? true)
        .map((j) => j['bus_no'] as String)
        .toList();
  }

  @override
  Future<List<String>> defectSources() async =>
      _names(await _api.get('/master/defect-sources'));

  @override
  Future<List<String>> defectTypes() async =>
      _names(await _api.get('/master/defect-types'));

  @override
  Future<List<MasterListItem>> masterList(MasterListKind kind) async {
    final json = await _api.get(_masterPath(kind),
        query: const <String, String>{'include_inactive': 'true'});
    final raw = _rawItems(json);
    return <MasterListItem>[
      for (var i = 0; i < raw.length; i++)
        if (raw[i] is Map<String, dynamic>)
          MasterListItem.fromJson(raw[i] as Map<String, dynamic>)
        else
          // A legacy backend returns bare strings with no id or flags.
          MasterListItem(
            id: raw[i].toString(),
            name: raw[i].toString(),
            isActive: true,
            sortOrder: i,
          ),
    ];
  }

  @override
  Future<MasterListItem> addMasterItem(MasterListKind kind, String name) async {
    final json = await _api.post(
      _masterPath(kind),
      body: <String, dynamic>{'name': name.trim()},
    );
    return MasterListItem.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<MasterListItem> updateMasterItem(
    MasterListKind kind,
    MasterListItem item,
  ) async {
    final json = await _api.put(
      '${_masterPath(kind)}/${item.id}',
      body: <String, dynamic>{
        'name': item.name,
        'is_active': item.isActive,
        'sort_order': item.sortOrder,
      },
    );
    return MasterListItem.fromJson(json as Map<String, dynamic>);
  }

  static String _masterPath(MasterListKind kind) =>
      kind == MasterListKind.defectSources
          ? '/master/defect-sources'
          : '/master/defect-types';

  /// The master lists come back as bare strings on the current API and as
  /// objects once they become editable; accept both.
  ///
  /// Written as a loop rather than a collection-if: nesting an `if` inside a
  /// collection-`if` makes the `else` bind to the inner one.
  static List<String> _names(dynamic json) {
    final out = <String>[];
    for (final item in _rawItems(json)) {
      if (item is Map<String, dynamic>) {
        if (item['is_active'] as bool? ?? true) {
          out.add(item['name'] as String);
        }
      } else {
        out.add(item.toString());
      }
    }
    return out;
  }

  static List<dynamic> _rawItems(dynamic json) {
    if (json is List) return json;
    if (json is Map<String, dynamic> && json['items'] is List) {
      return json['items'] as List<dynamic>;
    }
    return const <dynamic>[];
  }
}

// ─── Sites ────────────────────────────────────────────────────────────────

class ApiSiteRepository implements SiteRepository {
  ApiSiteRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<Site>> fetchSites() async {
    if (_api.capabilities.siteManagement) {
      return itemsOf(await _api.get('/sites')).map(Site.fromJson).toList();
    }
    // Legacy backend: depots are read-only labels with no lifecycle.
    return itemsOf(await _api.get('/master/depots'))
        .map(
          (j) => Site(
            code: j['code'] as String,
            name: j['name'] as String? ?? j['code'] as String,
            isActive: true,
          ),
        )
        .toList();
  }

  @override
  Future<Site> createSite({
    required String code,
    required String name,
    String timezone = 'Asia/Kolkata',
    String address = '',
    String? commissionedOn,
  }) async {
    _requireSiteManagement();
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
    _requireSiteManagement();
    final json = await _api.put('/sites/${site.code}', body: site.toJson());
    return Site.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Site> setActive(String code, bool active) async {
    _requireSiteManagement();
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

  void _requireSiteManagement() {
    if (!_api.capabilities.siteManagement) {
      throw const UnsupportedByBackend(
        'This API version has fixed depots. Site onboarding needs the '
        'site-management release.',
      );
    }
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
    if (_api.capabilities.siteManagement) {
      final json = await _api.get(
        '/sites/$siteCode/vehicles',
        query: <String, String>{'include_inactive': '$includeInactive'},
      );
      return itemsOf(json).map(Vehicle.fromJson).toList();
    }
    // Legacy: the bus master is read-only and carries no id or specs.
    final json = await _api.get(
      '/master/buses',
      query: <String, String>{_api.capabilities.scopeParam: siteCode},
    );
    return itemsOf(json)
        .where((j) => includeInactive || (j['is_active'] as bool? ?? true))
        .map(
          (j) => Vehicle(
            id: j['bus_no'] as String,
            registrationNo: j['bus_no'] as String,
            siteCode: siteCode,
            isActive: j['is_active'] as bool? ?? true,
          ),
        )
        .toList();
  }

  @override
  Future<Vehicle> createVehicle({
    required String siteCode,
    required String registrationNo,
    String make = '',
    String model = '',
    double? batteryCapacityKwh,
  }) async {
    _requireSiteManagement();
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
    _requireSiteManagement();
    final json = await _api.put(
      '/sites/${vehicle.siteCode}/vehicles/${vehicle.id}',
      body: vehicle.toJson(),
    );
    return Vehicle.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Vehicle> setActive(String id, bool active) async {
    _requireSiteManagement();
    final json = await _api.post(
      '/vehicles/$id/${active ? 'activate' : 'deactivate'}',
    );
    return Vehicle.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<OdometerSyncResult> syncOdometers({required String siteCode}) async {
    _requireSiteManagement();
    final json = await _api.post('/sites/$siteCode/vehicles/odometer/sync');
    return OdometerSyncResult.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<Vehicle> setOdometer({
    required String vehicleId,
    required int odometerKm,
  }) async {
    _requireSiteManagement();
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
    _requireSiteManagement();
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

  void _requireSiteManagement() {
    if (!_api.capabilities.siteManagement) {
      throw const UnsupportedByBackend(
        'This API version has a read-only bus master. Fleet editing needs the '
        'site-management release.',
      );
    }
  }
}

// ─── Site config ──────────────────────────────────────────────────────────

class ApiSiteConfigRepository implements SiteConfigRepository {
  ApiSiteConfigRepository(this._api);

  final ApiClient _api;

  @override
  Future<SiteConfig> fetchConfig(String siteCode) async {
    _require();
    final json = await _api.get('/sites/$siteCode/config');
    return SiteConfig.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<SiteConfig> saveConfig(SiteConfig config) async {
    _require();
    final json = await _api.put(
      '/sites/${config.siteCode}/config',
      body: config.toJson(),
    );
    return SiteConfig.fromJson(json as Map<String, dynamic>);
  }

  void _require() {
    if (!_api.capabilities.siteManagement) {
      throw const UnsupportedByBackend(
        'Docking configuration needs the site-management release.',
      );
    }
  }
}

// ─── Imports ──────────────────────────────────────────────────────────────

class ApiImportRepository implements ImportRepository {
  ApiImportRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<ImportProfile>> fetchProfiles(String siteCode) async {
    _require();
    return itemsOf(await _api.get('/sites/$siteCode/import-profiles'))
        .map(ImportProfile.fromJson)
        .toList();
  }

  @override
  Future<ImportProfile> saveProfile(ImportProfile profile) async {
    _require();
    final base = '/sites/${profile.siteCode}/import-profiles';
    // A draft id is client-minted; the server assigns the real one on create.
    final json = profile.id.startsWith('draft-')
        ? await _api.post(base, body: profile.toJson())
        : await _api.put('$base/${profile.id}', body: profile.toJson());
    return ImportProfile.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    _require();
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
    _require();
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
    _require();
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
    _require();
    final json = await _api.post(
      '/sites/$siteCode/imports/commit',
      body: <String, dynamic>{'token': token},
    );
    return ImportRun.fromJson(json as Map<String, dynamic>);
  }

  @override
  Future<List<ImportRun>> fetchRuns(String siteCode) async {
    _require();
    return itemsOf(await _api.get('/sites/$siteCode/imports'))
        .map(ImportRun.fromJson)
        .toList();
  }

  /// Sent as a JSON string inside the multipart body so an unsaved mapping can
  /// still be previewed.
  static String _encodeMappings(ImportProfile profile) => jsonEncode(
        profile.mappings.where((m) => m.isBound).map((m) => m.toJson()).toList(),
      );

  void _require() {
    if (!_api.capabilities.siteManagement) {
      throw const UnsupportedByBackend(
        'Data import needs the site-management release.',
      );
    }
  }
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
        _api.capabilities.scopeParam: site,
        'page_size': '200',
      },
    );
    return itemsOf(json).map(_fromWire).toList();
  }

  @override
  Future<RegisterEntry> createEntry(RegisterEntry entry) async {
    final json = await _api.post('/entries', body: <String, dynamic>{
      'register': _registerToWire[entry.registerId],
      _api.capabilities.scopeParam: entry.site,
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
      site: (json['site'] ?? json['depot']) as String,
      enteredBy: createdBy is Map<String, dynamic>
          ? (createdBy['name'] as String? ?? '')
          : (createdBy?.toString() ?? ''),
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

  String get _accessKey =>
      _api.capabilities.siteManagement ? 'site_access' : 'depot_access';

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
      _accessKey: sites,
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
        if (!user.governsAllSites) _accessKey: user.sites,
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
          (json['site_access'] ?? json['depot_access']) as List<dynamic>? ??
              <dynamic>[],
        ),
        active: json['is_active'] as bool? ?? true,
        mustResetPassword: json['must_reset_password'] as bool? ?? false,
      );
}

// ─── Auth ─────────────────────────────────────────────────────────────────

class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository(this._api);

  final ApiClient _api;

  @override
  Future<AppUser> signInWithMicrosoft() async {
    // The Entra ID token comes from MSAL on device; until that is wired the
    // endpoint has nothing to validate.
    throw const ApiException(
      'Microsoft sign-in needs the MSAL client. Use your User ID and password.',
    );
  }

  @override
  Future<AppUser> signInWithCredentials({
    required String userId,
    required String password,
  }) async {
    final json = await _api.post('/auth/login', body: <String, dynamic>{
      'user_id': userId.trim().toUpperCase(),
      'password': password,
    }) as Map<String, dynamic>;

    await _api.setTokens(
      json['access_token'] as String?,
      json['refresh_token'] as String?,
    );
    // Which features exist depends on the backend release; ask once per session.
    await _api.detectCapabilities();

    return ApiUserRepository(_api)
        ._userFromWire(json['user'] as Map<String, dynamic>);
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
