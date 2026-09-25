import 'package:transvolt_em/models/app_user.dart';
import 'package:transvolt_em/models/driver.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/models/site.dart';
import 'package:transvolt_em/models/spare_part.dart';
import 'package:transvolt_em/models/staff.dart';
import 'package:transvolt_em/models/ticket.dart';
import 'package:transvolt_em/data/api/api_repositories.dart' show registerToWire;
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/data/registers.dart';
import 'package:transvolt_em/state/entries.dart' show entrySummary;
import 'fake_store.dart';
import 'seed.dart';
import 'package:transvolt_em/data/auth/ms_sso.dart';

const Duration _latency = Duration(milliseconds: 220);

// ─── Master data ──────────────────────────────────────────────────────────

class FakeMasterDataRepository implements MasterDataRepository {
  FakeMasterDataRepository(this._store);

  final FakeStore _store;

  @override
  Future<List<String>> siteCodes() async {
    await Future<void>.delayed(_latency);
    return _store.visibleSites().where((s) => s.isActive).map((s) => s.code).toList();
  }

  @override
  Future<List<String>> vehicleNumbers({
    required String siteCode,
    String? siteOpsSiteId,
  }) async {
    await Future<void>.delayed(_latency);
    // Fakes have no SiteOps fleet — scope by E&M code only.
    return activeVehicleNumbers(_store, siteCode);
  }

  @override
  Future<List<String>> defectSources() async {
    await Future<void>.delayed(_latency);
    return _activeNames(_store.defectSources);
  }

  @override
  Future<List<String>> defectTypes() async {
    await Future<void>.delayed(_latency);
    return _activeNames(_store.defectTypes);
  }

  @override
  Future<List<String>> staff({required String siteCode}) async =>
      _store.users
          .where((u) => u.active && u.canAccess(siteCode))
          .map((u) => u.name)
          .toList();

  @override
  Future<List<StaffMember>> staffDirectory({required String siteCode}) async {
    await Future<void>.delayed(_latency);
    return _store.users
        .where((u) => u.active && u.canAccess(siteCode))
        .map((u) => StaffMember(id: u.id, name: u.name))
        .toList();
  }

  @override
  Future<List<SparePart>> sparePartDirectory({required String siteCode}) async {
    await Future<void>.delayed(_latency);
    return List<SparePart>.of(_store.spareParts);
  }

  @override
  Future<SparePart> createSparePart({
    required String siteCode,
    required String partNo,
    required String name,
  }) async {
    await Future<void>.delayed(_latency);
    final normalized = partNo.trim().toUpperCase();
    if (_store.spareParts.any((p) => p.partNo == normalized)) {
      throw ApiException('"$normalized" already exists');
    }
    final part = SparePart(id: _store.newId(), partNo: normalized, name: name.trim());
    _store.spareParts.add(part);
    return part;
  }

  @override
  Future<List<String>> technicianStaff({required String siteName, String? siteId}) async =>
      _store.users
          .where((u) => u.active && u.role == UserRole.executive)
          .map((u) => u.name)
          .toList();

  @override
  Future<List<String>> supervisorStaff({required String siteName, String? siteId}) async =>
      _store.users
          .where((u) => u.active && u.role == UserRole.supervisor)
          .map((u) => u.name)
          .toList();

  @override
  Future<List<String>> mechanicStaff({required String siteName, String? siteId}) async =>
      _store.users
          .where((u) => u.active && u.role == UserRole.executive) // or filter appropriately
          .map((u) => u.name)
          .toList();

  @override
  Future<List<String>> drivers({required String siteCode}) async {
    await Future<void>.delayed(_latency);
    return _store.drivers.map((d) => d.driverCode).toList();
  }

  @override
  Future<Driver> createDriver({
    required String siteCode,
    required String driverCode,
    required String name,
  }) async {
    await Future<void>.delayed(_latency);
    final normalized = driverCode.trim().toUpperCase();
    if (_store.drivers.any((d) => d.driverCode == normalized)) {
      throw ApiException('"$normalized" already exists');
    }
    final driver = Driver(id: _store.newId(), driverCode: normalized, name: name.trim());
    _store.drivers.add(driver);
    return driver;
  }

