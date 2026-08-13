import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/widgets/page_body.dart';
import 'package:transvolt_em/widgets/sheet.dart';

/// A page taller than the window has to scroll rather than overflow.
///
/// This used to fail for every screen in the app: the shell wrapped the
/// `ShellRoute`'s Navigator in a scroll view, the Navigator could not lay out
/// against an unbounded height, and it collapsed to an arbitrary box — so tall
/// screens painted past the bottom of the window with no way to reach the rest.
void main() {
  _sheetTests();

  testWidgets('a page taller than the window scrolls instead of overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const SizedBox(height: 100, child: Text('header')),
              // The shell hands its child a bounded box and nothing else.
              Expanded(
                child: PageBody(
                  child: Column(
                    children: <Widget>[
                      for (var i = 0; i < 40; i++)
                        SizedBox(height: 60, child: Text('row $i')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // Overflowing throws in a test binding, so a clean pump is half the
    // assertion.
    expect(tester.takeException(), isNull);

    // The other half: there is somewhere to scroll to. A collapsed viewport
    // reports no extent and simply paints past the bottom of the window.
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    expect(position.maxScrollExtent, greaterThan(0));

    await tester.drag(find.byType(PageBody), const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(position.pixels, greaterThan(0));
    expect(find.text('row 39'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short page does not scroll and does not throw',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Expanded(child: PageBody(child: Text('short'))),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('short'), findsOneWidget);
  });
}

/// A form long enough to scroll is exactly the form whose save button goes
/// missing, so [EditorSheet] pins it. This is the shape of the bug the off-road
/// form shipped with: the sheet ran off the bottom of the window with no way to
/// reach the action.
void _sheetTests() {
  testWidgets('a long form keeps its action in view', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showEditorSheet<void>(
                context: context,
                builder: (_) => EditorSheet(
                  title: 'Put a bus off the road',
                  subtitle: 'One open case per bus.',
                  action: FilledButton(
                    onPressed: () {},
                    child: const Text('Save'),
                  ),
                  children: <Widget>[
                    for (var i = 0; i < 25; i++)
                      SizedBox(height: 60, child: Text('field $i')),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Put a bus off the road'), findsOneWidget);

    // The action is on screen without scrolling anywhere.
    final save = tester.getRect(find.text('Save'));
    expect(save.bottom, lessThanOrEqualTo(700));
    expect(save.top, greaterThan(0));

    // And the fields still scroll under it.
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable).last).position;
    expect(position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('a short form makes a short sheet', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showEditorSheet<void>(
                context: context,
                builder: (_) => const EditorSheet(
                  title: 'Short',
                  children: <Widget>[SizedBox(height: 40, child: Text('one'))],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Well under the 92% ceiling — a two-line form must not fill the window.
    expect(tester.getRect(find.byType(EditorSheet)).height, lessThan(400));
  });
}
