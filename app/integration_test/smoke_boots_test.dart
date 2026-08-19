import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:transvolt_em/main.dart' as app;

/// The client boots and paints a login screen a depot user would recognise.
///
/// Every string asserted here comes from `design/HANDOFF.md` section 1, not
/// from the widget source. Reading the implementation to decide what to assert
/// is how a test starts confirming the code instead of checking the promise.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The login chevrons drift on an 11-16s loop, so `pumpAndSettle` never
  /// returns. Pump a fixed number of frames instead.
  Future<void> settle(WidgetTester tester, {int seconds = 4}) async {
    for (var i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('the app boots to the login screen', (tester) async {
    unawaited(app.main());
    await settle(tester);

    expect(find.text('E & M MAINTENANCE'), findsOneWidget);
    expect(find.text('Ground operations register · All sites'), findsOneWidget);
  });

  testWidgets('the login screen offers the User ID path', (tester) async {
    unawaited(app.main());
    await settle(tester);

    // HANDOFF section 1: a User ID input, a Password input, a black Sign in
    // button. This is the path ground staff without a Transvolt mail ID use.
    expect(find.byType(EditableText), findsNWidgets(2));
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets(
    'the login screen offers Microsoft sign-in exactly when it is usable',
    (tester) async {
      unawaited(app.main());
      await settle(tester);

      // HANDOFF section 1 describes a configured deployment: a Microsoft
      // button above a divider reading "OR SIGN IN WITH USER ID". The server
      // decides whether this deployment is one, via /auth/sso/config, so the
      // promise is asserted against that rather than against the screenshot.
      //
      // Offering a button that cannot obtain a token would be the real bug,
      // so the two states are checked together: the button and the "OR" go in
      // and out as one.
      final button = find.text('Sign in with Microsoft');
      final withOr = find.text('OR SIGN IN WITH USER ID');
      final withoutOr = find.text('SIGN IN WITH USER ID');

      if (button.evaluate().isNotEmpty) {
        expect(withOr, findsOneWidget,
            reason: 'SSO is offered, so HANDOFF section 1 wants the "OR"');
        expect(withoutOr, findsNothing);
      } else {
        expect(withoutOr, findsOneWidget,
            reason: 'no SSO, so the divider names the only path there is');
        expect(withOr, findsNothing);
      }

      // Either way the User ID path is always there: HANDOFF section 1 exists
      // for ground staff without a Transvolt mail ID.
      expect(find.text('Sign in'), findsOneWidget);
    },
  );
}
