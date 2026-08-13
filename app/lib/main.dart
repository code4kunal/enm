import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'router.dart';
import 'state/session.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Home's date line renders in en_IN.
  await initializeDateFormatting('en_IN');
  runApp(const ProviderScope(child: TransvoltEmApp()));
}

class TransvoltEmApp extends ConsumerStatefulWidget {
  const TransvoltEmApp({super.key});

  @override
  ConsumerState<TransvoltEmApp> createState() => _TransvoltEmAppState();
}

class _TransvoltEmAppState extends ConsumerState<TransvoltEmApp> {
  @override
  void initState() {
    super.initState();
    // A Microsoft sign-in finishes on the page load *after* the redirect, so
    // the first thing the app does is ask whether this is that load.
    Future<void>.microtask(_resumeSignIn);
  }

  Future<void> _resumeSignIn() async {
    final config = await ref.read(ssoConfigProvider.future);
    if (!mounted) return;
    await ref.read(sessionProvider.notifier).resumeMicrosoftSignIn(config);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Transvolt E&M Maintenance',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
