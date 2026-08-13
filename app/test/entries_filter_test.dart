import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/data/fake/seed.dart';
import 'package:transvolt_em/data/registers.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/state/entries.dart';
import 'package:transvolt_em/state/session.dart';
import 'package:transvolt_em/utils/dates.dart';

/// Signs in against the fake auth repository and lands on MBMT, which is where
/// the seed entries live.
Future<ProviderContainer> signedInContainer() async {
  final container = ProviderContainer();
  addTearDown(container.dispose);

  await container
      .read(sessionProvider.notifier)
      .signInWithCredentials('TV4021', kSeedPassword);
  container.read(sessionProvider.notifier).enterApp();
  await container.read(entriesProvider.future);

  return container;
}

void main() {
  group('entriesProvider', () {
    test('is scoped to the active site', () async {
      final container = await signedInContainer();
      final entries = container.read(entriesProvider).requireValue;

      expect(entries, isNotEmpty);
      expect(entries.every((e) => e.site == 'MBMT'), isTrue);
    });

    test('re-fetches when the site switches', () async {
      final container = await signedInContainer();
      container.read(sessionProvider.notifier).switchSite('UMT');
      final entries = await container.read(entriesProvider.future);

      expect(entries.every((e) => e.site == 'UMT'), isTrue);
    });

    test('sorts newest first', () async {
      final container = await signedInContainer();
      final entries = container.read(entriesProvider).requireValue;

      for (var i = 1; i < entries.length; i++) {
        expect(
          entries[i - 1].date.compareTo(entries[i].date),
          greaterThanOrEqualTo(0),
        );
      }
    });
  });

  group('create', () {
    test('normalises the bus number to uppercase without spaces', () async {
      final container = await signedInContainer();
      final created = await container.read(entriesProvider.notifier).create(
        registerId: 'coolant',
        data: <String, String>{
          'bus': ' mh40ly 1894 ',
          'date': Dates.today(),
          'bcs': '1',
        },
      );

      expect(created.busNumber, 'MH40LY1894');
    });

    test('opens breakdowns and closes everything else', () async {
      final container = await signedInContainer();
      final notifier = container.read(entriesProvider.notifier);

      final bd = await notifier.create(
        registerId: kBreakdownRegisterId,
        data: <String, String>{'bus': 'MH40LY1894', 'date': Dates.today()},
      );
      final work = await notifier.create(
        registerId: 'work',
        data: <String, String>{'bus': 'MH40LY1894', 'date': Dates.today()},
      );

      expect(bd.status, EntryStatus.open);
      expect(work.status, EntryStatus.done);
    });

    test('attributes the entry to the employee or mechanic field', () async {
      final container = await signedInContainer();
      final notifier = container.read(entriesProvider.notifier);

      final byEmployee = await notifier.create(
        registerId: 'work',
        data: <String, String>{
          'bus': 'MH40LY1894',
          'date': Dates.today(),
          'employee': 'S. Pawar / 4102',
        },
      );
      final byMechanic = await notifier.create(
        registerId: 'complaint',
        data: <String, String>{
          'bus': 'MH40LY1894',
          'date': Dates.today(),
          'mechanic': 'A. Khan / 3987',
        },
      );
      final unattributed = await notifier.create(
        registerId: 'work',
        data: <String, String>{'bus': 'MH40LY1894', 'date': Dates.today()},
      );

      expect(byEmployee.enteredBy, 'S. Pawar / 4102');
      expect(byMechanic.enteredBy, 'A. Khan / 3987');
      // Falls back to the signed-in user.
      expect(unattributed.enteredBy, 'Rahul Sharma');
    });

    test('a new entry lands in today\'s feed', () async {
      final container = await signedInContainer();
      final before = container.read(todayEntriesProvider).length;

      await container.read(entriesProvider.notifier).create(
        registerId: 'coolant',
        data: <String, String>{'bus': 'MH40LY1721', 'date': Dates.today()},
      );

      expect(container.read(todayEntriesProvider), hasLength(before + 1));
    });
  });

  group('resolveBreakdown', () {
    test('clears the entry from the open list', () async {
      final container = await signedInContainer();
      final open = container.read(openBreakdownsProvider);
      expect(open, isNotEmpty);

      await container
          .read(entriesProvider.notifier)
          .resolveBreakdown(open.first.id);

      final after = container.read(openBreakdownsProvider);
      expect(after.any((e) => e.id == open.first.id), isFalse);
      // The breakdown itself is retained, just resolved.
      expect(
        container.read(breakdownsProvider).any((e) => e.id == open.first.id),
        isTrue,
      );
    });
  });

  group('filteredEntriesProvider', () {
    test('filters by register', () async {
      final container = await signedInContainer();
      container.read(entryFiltersProvider.notifier)
        ..setDateMode(DateMode.all)
        ..setRegister('coolant');

      final results = container.read(filteredEntriesProvider);
      expect(results, isNotEmpty);
      expect(results.every((e) => e.registerId == 'coolant'), isTrue);
    });

    test('Today keeps only today\'s entries', () async {
      final container = await signedInContainer();
      container.read(entryFiltersProvider.notifier).setDateMode(DateMode.today);

      final results = container.read(filteredEntriesProvider);
      expect(results.every((e) => e.date == Dates.today()), isTrue);
    });

    test('Last 7 days excludes older entries', () async {
      final container = await signedInContainer();
      container.read(entryFiltersProvider.notifier).setDateMode(DateMode.week);

      final results = container.read(filteredEntriesProvider);
      final cutoff = Dates.today(-6);
      expect(results.every((e) => e.date.compareTo(cutoff) >= 0), isTrue);
      // The seed set contains a 35-day-old entry that must be excluded.
      expect(
        results.any((e) => e.date.compareTo(Dates.today(-30)) < 0),
        isFalse,
      );
    });

    test('a custom range honours both bounds', () async {
      final container = await signedInContainer();
      container.read(entryFiltersProvider.notifier)
        ..setDateMode(DateMode.custom)
        ..setFrom(Dates.today(-3))
        ..setTo(Dates.today(-1));

      final results = container.read(filteredEntriesProvider);
      expect(
        results.every(
          (e) =>
              e.date.compareTo(Dates.today(-3)) >= 0 &&
              e.date.compareTo(Dates.today(-1)) <= 0,
        ),
        isTrue,
      );
    });

    test('free-text search matches across any captured column', () async {
      final container = await signedInContainer();
      container.read(entryFiltersProvider.notifier)
        ..setDateMode(DateMode.all)
        ..setQuery('kashimira');

      final results = container.read(filteredEntriesProvider);
      expect(results, hasLength(1));
      expect(results.first.data['loc'], contains('Kashimira'));
    });

    test('free-text search also matches the operator', () async {
      final container = await signedInContainer();
      container.read(entryFiltersProvider.notifier)
        ..setDateMode(DateMode.all)
        ..setQuery('jadhav');

      expect(container.read(filteredEntriesProvider), isNotEmpty);
    });

    test('an unmatched query yields nothing', () async {
      final container = await signedInContainer();
      container.read(entryFiltersProvider.notifier)
        ..setDateMode(DateMode.all)
        ..setQuery('zzzz-no-such-thing');

      expect(container.read(filteredEntriesProvider), isEmpty);
    });
  });
}
