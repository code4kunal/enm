import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/api/api_repositories.dart';
import '../data/api/siteops_client.dart';
import '../data/repositories.dart';
import '../models/site.dart';
import '../models/site_config.dart';
import 'selected_site.dart';
import 'session.dart';

/// Single wiring point for the data layer.
///
/// Every repository resolves to its HTTP implementation in `data/api/`. There
/// are no in-memory fakes and no demo seed: what the screens show is what is in
/// the database. Point a build at different backends with:
///
/// ```sh
/// flutter run -d chrome \
///   --dart-define=API_BASE_URL=http://localhost:8123/api/v1 \
///   --dart-define=SITEOPS_BASE_URL=https://platform-service.transvolt.in/api/v1
/// ```

/// HTTP transport, created once so the access token is shared by every
/// repository.
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.listen<SelectedSiteState>(selectedSiteProvider, (prev, next) {
    client.selectedSiteId = next.id;
  }, fireImmediately: true);
  ref.onDispose(client.close);
  return client;
});

/// SiteOps platform API — vehicle master, site dropdown, onboarding.
final siteOpsClientProvider = Provider<SiteOpsClient>((ref) {
  final client = SiteOpsClient();
  ref.onDispose(client.close);
  return client;
});

final masterDataRepositoryProvider = Provider<MasterDataRepository>(
  (ref) => ApiMasterDataRepository(ref.watch(apiClientProvider), ref.watch(siteOpsClientProvider)),
);

final entryRepositoryProvider = Provider<EntryRepository>(
  (ref) => ApiEntryRepository(ref.watch(apiClientProvider)),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => ApiUserRepository(ref.watch(apiClientProvider)),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => ApiAuthRepository(ref.watch(apiClientProvider)),
);

final siteRepositoryProvider = Provider<SiteRepository>(
  (ref) => ApiSiteRepository(
    ref.watch(apiClientProvider),
    ref.watch(siteOpsClientProvider),
  ),
);

final vehicleRepositoryProvider = Provider<VehicleRepository>(
  (ref) => ApiVehicleRepository(
    ref.watch(apiClientProvider),
    ref.watch(siteOpsClientProvider),
  ),
);

final siteConfigRepositoryProvider = Provider<SiteConfigRepository>(
  (ref) => ApiSiteConfigRepository(ref.watch(apiClientProvider)),
);

final importRepositoryProvider = Provider<ImportRepository>(
  (ref) => ApiImportRepository(ref.watch(apiClientProvider)),
);

final inspectionRepositoryProvider = Provider<InspectionRepository>(
  (ref) => ApiInspectionRepository(ref.watch(apiClientProvider)),
);

final checklistRepositoryProvider = Provider<ChecklistRepository>(
  (ref) => ApiChecklistRepository(ref.watch(apiClientProvider)),
);

final reportRepositoryProvider = Provider<ReportRepository>(
  (ref) => ApiReportRepository(ref.watch(apiClientProvider)),
);

// ─── Derived reference data ───────────────────────────────────────────────

/// Full site records the signed-in user can reach. Super admins get all of them.
final sitesProvider = FutureProvider<List<Site>>((ref) {
  // Re-resolves on sign-in, because visibility depends on who is asking.
  ref.watch(sessionProvider.select((s) => s.user?.id));
  return ref.watch(siteRepositoryProvider).fetchSites();
});

/// Just the codes, for the header switcher and access chips.
final siteCodesProvider = Provider<List<String>>((ref) {
  final sites = ref.watch(sitesProvider).valueOrNull ?? const <Site>[];
  return sites.where((s) => s.isActive).map((s) => s.code).toList();
});

/// The active site's record.
final activeSiteProvider = Provider<Site?>((ref) {
  final code = ref.watch(sessionProvider.select((s) => s.site));
  final selectedId = ref.watch(selectedSiteProvider.select((s) => s.id));
  final selectedName = ref.watch(selectedSiteProvider.select((s) => s.name));
  final sites = ref.watch(sitesProvider).valueOrNull ?? const <Site>[];
  for (final s in sites) {
    if (s.code == code || (selectedId != null && s.code == selectedId)) return s;
  }
  if (selectedName.isNotEmpty) {
    return Site(
      code: code,
      name: selectedName,
      address: '',
      timezone: 'Asia/Kolkata',
      isActive: true,
    );
  }
  return null;
});

/// Human-readable display name for the active site (maps UUID to site name).
final siteDisplayNameProvider = Provider<String>((ref) {
  final selectedName = ref.watch(selectedSiteProvider.select((s) => s.name));
  if (selectedName.isNotEmpty) {
    return selectedName;
  }
  final active = ref.watch(activeSiteProvider);
  if (active != null && active.name.isNotEmpty) {
    return active.name;
  }
  final code = ref.watch(sessionProvider.select((s) => s.site));
  return code;
});

