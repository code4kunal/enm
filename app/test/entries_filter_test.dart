import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness.dart';
import 'support/seed.dart';
import 'package:transvolt_em/data/registers.dart';
import 'package:transvolt_em/data/repositories.dart';
import 'package:transvolt_em/models/checklist.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/state/entries.dart';
import 'package:transvolt_em/state/inspections.dart';
import 'package:transvolt_em/state/providers.dart';
import 'package:transvolt_em/state/session.dart';
import 'package:transvolt_em/utils/dates.dart';

/// No FakeChecklistRepository exists in this suite (see providers.dart's own
/// note on ChecklistRepository vs the scheduling-only InspectionRepository)
/// -- a minimal stub for the one method filteredInspectionsProvider needs.
class _StubChecklistRepository implements ChecklistRepository {
  _StubChecklistRepository(this.inspections);

  final List<InspectionEntry> inspections;

  @override
  Future<List<InspectionEntry>> fetchInspections(
    String siteCode, {
    int? workTypeId,
  }) async =>
      inspections;

  @override
  Future<List<InspectionEntry>> todaysInspections(String siteCode) async =>
      inspections;

  @override
  Future<List<Checklist>> fetchChecklists(String siteCode) =>
      throw UnimplementedError();

  @override
  Future<Checklist> saveChecklist(String siteCode, Checklist checklist) =>
      throw UnimplementedError();

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
    int? milestoneKm,
    required List<InspectionResult> results,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<InspectionEntry>> recordInspectionBatch({
    required String siteCode,
    required int workTypeId,
    required String inspectedOn,
    String? entryTime,
    String? supervisor,
    required List<InspectionBatchItem> items,
  }) =>
      throw UnimplementedError();
}

