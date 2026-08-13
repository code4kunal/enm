import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories.dart';
import '../models/site.dart';
import '../models/site_config.dart';
import '../utils/dates.dart';
import 'providers.dart';
import 'session.dart';

// ─── Site onboarding ──────────────────────────────────────────────────────

/// Working copy behind the create/edit site card. A null [code] means new.
@immutable
class SiteDraft {
  const SiteDraft({
    this.code = '',
    this.name = '',
    this.address = '',
    this.timezone = 'Asia/Kolkata',
    this.commissionedOn,
    this.isEdit = false,
  });

  SiteDraft.fromSite(Site s)
      : code = s.code,
        name = s.name,
        address = s.address,
        timezone = s.timezone,
        commissionedOn = s.commissionedOn,
        isEdit = true;

  final String code;
  final String name;
  final String address;
  final String timezone;
  final String? commissionedOn;
  final bool isEdit;

  String get title => isEdit ? 'Edit site' : 'Onboard site';

  String get cta => isEdit ? 'Save changes' : 'Create site';

  SiteDraft copyWith({
    String? code,
    String? name,
    String? address,
    String? timezone,
    String? commissionedOn,
  }) =>
      SiteDraft(
        code: code ?? this.code,
        name: name ?? this.name,
        address: address ?? this.address,
        timezone: timezone ?? this.timezone,
        commissionedOn: commissionedOn ?? this.commissionedOn,
        isEdit: isEdit,
      );
}

class SitesController extends AsyncNotifier<List<Site>> {
  @override
  Future<List<Site>> build() async {
    // Visibility depends on who is signed in.
    ref.watch(sessionProvider.select((s) => s.user?.id));
    return ref.watch(siteRepositoryProvider).fetchSites();
  }

  SiteRepository get _repo => ref.read(siteRepositoryProvider);

  /// Throws [ApiException] with a message fit for the inline form error.
  Future<Site> save(SiteDraft draft) async {
    final code = draft.code.trim().toUpperCase();
    final name = draft.name.trim();
    if (code.isEmpty || name.isEmpty) {
      throw const ApiException('Site code and name are required');
    }
    if (!RegExp(r'^[A-Z0-9][A-Z0-9_-]{1,15}$').hasMatch(code)) {
      throw const ApiException(
        'Site code must be 2–16 characters: letters, digits, - or _',
      );
    }

    if (draft.isEdit) {
      final current =
          (state.valueOrNull ?? const <Site>[]).firstWhere((s) => s.code == code);
      final saved = await _repo.updateSite(
        current.copyWith(
          name: name,
          address: draft.address.trim(),
          timezone: draft.timezone,
          commissionedOn: draft.commissionedOn,
        ),
      );
      _patch((list) => list.map((s) => s.code == saved.code ? saved : s).toList());
      return saved;
    }

    final created = await _repo.createSite(
      code: code,
      name: name,
      timezone: draft.timezone,
      address: draft.address.trim(),
      commissionedOn: draft.commissionedOn,
    );
    _patch((list) => <Site>[...list, created]..sort((a, b) => a.code.compareTo(b.code)));
    // A newly onboarded site should be switchable without re-authenticating.
    ref.read(sessionProvider.notifier).adoptSites(state.valueOrNull ?? const <Site>[]);
    ref.invalidate(sitesProvider);
    return created;
  }

  Future<Site> setActive(String code, bool active) async {
    final saved = await _repo.setActive(code, active);
    _patch((list) => list.map((s) => s.code == saved.code ? saved : s).toList());
    ref.read(sessionProvider.notifier).adoptSites(state.valueOrNull ?? const <Site>[]);
    ref.invalidate(sitesProvider);
    return saved;
  }

  void _patch(List<Site> Function(List<Site>) transform) {
    state = AsyncData<List<Site>>(transform(state.valueOrNull ?? const <Site>[]));
  }
}

final sitesAdminProvider =
    AsyncNotifierProvider<SitesController, List<Site>>(SitesController.new);

// ─── Fleet ────────────────────────────────────────────────────────────────

class VehiclesController extends AsyncNotifier<List<Vehicle>> {
  @override
  Future<List<Vehicle>> build() async {
    final site = ref.watch(sessionProvider.select((s) => s.site));
    if (site.isEmpty) return const <Vehicle>[];
    return ref
        .watch(vehicleRepositoryProvider)
        .fetchVehicles(siteCode: site, includeInactive: true);
  }

  VehicleRepository get _repo => ref.read(vehicleRepositoryProvider);