/// Resolves a vehicle registration number from its ID or UUID string.
final vehicleNameProvider = Provider.family<String, String>((ref, vehicleId) {
  if (vehicleId.isEmpty) return '—';

  final fleet = ref.watch(siteVehiclesProvider).valueOrNull ?? const <Vehicle>[];
  for (final v in fleet) {
    if (v.id == vehicleId || v.registrationNo == vehicleId) {
      if (v.registrationNo.isNotEmpty && (!v.registrationNo.contains('-') || v.registrationNo.length < 25)) {
        return v.registrationNo;
      }
    }
  }

  final master = ref.watch(masterDataProvider).valueOrNull;
  if (master != null) {
    for (final busReg in master.vehicles) {
      if (busReg == vehicleId && (!busReg.contains('-') || busReg.length < 25)) {
        return busReg;
      }
    }
  }

  if (vehicleId.contains('-') && vehicleId.length >= 8) {
    return 'Bus #${vehicleId.substring(0, 8).toUpperCase()}';
  }
  return vehicleId;
});

/// Reference data for the entry form, re-resolved whenever the active site
/// changes — the fleet is site-scoped.
final masterDataProvider = FutureProvider<MasterData>((ref) async {
  final repo = ref.watch(masterDataRepositoryProvider);
  final site = ref.watch(sessionProvider.select((s) => s.site));
  final siteOpsSiteId =
      ref.watch(selectedSiteProvider.select((s) => s.id)) ?? '';
  // Need at least an E&M code or a SiteOps UUID to load a fleet.
  if (site.isEmpty && siteOpsSiteId.isEmpty) return MasterData.empty;

  // Stale-bundle key for the register form: prefer E&M code, else SiteOps id.
  final scopeKey = site.isNotEmpty ? site : siteOpsSiteId;

  Future<List<String>> safe(Future<List<String>> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return const <String>[];
    }
  }

  final results = await Future.wait(<Future<List<String>>>[
    safe(() => repo.siteCodes()),
    // SiteOps UUID first (header site), E&M code as fallback — see
    // [MasterDataRepository.vehicleNumbers].
    safe(
      () => repo.vehicleNumbers(
        siteCode: site,
        siteOpsSiteId: siteOpsSiteId,
      ),
    ),
    safe(() => repo.defectSources()),
    safe(() => repo.defectTypes()),
    safe(() => repo.staff(siteCode: site)),
    // Staff rosters still come from SiteOps and are keyed by its site UUID.
    safe(() => repo.technicianStaff(siteName: site, siteId: siteOpsSiteId)),
    safe(() => repo.supervisorStaff(siteName: site, siteId: siteOpsSiteId)),
    safe(() => repo.mechanicStaff(siteName: site, siteId: siteOpsSiteId)),
  ]);

  return MasterData(
    siteCode: scopeKey,
    sites: results[0],
    vehicles: results[1],
    defectSources: results[2],
    defectTypes: results[3],
    staff: results[4],
    technicianStaff: results[5],
    supervisorStaff: results[6],
    mechanicStaff: results[7],
  );
});

/// Technician names for the Daily Work Done attended-by picker.
final technicianStaffProvider = FutureProvider<List<String>>((ref) async {
  final repo = ref.watch(masterDataRepositoryProvider);
  final siteName = ref.watch(sessionProvider.select((s) => s.site));
  final siteOpsSiteId =
      ref.watch(selectedSiteProvider.select((s) => s.id)) ?? '';
  if (siteName.isEmpty) return const <String>[];

  try {
    return await repo.technicianStaff(
        siteName: siteName, siteId: siteOpsSiteId);
  } catch (_) {
    return const <String>[];
  }
});

/// Supervisor names for the Daily Work Done supervisor picker.
final supervisorStaffProvider = FutureProvider<List<String>>((ref) async {
  final repo = ref.watch(masterDataRepositoryProvider);
  final siteName = ref.watch(sessionProvider.select((s) => s.site));
  final siteOpsSiteId =
      ref.watch(selectedSiteProvider.select((s) => s.id)) ?? '';
  if (siteName.isEmpty && siteOpsSiteId.isEmpty) return const <String>[];

  try {
    return await repo.supervisorStaff(
        siteName: siteName, siteId: siteOpsSiteId);
  } catch (_) {
    return const <String>[];
  }
});

/// Mechanic names for the Driver Complaints mechanic picker.
final mechanicStaffProvider = FutureProvider<List<String>>((ref) async {
  final repo = ref.watch(masterDataRepositoryProvider);
  final siteName = ref.watch(sessionProvider.select((s) => s.site));
  final siteOpsSiteId =
      ref.watch(selectedSiteProvider.select((s) => s.id)) ?? '';
  if (siteName.isEmpty && siteOpsSiteId.isEmpty) return const <String>[];

  try {
    return await repo.mechanicStaff(siteName: siteName, siteId: siteOpsSiteId);
  } catch (_) {
    return const <String>[];
  }
});

/// Full vehicle records for the active site's fleet screen, including retired
/// ones so a manager can reactivate.
///
/// E&M code, not the SiteOps id: this feeds bus history, off-road and units,
/// which all resolve report rows against the E&M-native vehicle id.
final siteVehiclesProvider = FutureProvider<List<Vehicle>>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) return Future<List<Vehicle>>.value(const <Vehicle>[]);
  return ref
      .watch(vehicleRepositoryProvider)
      .fetchVehicles(siteCode: site, includeInactive: true);
});

/// The preventive-maintenance configuration for the active site.
final siteConfigProvider = FutureProvider<SiteConfig>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) {
    return Future<SiteConfig>.value(SiteConfig.empty(''));
  }
  return ref.watch(siteConfigRepositoryProvider).fetchConfig(site);
});