  @override
  Future<List<MasterListItem>> masterList(MasterListKind kind) async {
    await Future<void>.delayed(_latency);
    return List<MasterListItem>.of(_listFor(kind))
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  @override
  Future<MasterListItem> addMasterItem(MasterListKind kind, String name) async {
    await Future<void>.delayed(_latency);
    final list = _listFor(kind);
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const ApiException('Name is required');
    if (_store.findMasterItem(list, trimmed) != null) {
      throw ApiException('"$trimmed" is already on the list');
    }
    final item = MasterListItem(
      id: _store.newId(),
      name: trimmed,
      isActive: true,
      sortOrder: list.length,
    );
    list.add(item);
    return item;
  }

  @override
  Future<MasterListItem> updateMasterItem(
    MasterListKind kind,
    MasterListItem item,
  ) async {
    await Future<void>.delayed(_latency);
    final list = _listFor(kind);
    final i = list.indexWhere((m) => m.id == item.id);
    if (i == -1) throw ApiException('${item.name} not found');
    list[i] = item;
    return item;
  }

  List<MasterListItem> _listFor(MasterListKind kind) =>
      kind == MasterListKind.defectSources
          ? _store.defectSources
          : _store.defectTypes;

  static List<String> _activeNames(List<MasterListItem> list) {
    final active = list.where((m) => m.isActive).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return active.map((m) => m.name).toList();
  }
}

// ─── Entries ──────────────────────────────────────────────────────────────

class FakeEntryRepository implements EntryRepository {
  FakeEntryRepository(this._store);

  final FakeStore _store;

  @override
  Future<List<RegisterEntry>> fetchEntries({
    required String site,
    String? registerId,
    String? dateFrom,
    String? dateTo,
    bool? hasOpenTicket,
  }) async {
    await Future<void>.delayed(_latency);
    return scopedEntries(_store, site)
        .where((e) => registerId == null || e.registerId == registerId)
        .where((e) => dateFrom == null || e.date.compareTo(dateFrom) >= 0)
        .where((e) => dateTo == null || e.date.compareTo(dateTo) <= 0)
        // The fake has no separate ticket concept (see FakeTicketRepository's
        // own note) — EntryStatus.open is the only register that ever
        // reaches "open" today, so it stands in for "has an open ticket".
        .where(
          (e) =>
              hasOpenTicket == null ||
              (e.status == EntryStatus.open) == hasOpenTicket,
        )
        .toList();
  }

  @override
  Future<RegisterEntry> fetchEntry(String id) async {
    await Future<void>.delayed(_latency);
    final i = _store.entries.indexWhere((e) => e.id == id);
    if (i == -1) throw ApiException('Entry $id not found');
    return _store.entries[i];
  }

  @override
  Future<RegisterEntry> createEntry(RegisterEntry entry) async {
    await Future<void>.delayed(_latency);
    // Mirrors the server's rule: a dropdown value must exist on its master list.
    assertMasterValue(_store, entry);
    final created = RegisterEntry(
      id: _store.newId(),
      registerId: entry.registerId,
      date: entry.date,
      time: entry.time,
      site: entry.site,
      enteredBy: entry.enteredBy,
      data: entry.data,
      status: entry.status,
      photoUrl: entry.photoUrl,
    );
    _store.entries.insert(0, created);
    return created;
  }

  @override
  Future<RegisterEntry> updateEntry(RegisterEntry entry) async {
    await Future<void>.delayed(_latency);
    assertMasterValue(_store, entry);
    final i = _store.entries.indexWhere((e) => e.id == entry.id);
    if (i == -1) throw ApiException('Entry ${entry.id} not found');
    _store.entries[i] = entry;
    return entry;
  }

  @override
  Future<RegisterEntry> setStatus(String entryId, EntryStatus status) async {
    await Future<void>.delayed(_latency);
    final i = _store.entries.indexWhere((e) => e.id == entryId);
    if (i == -1) throw ApiException('Entry $entryId not found');
    final updated = _store.entries[i].copyWith(status: status);
    _store.entries[i] = updated;
    return updated;
  }

  @override
  Future<String> attachPhoto(
    String entryId, {
    required String filename,
    required List<int> bytes,
  }) async {
    await Future<void>.delayed(_latency);
    final i = _store.entries.indexWhere((e) => e.id == entryId);
    if (i == -1) throw ApiException('Entry $entryId not found');
    final url = 'fake://photos/$entryId/$filename';
    _store.entries[i] = _store.entries[i].withPhotoUrl(url);
    return url;
  }

  @override
  Future<void> removePhoto(String entryId) async {
    await Future<void>.delayed(_latency);
    final i = _store.entries.indexWhere((e) => e.id == entryId);
    if (i == -1) throw ApiException('Entry $entryId not found');
    _store.entries[i] = _store.entries[i].withPhotoUrl(null);
  }

