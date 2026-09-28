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
}
