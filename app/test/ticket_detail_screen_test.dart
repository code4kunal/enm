import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/models/ticket_detail.dart';
import 'package:transvolt_em/screens/ticket_detail_screen.dart';
import 'package:transvolt_em/state/entries.dart';

RegisterEntry _breakdownEntry() => const RegisterEntry(
      id: 'e1',
      registerId: 'breakdown',
      date: '2026-09-29',
      time: '09:00',
      site: 'MBMT',
      enteredBy: 'Super Admin',
      displayId: 'BD-2026-000002',
      data: <String, String>{
        'bus': 'MH04LQ5737',
        'defectType': 'Brake',
        'complaint':
            'Brake pressure low, vehicle stopped for technical attention',
        'route': '7',
        'loss': '12.5',
        'remarks': 'Towed to workshop',
        'latitude': '19.1197',
        'longitude': '72.8468',
        'locationSource': 'gps',
      },
    );

/// The same breakdown, plus whatever the test under way cares about.
RegisterEntry _breakdownEntryWith(Map<String, String> extra) {
  final base = _breakdownEntry();
  return RegisterEntry(
    id: base.id,
    registerId: base.registerId,
    date: base.date,
    time: base.time,
    site: base.site,
    enteredBy: base.enteredBy,
    displayId: base.displayId,
    status: base.status,
    data: <String, String>{...base.data, ...extra},
  );
}

TicketDetail _ticketFor(RegisterEntry entry) => TicketDetail(
      ticketId: 't1',
      displayId: entry.displayId,
      status: 'open',
      title: 'Brake pressure low, vehicle stopped for technical attention',
      busNo: entry.busNumber,
      sourceEntry: entry,
      linkedSessions: const <Map<String, dynamic>>[],
      photos: const <EntryPhoto>[],
    );