  @override
  Future<List<RegisterEntry>> createCoolantDay({
    required String site,
    required String entryDate,
    String? supervisor,
    required List<Map<String, dynamic>> rows,
  }) async {
    final created = <RegisterEntry>[];
    for (final row in rows) {
      final vehicle = _store.vehicles.firstWhere(
        (v) => v.id == row['vehicle_id'],
        orElse: () => throw ApiException('Vehicle ${row['vehicle_id']} not found'),
      );
      final entry = await createEntry(
        RegisterEntry(
          id: '',
          registerId: 'coolant',
          date: entryDate,
          time: '',
          site: site,
          enteredBy: '',
          data: <String, String>{
            'bus': vehicle.registrationNo,
            if (row['bcs_litres'] != null) 'bcs': '${row['bcs_litres']}',
            if (row['tcs_litres'] != null) 'tcs': '${row['tcs_litres']}',
            if (row['topped_by'] != null) 'employee': '${row['topped_by']}',
            if (supervisor != null && supervisor.isNotEmpty) 'supervisor': supervisor,
          },
        ),
      );
      created.add(entry);
    }
    return created;
  }
}

// ─── Tickets ──────────────────────────────────────────────────────────────

/// A simplification: the fake store has no separate ticket concept, so the
/// source entry's own id stands in for the ticket id. Good enough for
/// widget/provider tests that only need a plausible round trip, not real
/// ticket semantics.
class FakeTicketRepository implements TicketRepository {
  FakeTicketRepository(this._store);

  final FakeStore _store;

  @override
  Future<List<TicketSearchResult>> search({
    required String site,
    String? register,
    String? q,
  }) async {
    await Future<void>.delayed(_latency);
    final needle = (q ?? '').toLowerCase();
    // `ApiTicketRepository.search` translates the app-side register id to its
    // wire value before sending, and the backend's `Register` enum 422s on
    // anything else. Match on the wire value here for the same reason: a fake
    // that quietly accepted `complaint` where the real API sends
    // `driver_complaint` is a fake that hides the bug.
    final wanted = register == null ? null : registerToWire[register];
    if (register != null && wanted == null) {
      throw ApiException('register: $register is not a register id');
    }
    return _store.entries
        .where((e) => e.site == site)
        .where((e) => e.isOpen || e.registerId != kBreakdownRegisterId)
        .where((e) => wanted == null || registerToWire[e.registerId] == wanted)
        .where((e) => needle.isEmpty || entrySummary(e).toLowerCase().contains(needle))
        .map(
          (e) => TicketSearchResult(
            ticketId: e.id,
            title: '${entrySummary(e)} · ${e.busNumber}',
            entryDate: e.date,
            status: 'open',
            sourceKind: registerToWire[e.registerId] ?? e.registerId,
          ),
        )
        .toList();
  }

  @override
  Future<RegisterEntry> raiseTicket(String entryId) async {
    await Future<void>.delayed(_latency);
    final i = _store.entries.indexWhere((e) => e.id == entryId);
    if (i == -1) throw ApiException('Entry $entryId not found');
    final updated = _store.entries[i].copyWith(status: EntryStatus.open);
    _store.entries[i] = updated;
    return updated;
  }
}

// ─── Users ────────────────────────────────────────────────────────────────

class FakeUserRepository implements UserRepository {
  FakeUserRepository(this._store);

  final FakeStore _store;

  @override
  Future<List<AppUser>> fetchUsers() async {
    await Future<void>.delayed(_latency);
    return _store.visibleUsers();
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
    await Future<void>.delayed(_latency);
    final handle = userId.trim().toUpperCase();
    if (await isUserIdTaken(handle)) {
      throw const ApiException('User ID already exists');
    }
    final created = AppUser(
      id: _store.newId(),
      name: name.trim(),
      userId: handle,
      email: email.trim(),
      role: role,
      // A super admin reaches every site; storing a list would go stale the
      // moment a new site is onboarded.
      sites: role.governsAllSites ? const <String>[] : sites,
      active: true,
      mustResetPassword: true,
    );
    final temp = (password == null || password.trim().isEmpty)
        ? _generatePassword()
        : password.trim();
    _store.users.insert(0, created);
    _store.passwords[handle] = temp;
    return (user: created, temporaryPassword: temp);
  }

  @override
  Future<AppUser> updateUser(AppUser user) async {
    await Future<void>.delayed(_latency);
    final i = _store.users.indexWhere((u) => u.id == user.id);
    if (i == -1) throw ApiException('User ${user.id} not found');
    _store.users[i] = user;
    return user;
  }

