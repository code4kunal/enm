import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/screens/breakdowns_screen.dart';
import 'package:transvolt_em/state/entries.dart';
import 'package:transvolt_em/state/providers.dart';

/// One open breakdown, as the list fetch delivers it.
///
/// `driver` carries what the register stored (the site's driver code, which
/// is the only driver identity the client ever holds — the drivers master
/// list is a list of codes, and Ticket Detail already renders this value
/// verbatim as "Driver").
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
      // who was behind the wheel.
      await _pump(tester, _breakdown(<String, String>{'driver': 'DRV221'}));

      expect(
        find.textContaining('DRV221', findRichText: true),
        findsWidgets,
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
