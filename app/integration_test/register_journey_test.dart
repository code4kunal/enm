import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:transvolt_em/main.dart' as app;

import 'support/journey.dart';

/// Must match qa/personas.py.
const String kUser = String.fromEnvironment('QA_USER', defaultValue: 'QA_MGR');
const String kPassword =
    String.fromEnvironment('QA_PASSWORD', defaultValue: 'QaFloor@2026');
const String kSite = String.fromEnvironment('QA_SITE', defaultValue: 'QASITE');

/// The paper registers, named as design/HANDOFF.md section 4 names them.
/// PM Schedule Attention is retired in favour of Inspections — see
/// qa/findings/2026-08-19-0003.md — so four are writable.
const List<String> kLiveRegisters = <String>[
  'Daily Work Done',
  'Coolant Topping',
  'Driver Complaints',
  'Breakdown Report',
];

/// One test, not four.
///
/// A journey is a sequence — a manager signs in once and moves through the
/// app — and modelling it as one walk is also what keeps it stable: each
/// `testWidgets` boots the app afresh, and a second boot tears the first one
/// down mid-request, which surfaces as an aborted call blamed on whichever
/// test happened to finish first.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a manager walks the app after signing in', (tester) async {
    unawaited(app.main());
    await signIn(tester, userId: kUser, password: kPassword, site: kSite);

    // --- HANDOFF section 2: the shell names the site being worked in.
    // CLAUDE.md calls the header switcher the only tenant boundary the UI
    // exposes, so it has to say which side of it the user is on.
    expect(find.text('E&M'), findsOneWidget);
    expect(
      find.textContaining(kSite),
      findsWidgets,
      reason: 'the header does not name the current site',
    );

    // --- HANDOFF section 3: a card per live register.
    for (final String name in kLiveRegisters) {
      expect(
        find.textContaining(name),
        findsWidgets,
        reason: '$name has no card on Home',
      );
    }

    // --- HANDOFF section 5: the Registers view and its period chips.
    final Finder registers = find.text('Registers');
    expect(registers, findsWidgets, reason: 'HANDOFF section 2 names this tab');
    await tester.tap(registers.first);
    await settle(tester);
    for (final String chip in <String>['Today', 'This month']) {
      expect(
        find.textContaining(chip),
        findsWidgets,
        reason: '$chip period chip missing from the Registers view',
      );
    }

    // --- HANDOFF section 6: the breakdown tracker, whose cards carry an
    // OPEN or RESOLVED pill. The screen has to read sensibly when empty too.
    final Finder breakdowns = find.text('Breakdowns');
    expect(breakdowns, findsWidgets, reason: 'HANDOFF section 2 names this tab');
    await tester.tap(breakdowns.first);
    await settle(tester);
    final bool hasCards = find.textContaining('OPEN').evaluate().isNotEmpty ||
        find.textContaining('RESOLVED').evaluate().isNotEmpty;
    final bool saysEmpty = find.textContaining('No ').evaluate().isNotEmpty;
    expect(
      hasCards || saysEmpty,
      isTrue,
      reason: 'the tracker shows neither a breakdown nor an empty state',
    );

    await quiesce(tester);
  });
}
