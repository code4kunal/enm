import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/screens/breakdowns_screen.dart';
import 'package:transvolt_em/state/entries.dart';
import 'package:transvolt_em/state/providers.dart';

/// One open breakdown, as the list fetch delivers it.
///
/// `driver` is the site's driver code (the form's own FK value); `driverName`
/// is the server-resolved display name the card now reads -- the card
/// falls back to the code only for an entry whose driver has since been
/// removed from the master list.
RegisterEntry _breakdown([Map<String, String> extra = const <String, String>{}]) {
  return RegisterEntry(
    id: 'bd1',
    registerId: 'breakdown',
    date: '2026-09-29',
    time: '14:45',
    site: 'MBMT',
    enteredBy: 'Rahul Sharma (TV4021)',
    displayId: 'BD-2026-000002',
    status: EntryStatus.open,
    data: <String, String>{
      'bus': 'MH04LQ5737',
      'complaint': 'HV contactor tripped, bus immobile',
      'loc': 'Kashimira signal',
      't_reported': '14:45',
      'loss': '18.5',
      ...extra,
    },
  );
}

Future<void> _pump(WidgetTester tester, RegisterEntry entry) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        breakdownsProvider.overrideWithValue(<RegisterEntry>[entry]),
        siteDisplayNameProvider.overrideWithValue('Mira Bhayandar'),
        vehicleNameProvider(entry.busNumber)
            .overrideWithValue(entry.busNumber),
        // The tracker fetches each card's own detail for linked sessions;
        // serve it from the same row so no socket is opened.
        entryDetailProvider(entry.id).overrideWith((ref) => Future.value(entry)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BreakdownsScreen()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'test_ac2_breakdown_card_shows_the_driver',
    (tester) async {
      // Captured on the Breakdown form and shown on Ticket Detail, but never
      // on the tracker — which is the screen a supervisor scans to find out
      // who was behind the wheel. The name, not the bare code: that's what
      // a supervisor scanning the tracker can actually recognise.
      await _pump(
        tester,
        _breakdown(<String, String>{
          'driver': 'DRV221',
          'driverName': 'Rakesh Pawar',
        }),
      );

      expect(
        find.textContaining('Rakesh Pawar', findRichText: true),
        findsWidgets,
      );
      expect(
        find.textContaining('DRV221', findRichText: true),
        findsNothing,
      );

      // …without displacing what the tracker already shows — these are the
      // columns ground staff read down.
      expect(find.textContaining('MH04LQ5737', findRichText: true), findsWidgets);
      expect(
        find.textContaining('Kashimira signal', findRichText: true),
        findsWidgets,
      );
      expect(find.textContaining('18.5', findRichText: true), findsWidgets);
      expect(
        find.textContaining('HV contactor tripped', findRichText: true),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'test_ac2_breakdown_card_falls_back_to_the_driver_code_without_a_name',
    (tester) async {
      // An entry fetched before the server resolved driver_name, or whose
      // driver has since been removed from the master list -- the card
      // must still show *something* identifying, not a blank.
      await _pump(tester, _breakdown(<String, String>{'driver': 'DRV221'}));

      expect(
        find.textContaining('DRV221', findRichText: true),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'test_item5_breakdown_card_shows_the_entrys_display_id',
    (tester) async {
      // Mechanics quote this id over the phone/radio -- it was only ever
      // shown on Ticket Detail, never on the tracker itself.
      await _pump(tester, _breakdown());

      expect(
        find.textContaining('BD-2026-000002', findRichText: true),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'test_ac3_breakdown_card_shows_the_odometer_reading',
    (tester) async {
      await _pump(tester, _breakdown(<String, String>{'odo': '121000'}));

      expect(
        find.textContaining(RegExp(r'121,?000'), findRichText: true),
        findsWidgets,
      );
    },
  );
}
