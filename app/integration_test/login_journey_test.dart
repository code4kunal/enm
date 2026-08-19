import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:transvolt_em/main.dart' as app;

import 'support/journey.dart';

/// Must match qa/personas.py.
const String kUser = String.fromEnvironment('QA_USER', defaultValue: 'QA_MGR');
const String kPassword =
    String.fromEnvironment('QA_PASSWORD', defaultValue: 'QaFloor@2026');
const String kSite = String.fromEnvironment('QA_SITE', defaultValue: 'QASITE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a manager signs in and reaches their site', (tester) async {
    app.main();
    await signIn(tester, userId: kUser, password: kPassword, site: kSite);

    // Past the login card: the User ID / Password pair is gone.
    expect(
      find.text('Ground operations register · All sites'),
      findsNothing,
      reason: 'still on the login screen after signing in',
    );

    // design/HANDOFF.md section 2: the shell header carries the E&M mark and
    // names the site the user is working in.
    expect(find.text('E&M'), findsOneWidget);
    expect(find.textContaining(kSite), findsWidgets);
  });
}
