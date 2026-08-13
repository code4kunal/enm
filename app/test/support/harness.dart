import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transvolt_em/state/providers.dart';

import 'fake_repositories.dart';
import 'fake_site_repositories.dart';
import 'fake_store.dart';

/// Test-only wiring.
///
/// The app itself has no fakes: every repository in `lib/state/providers.dart`
/// resolves to HTTP, and what a screen shows is what is in the database. These
/// doubles live under `test/` so they cannot be compiled into a build, and
/// exist only so the state layer — session scoping, filters, site and user
/// rules, import mapping — can be exercised without a server.
///
/// One [FakeStore] backs all eight, deliberately: an import has to change what
/// the entry form's bus dropdown offers, and signing in has to scope what is
/// visible. Per-repository stubs reproduce neither.
List<Override> fakeOverrides([FakeStore? store]) {
  final db = store ?? FakeStore();
  return <Override>[
    masterDataRepositoryProvider.overrideWithValue(
      FakeMasterDataRepository(db),
    ),
    entryRepositoryProvider.overrideWithValue(FakeEntryRepository(db)),
    userRepositoryProvider.overrideWithValue(FakeUserRepository(db)),
    authRepositoryProvider.overrideWithValue(FakeAuthRepository(db)),
    siteRepositoryProvider.overrideWithValue(FakeSiteRepository(db)),
    vehicleRepositoryProvider.overrideWithValue(FakeVehicleRepository(db)),
    siteConfigRepositoryProvider.overrideWithValue(
      FakeSiteConfigRepository(db),
    ),
    importRepositoryProvider.overrideWithValue(FakeImportRepository(db)),
  ];
}

/// A container with the fake data layer wired in.
ProviderContainer fakeContainer([FakeStore? store]) =>
    ProviderContainer(overrides: fakeOverrides(store));
