import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'data/api/runtime_config.dart';
import 'router.dart';
import 'state/session.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything touches ApiClient/SiteOpsClient, so the resolved base
  // URLs are in place before the first provider reads them.
  await loadRuntimeConfig();
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
    // Restore stored JWTs (and finish an MS redirect if this load is one)
    // before the router decides the user is signed out.
    Future<void>.microtask(_bootstrap);
  }

  Future<void> _bootstrap() async {
    final config = await ref.read(ssoConfigProvider.future);
    if (!mounted) return;
    await ref.read(sessionProvider.notifier).bootstrap(config);
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