  @override
  Future<AppUser> setActive(String id, bool active) async {
    await Future<void>.delayed(_latency);
    final i = _store.users.indexWhere((u) => u.id == id);
    if (i == -1) throw ApiException('User $id not found');
    final updated = _store.users[i].copyWith(active: active);
    _store.users[i] = updated;
    return updated;
  }

  @override
  Future<String> resetPassword(String id, {String? password}) async {
    await Future<void>.delayed(_latency);
    final i = _store.users.indexWhere((u) => u.id == id);
    if (i == -1) throw ApiException('User $id not found');
    final temp = (password == null || password.trim().isEmpty)
        ? _generatePassword()
        : password.trim();
    _store.passwords[_store.users[i].userId] = temp;
    _store.users[i] = _store.users[i].copyWith(mustResetPassword: true);
    return temp;
  }

  @override
  Future<bool> isUserIdTaken(String userId, {String? exceptId}) async {
    final needle = userId.trim().toUpperCase();
    return _store.users
        .any((u) => u.userId.toUpperCase() == needle && u.id != exceptId);
  }

  /// Readable but not guessable — an admin reads this aloud to a mechanic.
  String _generatePassword() {
    const words = <String>['Depot', 'Charge', 'Volt', 'Fleet', 'Shift', 'Bay'];
    final word = words[DateTime.now().microsecond % words.length];
    final digits = (DateTime.now().millisecondsSinceEpoch % 9000) + 1000;
    return '$word@$digits';
  }
}

// ─── Auth ─────────────────────────────────────────────────────────────────

/// Stands in for MSAL + the credential endpoint.
///
/// Credential sign-in checks the seeded password, and the inactive-account
/// rejection is real, because that rule has to hold in the UI as well as on the
/// server.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository(this._store);

  final FakeStore _store;

  @override
  Future<SsoConfig> ssoConfig() async => const SsoConfig(
        enabled: true,
        clientId: 'fake-client',
        authority: 'https://login.microsoftonline.com/fake-tenant',
      );

  @override
  Future<void> beginMicrosoftSignIn(SsoConfig config) async {}

  @override
  Future<AppUser?> completeMicrosoftSignIn(SsoConfig config) async {
    // Matches the 1.4s SSO handshake the prototype simulates.
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    final user = _store.users
        .where((u) => u.canUseSso && u.active)
        .cast<AppUser?>()
        .firstWhere((u) => true, orElse: () => null);
    if (user == null) {
      throw const ApiException(
        'No Microsoft account is linked to this device',
      );
    }
    _store.currentUser = user;
    return user;
  }

  @override
  Future<AppUser> signInWithCredentials({
    required String userId,
    required String password,
  }) async {
    await Future<void>.delayed(_latency);
    if (userId.trim().isEmpty || password.isEmpty) {
      throw const ApiException('Enter your User ID and password');
    }
    final needle = userId.trim().toUpperCase();
    final matches =
        _store.users.where((u) => u.userId.toUpperCase() == needle).toList();
    if (matches.isEmpty) {
      throw const ApiException('User ID not recognised');
    }
    final user = matches.first;
    if (_store.passwords[user.userId] != password) {
      throw const ApiException('Incorrect password');
    }
    if (!user.active) {
      throw const ApiException(
        'This account is inactive. Contact your site manager.',
      );
    }
    _store.currentUser = user;
    return user;
  }

  @override
  Future<AppUser?> restoreSession() async {
    final user = _store.currentUser;
    if (user == null || !user.active) return null;
    return user;
  }

  @override
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await Future<void>.delayed(_latency);
    final user = _store.currentUser;
    if (user == null) throw const ApiException('Not signed in');
    if (_store.passwords[user.userId] != currentPassword) {
      throw const ApiException('Current password is incorrect');
    }
    if (newPassword.trim().length < 8) {
      throw const ApiException('New password must be at least 8 characters');
    }
    _store.passwords[user.userId] = newPassword;
    final i = _store.users.indexWhere((u) => u.id == user.id);
    if (i != -1) {
      _store.users[i] = _store.users[i].copyWith(mustResetPassword: false);
      _store.currentUser = _store.users[i];
    }
  }

  @override
  Future<void> signOut() async {
    await Future<void>.delayed(_latency);
    _store.currentUser = null;
  }
}

/// Exposed so tests and the demo can state the shared password once.
const String kDemoPassword = kSeedPassword;
