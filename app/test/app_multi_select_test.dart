import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/widgets/form_controls.dart';

/// [AppMultiSelect] used to render its options list inline, in the form's
/// own layout, visible whenever any unselected option existed -- not a
/// dropdown at all, just a permanently-open list pushing everything below
/// it down the page. These pin the fixed behaviour: the options list is a
/// floating overlay, shown only while the search field has focus, same as
/// [AppSelect].
void main() {
  Widget harness({
    List<String> values = const <String>[],
    List<String> options = const <String>['Rahul Sharma', 'Priya Nair', 'Amit Verma'],
    ValueChanged<List<String>>? onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AppMultiSelect(
          values: values,
          options: options,
          onChanged: onChanged ?? (_) {},
        ),
      ),
    );
  }

  testWidgets(
    'the options list is not visible before the field is focused',
    (tester) async {
      await tester.pumpWidget(harness());
      await tester.pump();

      // Unselected options exist, but nobody has touched the field yet --
      // this must not be visible, and it must not have pushed anything
      // else in the (non-existent, here) surrounding form down.
      expect(find.text('Rahul Sharma'), findsNothing);
      expect(find.text('Priya Nair'), findsNothing);
    },
  );

  testWidgets(
    'focusing the search field opens the options as an overlay',
    (tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(find.text('Rahul Sharma'), findsOneWidget);
      expect(find.text('Priya Nair'), findsOneWidget);
    },
  );

  testWidgets(
    'picking an option adds it and removes it from the open list',
    (tester) async {
      final picked = <List<String>>[];
      await tester.pumpWidget(
        harness(onChanged: (v) => picked.add(v)),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.tap(find.text('Rahul Sharma'));
      await tester.pump();

      expect(picked, <List<String>>[
        ['Rahul Sharma'],
      ]);
    },
  );

  testWidgets(
    'a selected value shows as a chip whether or not the field is focused',
    (tester) async {
      await tester.pumpWidget(harness(values: const <String>['Rahul Sharma']));
      await tester.pump();

      expect(find.text('Rahul Sharma'), findsOneWidget);
      // ...and it does not also appear in the (closed) options list.
      expect(find.byType(InputChip), findsOneWidget);
    },
  );

  testWidgets(
    'losing focus closes the options overlay',
    (tester) async {
      await tester.pumpWidget(harness());
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.text('Rahul Sharma'), findsOneWidget);

      // Move focus elsewhere.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Rahul Sharma'), findsNothing);
    },
  );
}
