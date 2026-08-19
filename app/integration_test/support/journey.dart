import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Advances time without `pumpAndSettle`.
///
/// The login chevrons drift on an 11-16s loop, so `pumpAndSettle` waits for a
/// quiescence that never arrives. Every journey pumps fixed frames instead.
Future<void> settle(WidgetTester tester, {int seconds = 4}) async {
  for (var i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Signs in with a User ID, per design/HANDOFF.md section 1.
///
/// HANDOFF describes a depot-select stage after sign-in. It is tapped only if
/// it appears: a user with one site may be taken straight through, and a
/// journey that insists on a screen the user never sees is testing the design
/// document rather than the app.
Future<void> signIn(
  WidgetTester tester, {
  required String userId,
  required String password,
  required String site,
}) async {
  await settle(tester);

  final fields = find.byType(EditableText);
  expect(
    fields,
    findsNWidgets(2),
    reason: 'HANDOFF section 1: a User ID field and a Password field',
  );

  await tester.enterText(fields.at(0), userId);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.enterText(fields.at(1), password);
  await tester.pump(const Duration(milliseconds: 300));

  await tester.tap(find.text('Sign in'));
  await settle(tester, seconds: 5);

  final continueCta = find.text('Continue to $site');
  if (continueCta.evaluate().isNotEmpty) {
    await tester.tap(continueCta);
    await settle(tester, seconds: 4);
  }
}

/// Lets in-flight requests land before the widget tree is torn down.
///
/// Each `testWidgets` boots the app again, and a test that ends while the
/// client is mid-request sees it aborted — reported as a failure after the
/// test has already passed. Pumping a little longer at the end is the cheapest
/// way to keep that noise out of a real signal.
Future<void> quiesce(WidgetTester tester) async {
  await settle(tester, seconds: 3);
}
