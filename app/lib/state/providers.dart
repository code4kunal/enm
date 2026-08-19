import 'selected_site.dart';
import '../data/api/siteops_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/api/api_repositories.dart';
import '../data/api/siteops_client.dart';
import '../data/repositories.dart';
import '../models/site.dart';
import '../models/site_config.dart';
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
///   --dart-define=SITEOPS_BASE_URL=https://dev-siteops-platform.transvolt.org/api/v1
/// ```

/// HTTP transport, created once so the access token is shared by every
/// repository.
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.listen<SelectedSiteState>(selectedSiteProvider, (prev, next) {
    client.selectedSiteId = next.id;
    siteOpsClient.selectedSiteId = next.id;
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
  (ref) => ApiMasterDataRepository(ref.watch(apiClientProvider)),
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
  (ref) => ApiSiteRepository(ref.watch(apiClientProvider)),
);

final vehicleRepositoryProvider = Provider<VehicleRepository>(
  (ref) => ApiVehicleRepository(ref.watch(apiClientProvider)),
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
  final sites = ref.watch(sitesProvider).valueOrNull ?? const <Site>[];
  for (final s in sites) {
    if (s.code == code) return s;
  }
  return null;
});

/// Reference data for the entry form, re-resolved whenever the active site
/// changes — the fleet is site-scoped.
final masterDataProvider = FutureProvider<MasterData>((ref) async {
  final repo = ref.watch(masterDataRepositoryProvider);
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) return MasterData.empty;

  Future<List<String>> safe(Future<List<String>> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return const <String>[];
    }
  }

  final results = await Future.wait(<Future<List<String>>>[
    safe(() => repo.siteCodes()),
    safe(() => repo.vehicleNumbers(siteCode: site)),
    safe(() => repo.defectSources()),
    safe(() => repo.defectTypes()),
    safe(() => repo.staff(siteCode: site)),
  ]);

  return MasterData(
    sites: results[0],
    vehicles: results[1],
    defectSources: results[2],
    defectTypes: results[3],
    staff: results[4],
  );
});

/// Full vehicle records for the active site's fleet screen, including retired
/// ones so a manager can reactivate.
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