/// Signs in against the fake auth repository and lands on MBMT, which is where
/// the seed entries live.
Future<ProviderContainer> signedInContainer() async {
  final container = fakeContainer();
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
          'employee': 'Sanjay Pawar',
        },
      );
      final byMechanic = await notifier.create(
        registerId: 'complaint',
        data: <String, String>{
          'bus': 'MH40LY1894',
          'date': Dates.today(),
          'mechanic': 'Arif Khan',
        },
      );
      final unattributed = await notifier.create(
        registerId: 'work',
        data: <String, String>{'bus': 'MH40LY1894', 'date': Dates.today()},
      );

      expect(byEmployee.enteredBy, 'Sanjay Pawar');
      expect(byMechanic.enteredBy, 'Arif Khan');
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

  group('photo', () {
    test('attachPhoto sets photoUrl on the entry', () async {
      final container = await signedInContainer();
      final notifier = container.read(entriesProvider.notifier);
      final created = await notifier.create(
        registerId: 'coolant',
        data: <String, String>{'bus': 'MH40LY1721', 'date': Dates.today()},
      );
      expect(created.photoUrl, isNull);

      final url = await notifier.attachPhoto(
        entryId: created.id,
        filename: 'leak.jpg',
        bytes: <int>[1, 2, 3],
      );

      final entries = container.read(entriesProvider).requireValue;
      final updated = entries.firstWhere((e) => e.id == created.id);
      expect(updated.photoUrl, url);
      expect(updated.photoUrl, isNotNull);
    });

    test('removePhoto clears photoUrl on the entry', () async {
      final container = await signedInContainer();
      final notifier = container.read(entriesProvider.notifier);
      final created = await notifier.create(
        registerId: 'coolant',
        data: <String, String>{'bus': 'MH40LY1721', 'date': Dates.today()},
      );
      await notifier.attachPhoto(
        entryId: created.id,
        filename: 'leak.jpg',
        bytes: <int>[1, 2, 3],
      );

      await notifier.removePhoto(created.id);

      final entries = container.read(entriesProvider).requireValue;
      expect(entries.firstWhere((e) => e.id == created.id).photoUrl, isNull);
    });
  });

  group('resolving a breakdown', () {
    test('a linked Work Done session that completes the ticket clears it from the open list', () async {
      // There is no direct "mark resolved" any more -- a breakdown only
      // resolves as a side effect of completing its linked ticket through a
      // Work Done session.
      final container = await signedInContainer();
      final open = container.read(openBreakdownsProvider);
      expect(open, isNotEmpty);

      await container.read(entriesProvider.notifier).create(
        registerId: 'work',
        data: <String, String>{
          'bus': 'MH40LY1721',
          'date': Dates.today(),
          'ticketId': open.first.id,
          'completesTicket': 'true',
        },
      );

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

  group('registerMonthEntriesProvider', () {
    test('finds an entry a month picked back reaches', () async {
      final container = await signedInContainer();
      // The seed's oldest MBMT entry, ~35 days back — reliably a different
      // calendar month from "This month", which is exactly the case
      // filteredEntriesProvider's capped cache would otherwise miss.
      final oldDate = Dates.today(-35);
      final oldMonth = oldDate.substring(0, 7);

      final results = await container.read(
        registerMonthEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          month: oldMonth,
        )).future,
      );

      expect(results.any((e) => e.date == oldDate), isTrue);
      expect(results.every((e) => e.date.startsWith(oldMonth)), isTrue);
    });

    test('a different month does not carry the entry over', () async {
      final container = await signedInContainer();
      final oldMonth = Dates.today(-35).substring(0, 7);
      final thisMonth = Dates.currentMonthPrefix();

      final results = await container.read(
        registerMonthEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          month: thisMonth,
        )).future,
      );

      expect(results.any((e) => e.date.startsWith(oldMonth)), isFalse);
    });

    test('still filters by register and the free-text query', () async {
      final container = await signedInContainer();
      final oldMonth = Dates.today(-35).substring(0, 7);

      final wrongRegister = await container.read(
        registerMonthEntriesProvider((
          site: 'MBMT',
          registerId: 'coolant',
          month: oldMonth,
        )).future,
      );
      expect(wrongRegister, isEmpty);

      container.read(entryFiltersProvider.notifier).setQuery('hvac filter');
      final searched = await container.read(
        registerMonthEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          month: oldMonth,
        )).future,
      );
      expect(searched, hasLength(1));
      expect(searched.first.data['defects'], contains('HVAC filter'));
    });
  });

  group('pendingFilterEntriesProvider', () {
    test('true matches only entries with an open ticket', () async {
      final container = await signedInContainer();
      final open = container.read(openBreakdownsProvider);
      expect(open, isNotEmpty);
      final openId = open.first.id;

      final pending = await container.read(
        pendingFilterEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          hasOpenTicket: true,
          dateFrom: null,
          dateTo: null,
        )).future,
      );
      expect(pending, isNotEmpty);
      expect(pending.every((e) => e.status == EntryStatus.open), isTrue);
      expect(pending.any((e) => e.id == openId), isTrue);

      await container.read(entriesProvider.notifier).create(
        registerId: 'work',
        data: <String, String>{
          'bus': 'MH40LY1721',
          'date': Dates.today(),
          'ticketId': openId,
          'completesTicket': 'true',
        },
      );
      final afterResolve = await container.read(
        pendingFilterEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          hasOpenTicket: true,
          dateFrom: null,
          dateTo: null,
        )).future,
      );
      expect(afterResolve.any((e) => e.id == openId), isFalse);
    });

    test('false matches only entries without an open ticket', () async {
      final container = await signedInContainer();
      final open = container.read(openBreakdownsProvider);
      expect(open, isNotEmpty);

      final complete = await container.read(
        pendingFilterEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          hasOpenTicket: false,
          dateFrom: null,
          dateTo: null,
        )).future,
      );

      expect(complete.any((e) => e.id == open.first.id), isFalse);
    });

    test('a date range narrows the result the same way the Registers screen shows it', () async {
      // The Registers screen keeps its PERIOD chips visible while a STATUS
      // chip is selected -- they must not be a no-op once one is.
      final container = await signedInContainer();
      final open = container.read(openBreakdownsProvider);
      expect(open, isNotEmpty);

      final excluded = await container.read(
        pendingFilterEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          hasOpenTicket: true,
          dateFrom: '2099-01-01',
          dateTo: null,
        )).future,
      );
      expect(excluded, isEmpty);

      final included = await container.read(
        pendingFilterEntriesProvider((
          site: 'MBMT',
          registerId: 'all',
          hasOpenTicket: true,
          dateFrom: null,
          dateTo: null,
        )).future,
      );
      expect(included.any((e) => e.id == open.first.id), isTrue);
    });
  });

  group('filteredInspectionsProvider hasOpenTicket', () {
    InspectionEntry entry(String id, {required List<InspectionResult> results}) {
      return InspectionEntry(
        id: id,
        siteCode: 'MBMT',
        vehicleId: 'v1',
        registrationNo: 'MH40LY1894',
        workTypeId: 1,
        workTypeCode: 'D.I',
        workTypeName: 'Daily inspection',
        inspectedOn: Dates.today(),
        results: results,
      );
    }

    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(overrides: [
        ...fakeOverrides(),
        checklistRepositoryProvider.overrideWithValue(
          _StubChecklistRepository(<InspectionEntry>[
            entry(
              'clean',
              results: const <InspectionResult>[
                InspectionResult(itemId: 'i1', result: CheckResult.ok),
              ],
            ),
            entry(
              'pending',
              results: const <InspectionResult>[
                InspectionResult(
                  itemId: 'i1',
                  result: CheckResult.notOk,
                  ticketId: 't1',
                  ticketStatus: 'open',
                ),
              ],
            ),
            entry(
              'completed',
              results: const <InspectionResult>[
                InspectionResult(
                  itemId: 'i1',
                  result: CheckResult.notOk,
                  ticketId: 't2',
                  ticketStatus: 'completed',
                ),
              ],
            ),
          ]),
        ),
      ]);
      addTearDown(container.dispose);
    });

    Future<void> signIn() async {
      await container
          .read(sessionProvider.notifier)
          .signInWithCredentials('TV4021', kSeedPassword);
      container.read(sessionProvider.notifier).enterApp();
      await container.read(siteInspectionsProvider.future);
    }

    test('true keeps only inspections with a still-open ticket', () async {
      await signIn();
      container.read(entryFiltersProvider.notifier).setHasOpenTicket(true);

      final results = container.read(filteredInspectionsProvider);
      expect(results.map((e) => e.id), <String>['pending']);
    });

    test('false keeps clean and completed, excludes pending', () async {
      await signIn();
      container.read(entryFiltersProvider.notifier).setHasOpenTicket(false);

      final results = container.read(filteredInspectionsProvider);
      expect(results.map((e) => e.id).toSet(), <String>{'clean', 'completed'});
    });

    test('null (All) keeps everything', () async {
      await signIn();

      final results = container.read(filteredInspectionsProvider);
      expect(results, hasLength(3));
    });
  });

  group('ticketSearchProvider', () {
    // The ticket picker offers the app-side register ids from
    // `registers.dart`; the API translates them to the backend's `Register`
    // values on the way out. The fake has to speak the same vocabulary, or
    // the screens pass it something the real service would 422 on and no test
    // notices.
    test('the picker\'s own register ids filter the results', () async {
      final container = await signedInContainer();

      final complaints = await container.read(
        ticketSearchProvider(
          (site: 'MBMT', register: 'complaint', q: 'wiper'),
        ).future,
      );
      expect(complaints, hasLength(1));
      expect(complaints.first.title, contains('Wiper blade'));

      // Same query, wrong register: the filter has to actually bite.
      final none = await container.read(
        ticketSearchProvider(
          (site: 'MBMT', register: 'breakdown', q: 'wiper'),
        ).future,
      );
      expect(none, isEmpty);
    });

    test('a wire register id is not a register id here', () async {
      final container = await signedInContainer();
      // `driver_complaint` is what goes on the wire, not what the repository
      // takes. Accepting it would mean the fake had drifted back to guessing.
      await expectLater(
        container.read(
          ticketSearchProvider(
            (site: 'MBMT', register: 'driver_complaint', q: 'wiper'),
          ).future,
        ),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
