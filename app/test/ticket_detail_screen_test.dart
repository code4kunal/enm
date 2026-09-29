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
        'complaint': 'Brake pressure low, vehicle stopped for technical attention',
        'route': '7',
        'loss': '12.5',
        'remarks': 'Towed to workshop',
        'latitude': '19.1197',
        'longitude': '72.8468',
        'locationSource': 'gps',
      },
    );

void main() {
  testWidgets(
    'renders defect type, loss km, remarks, and captured location',
    (tester) async {
      final ticket = TicketDetail(
        ticketId: 't1',
        displayId: 'BD-2026-000002',
        status: 'open',
        sourceEntry: _breakdownEntry(),
        linkedSessions: const <Map<String, dynamic>>[],
        photos: const <EntryPhoto>[],
      );

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

      expect(find.textContaining('Brake', findRichText: true), findsWidgets);
      expect(find.textContaining('12.5', findRichText: true), findsWidgets);
      expect(find.textContaining('Towed to workshop', findRichText: true), findsWidgets);
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
        sourceEntry: _breakdownEntry(),
        linkedSessions: <Map<String, dynamic>>[
          <String, dynamic>{
            'entry_date': '2026-09-29',
            'shift': 'C',
            'attendees': <dynamic>[],
            'completes_ticket': false,
            'spare_parts': <dynamic>[
              <String, dynamic>{'part_id': 'p1', 'part_no': 'SP-1', 'name': 'Brake pad'},
            ],
          },
        ],
        photos: const <EntryPhoto>[],
      );

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

      expect(find.textContaining('Brake pad', findRichText: true), findsWidgets);
    },
  );

  testWidgets(
    'a location with lat/long renders an actual map, not just text',
    (tester) async {
      final ticket = TicketDetail(
        ticketId: 't1',
        displayId: 'BD-2026-000002',
        status: 'open',
        sourceEntry: _breakdownEntry(),
        linkedSessions: const <Map<String, dynamic>>[],
        photos: const <EntryPhoto>[],
      );

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
        sourceEntry: _breakdownEntry(),
        linkedSessions: const <Map<String, dynamic>>[],
        photos: const <EntryPhoto>[],
      );

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

      expect(find.text('Work sessions'), findsOneWidget);
      expect(
        find.textContaining('No Work Done session logged against this ticket yet'),
        findsOneWidget,
      );
    },
  );
}