Future<void> _pumpTicket(WidgetTester tester, TicketDetail ticket) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        ticketDetailProvider('t1').overrideWith((ref) => Future.value(ticket)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: TicketDetailScreen(ticketId: 't1')),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'test_ac1_ticket_detail_shows_the_breakdown_location',
    (tester) async {
      // Captured on the Breakdown form as "Location of Breakdown" and shown
      // on the Breakdowns list, but never on Ticket Detail -- which is the
      // screen the depot team reads when the bus is already off the road.
      final ticket = _ticketFor(
        _breakdownEntryWith(<String, String>{'loc': 'Kashimira signal'}),
      );
      await _pumpTicket(tester, ticket);

      expect(
        find.textContaining('Location: Kashimira signal', findRichText: true),
        findsOneWidget,
      );

      // …and the row is optional, like every other row on this card: an
      // unset location must not render a dangling "Location:" label. (The
      // separate GPS card keeps its own "Location" title either way.)
      await _pumpTicket(tester, _ticketFor(_breakdownEntry()));
      expect(
        find.textContaining(RegExp(r'Location:'), findRichText: true),
        findsNothing,
      );
      expect(find.text('Location'), findsOneWidget);
    },
  );

  testWidgets(
    'test_ac3_ticket_detail_shows_the_odometer_reading',
    (tester) async {
      final ticket = _ticketFor(
        _breakdownEntryWith(<String, String>{'odo': '121000'}),
      );
      await _pumpTicket(tester, ticket);

      expect(
        find.textContaining(RegExp(r'Odometer.*121,?000'), findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'renders defect type, loss km, remarks, and captured location',
    (tester) async {
      final ticket = TicketDetail(
        ticketId: 't1',
        displayId: 'BD-2026-000002',
        status: 'open',
        title: 'Brake pressure low, vehicle stopped for technical attention',
        busNo: 'MH04LQ5737',
        sourceEntry: _breakdownEntry(),
        linkedSessions: const <Map<String, dynamic>>[],
        photos: const <EntryPhoto>[],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ticketDetailProvider('t1')
                .overrideWith((ref) => Future.value(ticket)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TicketDetailScreen(ticketId: 't1')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Brake', findRichText: true), findsWidgets);
      expect(find.textContaining('12.5', findRichText: true), findsWidgets);
      expect(find.textContaining('Towed to workshop', findRichText: true),
          findsWidgets);
      expect(find.textContaining('19.1197', findRichText: true), findsWidgets);
      expect(find.textContaining('GPS', findRichText: true), findsWidgets);
    },
  );

  testWidgets(
    'work session line shows spare parts used',
    (tester) async {
      final ticket = TicketDetail(
        ticketId: 't1',
        displayId: 'BD-2026-000002',
        status: 'open',
        title: 'Brake pressure low, vehicle stopped for technical attention',
        busNo: 'MH04LQ5737',
        sourceEntry: _breakdownEntry(),
        linkedSessions: <Map<String, dynamic>>[
          <String, dynamic>{
            'entry_date': '2026-09-29',
            'shift': 'C',
            'attendees': <dynamic>[],
            'completes_ticket': false,
            'spare_parts': <dynamic>[
              <String, dynamic>{
                'part_id': 'p1',
                'part_no': 'SP-1',
                'name': 'Brake pad'
              },
            ],
          },
        ],
        photos: const <EntryPhoto>[],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ticketDetailProvider('t1')
                .overrideWith((ref) => Future.value(ticket)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TicketDetailScreen(ticketId: 't1')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
          find.textContaining('Brake pad', findRichText: true), findsWidgets);
    },
  );

  testWidgets(
    'a location with lat/long renders an actual map, not just text',
    (tester) async {
      final ticket = TicketDetail(
        ticketId: 't1',
        displayId: 'BD-2026-000002',
        status: 'open',
        title: 'Brake pressure low, vehicle stopped for technical attention',
        busNo: 'MH04LQ5737',
        sourceEntry: _breakdownEntry(),
        linkedSessions: const <Map<String, dynamic>>[],
        photos: const <EntryPhoto>[],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ticketDetailProvider('t1')
                .overrideWith((ref) => Future.value(ticket)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TicketDetailScreen(ticketId: 't1')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(FlutterMap), findsOneWidget);
    },
  );

  testWidgets(
    'no work sessions yet shows an explicit empty state, not a missing section',
    (tester) async {
      final ticket = TicketDetail(
        ticketId: 't1',
        displayId: 'BD-2026-000002',
        status: 'open',
        title: 'Brake pressure low, vehicle stopped for technical attention',
        busNo: 'MH04LQ5737',
        sourceEntry: _breakdownEntry(),
        linkedSessions: const <Map<String, dynamic>>[],
        photos: const <EntryPhoto>[],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ticketDetailProvider('t1')
                .overrideWith((ref) => Future.value(ticket)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TicketDetailScreen(ticketId: 't1')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Work sessions'), findsOneWidget);
      expect(
        find.textContaining(
            'No Work Done session logged against this ticket yet'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'an inspection-sourced ticket (no sourceEntry) still shows a title, bus, timeline, and sessions',
    (tester) async {
      // A Work Done session can link to any ticket regardless of source
      // kind, so this screen is reachable for an inspection-sourced ticket
      // too -- it must not assume sourceEntry is non-null.
      const ticket = TicketDetail(
        ticketId: 't1',
        displayId: 'DI-2026-000001',
        status: 'completed',
        title: 'Brake check · MH40LY1894',
        busNo: 'MH40LY1894',
        sourceEntry: null,
        linkedSessions: <Map<String, dynamic>>[
          <String, dynamic>{
            'entry_date': '2026-09-29',
            'shift': 'C',
            'attendees': <dynamic>[],
            'completes_ticket': true,
          },
        ],
        photos: <EntryPhoto>[],
        attendedAt: '11:05',
        completedAt: '12:30',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ticketDetailProvider('t1')
                .overrideWith((ref) => Future.value(ticket)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TicketDetailScreen(ticketId: 't1')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
          find.textContaining('Brake check', findRichText: true), findsWidgets);
      expect(
          find.textContaining('MH40LY1894', findRichText: true), findsWidgets);
      expect(find.textContaining('11:05', findRichText: true), findsWidgets);
      expect(find.textContaining('12:30', findRichText: true), findsWidgets);
      expect(find.text('Work sessions'), findsOneWidget);
    },
  );
}
