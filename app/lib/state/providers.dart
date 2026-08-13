import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/api_client.dart';
import '../data/api/api_repositories.dart';
import '../data/fake/fake_repositories.dart';
import '../data/fake/fake_site_repositories.dart';
import '../data/fake/fake_store.dart';
import '../data/repositories.dart';
import '../models/site.dart';
import '../models/site_config.dart';
import 'session.dart';

/// Single wiring point for the data layer.
///
/// `--dart-define=USE_API=true` swaps every repository from the in-memory fakes
/// to the HTTP implementations in `data/api/`. Nothing above this file changes.

/// Whether this build talks to a real backend. Overridable in tests.
final useApiProvider = Provider<bool>((ref) => ApiConfig.useApi);

/// The shared in-memory database behind every fake. One instance so an import
/// changes the fleet the entry form offers, and signing in scopes what is
/// visible.
final fakeStoreProvider = Provider<FakeStore>((ref) => FakeStore());

/// HTTP transport, created once so the access token and the capability probe
/// are shared by every repository.
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.onDispose(client.close);
  return client;
});

/// Picks the live or fake implementation of one repository.
T _pick<T>(Ref ref, T Function(ApiClient) live, T Function(FakeStore) fake) =>
    ref.watch(useApiProvider)
        ? live(ref.watch(apiClientProvider))
        : fake(ref.watch(fakeStoreProvider));

final masterDataRepositoryProvider = Provider<MasterDataRepository>(
  (ref) => _pick(ref, ApiMasterDataRepository.new, FakeMasterDataRepository.new),
);

final entryRepositoryProvider = Provider<EntryRepository>(
  (ref) => _pick(ref, ApiEntryRepository.new, FakeEntryRepository.new),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => _pick(ref, ApiUserRepository.new, FakeUserRepository.new),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => _pick(ref, ApiAuthRepository.new, FakeAuthRepository.new),
);

final siteRepositoryProvider = Provider<SiteRepository>(
  (ref) => _pick(ref, ApiSiteRepository.new, FakeSiteRepository.new),
);

final vehicleRepositoryProvider = Provider<VehicleRepository>(
  (ref) => _pick(ref, ApiVehicleRepository.new, FakeVehicleRepository.new),
);

final siteConfigRepositoryProvider = Provider<SiteConfigRepository>(
  (ref) => _pick(ref, ApiSiteConfigRepository.new, FakeSiteConfigRepository.new),
);

final importRepositoryProvider = Provider<ImportRepository>(
  (ref) => _pick(ref, ApiImportRepository.new, FakeImportRepository.new),
);

/// What the connected backend supports. Meaningless in fake mode, where every
/// feature is present.
final backendCapabilitiesProvider = Provider<ApiCapabilities>((ref) {
  if (!ref.watch(useApiProvider)) return ApiCapabilities(siteManagement: true);
  return ref.watch(apiClientProvider).capabilities;
});

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

  final results = await Future.wait(<Future<List<String>>>[
    repo.siteCodes(),
    repo.vehicleNumbers(siteCode: site),
    repo.defectSources(),
    repo.defectTypes(),
  ]);

  return MasterData(
    sites: results[0],
    vehicles: results[1],
    defectSources: results[2],
    defectTypes: results[3],
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

/// Docking and charging parameters for the active site.
final siteConfigProvider = FutureProvider<SiteConfig>((ref) {
  final site = ref.watch(sessionProvider.select((s) => s.site));
  if (site.isEmpty) {
    return Future<SiteConfig>.value(SiteConfig.empty(''));
  }
  return ref.watch(siteConfigRepositoryProvider).fetchConfig(site);
});
