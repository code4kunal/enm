import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:transvolt_em/models/entry.dart';
import 'package:transvolt_em/screens/registers_screen.dart';
import 'package:transvolt_em/state/entries.dart';
import 'package:transvolt_em/state/session.dart';
import 'package:transvolt_em/widgets/page_body.dart';

import 'support/fake_store.dart';
import 'support/harness.dart';
import 'support/seed.dart';

/// Item 5: a register row surfaces the entry's own display id (BD-…,
/// DC-…, WD-…) -- previously only Ticket Detail showed it.
void main() {
  setUpAll(() => initializeDateFormatting('en_IN'));

  Future<ProviderContainer> signedIn(WidgetTester tester) async {
    final store = FakeStore();
    final container = ProviderContainer(overrides: fakeOverrides(store));
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      await container
          .read(sessionProvider.notifier)
          .signInWithCredentials('TV4021', kSeedPassword);
      container.read(sessionProvider.notifier).enterApp();
      await container.read(entriesProvider.future);
    });
    return container;
  }

  Future<void> pumpRegisters(WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PageBody(child: RegistersScreen())),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final (registerId, data) in <(String, Map<String, String>)>[
    ('work', <String, String>{'bus': 'MH40LY1894', 'defects': 'AC not cooling'}),
    ('breakdown', <String, String>{
      'bus': 'MH40LY1895',
      'complaint': 'Brake pressure low',
      't_reported': '09:00',
    }),
    ('complaint', <String, String>{'bus': 'MH40LY1894', 'complaint': 'Harsh braking'}),
  ]) {
    testWidgets('$registerId register row shows the entry\'s display id', (tester) async {
      final container = await signedIn(tester);
      late final RegisterEntry created;
      await tester.runAsync(() async {
        created = await container
            .read(entriesProvider.notifier)
            .create(registerId: registerId, data: data);
      });

      await pumpRegisters(tester, container);

      expect(created.displayId, isNotEmpty);
      expect(
        find.textContaining(created.displayId, findRichText: true),
        findsWidgets,
      );
    });
  }
}