  Future<Vehicle> add({
    required String registrationNo,
    String make = '',
    String model = '',
    double? batteryCapacityKwh,
  }) async {
    final site = ref.read(sessionProvider).site;
    final created = await _repo.createVehicle(
      siteCode: site,
      registrationNo: registrationNo,
      make: make,
      model: model,
      batteryCapacityKwh: batteryCapacityKwh,
    );
    _patch((list) => <Vehicle>[...list, created]
      ..sort((a, b) => a.registrationNo.compareTo(b.registrationNo)));
    // The entry form's bus dropdown reads master data, not this list.
    ref.invalidate(masterDataProvider);
    return created;
  }

  /// Named `edit` because `AsyncNotifier` already defines `update`.
  Future<Vehicle> edit(Vehicle vehicle) async {
    final saved = await _repo.updateVehicle(vehicle);
    _patch((list) => list.map((v) => v.id == saved.id ? saved : v).toList());
    ref.invalidate(masterDataProvider);
    return saved;
  }

  Future<Vehicle> setActive(String id, bool active) async {
    final saved = await _repo.setActive(id, active);
    _patch((list) => list.map((v) => v.id == saved.id ? saved : v).toList());
    ref.invalidate(masterDataProvider);
    return saved;
  }

  /// Records a manual odometer reading, for vehicles with no telematics feed.
  Future<Vehicle> setOdometer({
    required String vehicleId,
    required int odometerKm,
  }) async {
    final saved =
        await _repo.setOdometer(vehicleId: vehicleId, odometerKm: odometerKm);
    _patch((list) => list.map((v) => v.id == saved.id ? saved : v).toList());
    return saved;
  }

  /// Closes out a service, anchoring the next due point.
  Future<Vehicle> markServiced({
    required String vehicleId,
    required String planCode,
    required int odometerKm,
    String? servicedOn,
  }) async {
    final saved = await _repo.recordService(
      vehicleId: vehicleId,
      planCode: planCode,
      odometerKm: odometerKm,
      servicedOn: servicedOn ?? Dates.today(),
    );
    _patch((list) => list.map((v) => v.id == saved.id ? saved : v).toList());
    return saved;
  }

  void _patch(List<Vehicle> Function(List<Vehicle>) transform) {
    state =
        AsyncData<List<Vehicle>>(transform(state.valueOrNull ?? const <Vehicle>[]));
  }
}

final vehiclesProvider =
    AsyncNotifierProvider<VehiclesController, List<Vehicle>>(
  VehiclesController.new,
);

// ─── Master lists ─────────────────────────────────────────────────────────

/// Rows of one editable dropdown list, including inactive ones.
final masterListProvider =
    FutureProvider.family<List<MasterListItem>, MasterListKind>((ref, kind) {
  // Edits elsewhere in the app invalidate this through masterDataProvider.
  ref.watch(masterDataProvider);
  return ref.watch(masterDataRepositoryProvider).masterList(kind);
});

class MasterListController {
  const MasterListController(this._ref, this.kind);

  final Ref _ref;
  final MasterListKind kind;

  MasterDataRepository get _repo => _ref.read(masterDataRepositoryProvider);

  Future<void> add(String name) async {
    await _repo.addMasterItem(kind, name);
    _invalidate();
  }

  Future<void> rename(MasterListItem item, String name) async {
    await _repo.updateMasterItem(kind, item.copyWith(name: name.trim()));
    _invalidate();
  }

  Future<void> setActive(MasterListItem item, bool active) async {
    await _repo.updateMasterItem(kind, item.copyWith(isActive: active));
    _invalidate();
  }

  void _invalidate() {
    _ref.invalidate(masterListProvider(kind));
    _ref.invalidate(masterDataProvider);
  }
}

final masterListControllerProvider =
    Provider.family<MasterListController, MasterListKind>(
  (ref, kind) => MasterListController(ref, kind),
);

// ─── Docking configuration ────────────────────────────────────────────────

/// Editable working copy of the active site's config.
///
/// Held apart from [siteConfigProvider] so a manager can tinker with bays and
/// targets and still discard, and so validation runs against the draft rather
/// than what is saved.
class SiteConfigDraftController extends Notifier<SiteConfig?> {
  @override
  SiteConfig? build() {
    // Discard the draft when the site changes — it belongs to one site.
    ref.watch(sessionProvider.select((s) => s.site));
    return null;
  }

  /// Starts editing from the saved config.
  void begin(SiteConfig saved) => state = saved;

  void discard() => state = null;

  void update(SiteConfig Function(SiteConfig) transform) {
    final current = state;
    if (current != null) state = transform(current);
  }

  Future<SiteConfig> save() async {
    final draft = state;
    if (draft == null) throw const ApiException('Nothing to save');
    final saved = await ref.read(siteConfigRepositoryProvider).saveConfig(draft);
    state = null;
    ref.invalidate(siteConfigProvider);
    return saved;
  }
}

final siteConfigDraftProvider =
    NotifierProvider<SiteConfigDraftController, SiteConfig?>(
  SiteConfigDraftController.new,
);
