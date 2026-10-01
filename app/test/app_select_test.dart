import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/widgets/form_controls.dart';

void main() {
  testWidgets(
    'opening the dropdown on a field wider than 480px does not throw',
    (tester) async {
      // Reproduces live: on any normal desktop width, a form field commonly
      // renders wider than 480 -- the overlay's minWidth (the field's own
      // width) must never exceed its maxWidth (clamped to 480), or Flutter
      // throws "BoxConstraints has non-normalized width constraints."
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: AppSelect(
                value: null,
                options: const <String>['MH04LQ5736', 'MH04LQ5737'],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AppSelect));
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shows a value the field already holds even when the options list '
    'does not offer it',
    (tester) async {
      // A retired bus autofilled from a linked ticket (kept out of the
      // active fleet picker on purpose) must still show, or it reads to a
      // mechanic as the autofill having silently failed -- even though the
      // value saves correctly underneath.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSelect(
              value: 'MH04LY1894',
              options: const <String>['MH04LQ5736', 'MH04LQ5737'],
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('MH04LY1894'), findsOneWidget);
    },
  );

  testWidgets(
    'shows a held bus registration when the options list is empty',
    (tester) async {
      // Options can be empty while a value is already on the field (the
      // fleet list hasn't loaded, or every active bus was filtered out).
      // That must not swap the registration for the empty hint.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSelect(
              value: 'MH04LY1894',
              options: const <String>[],
              emptyHint: 'No buses loaded',
              mono: true,
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('MH04LY1894'), findsOneWidget);
      expect(find.text('No buses loaded'), findsNothing);

      final shown = tester.widget<Text>(find.text('MH04LY1894'));
      expect(shown.style?.fontWeight, FontWeight.w600);
      expect(shown.style?.fontSize, 16);

      await tester.tap(find.byType(AppSelect));
      await tester.pump();
      expect(find.text('No matches'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shows emptyHint when options are empty and nothing is held',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppSelect(
              value: null,
              options: const <String>[],
              emptyHint: 'No buses loaded',
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('No buses loaded'), findsOneWidget);
    },
  );
}
