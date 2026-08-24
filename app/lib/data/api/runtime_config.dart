import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'siteops_client.dart';

/// Loads `config.json`, deployed alongside the built app, and overwrites
/// [ApiConfig.baseUrl] / [SiteOpsConfig.baseUrl] with whatever it finds.
///
/// This is what makes one Docker image portable across dev/staging/prod:
/// `docker-entrypoint.sh` writes that file from `API_BASE_URL` /
/// `SITEOPS_BASE_URL` env vars at container **start**, not at `flutter
/// build` time, so repointing an environment is a container restart, not a
/// rebuild.
///
/// Must run before [ApiClient]/[SiteOpsClient] are constructed — call from
/// `main()` before `runApp`. Falls back to the `--dart-define` compile-time
/// value already on [ApiConfig.baseUrl]/[SiteOpsConfig.baseUrl] when the file
/// is missing, unreachable, or a key is blank — a plain `flutter run` never
/// serves `config.json` and keeps working unchanged.
Future<void> loadRuntimeConfig() async {
  try {
    final response = await http.get(Uri.parse('config.json'));
    if (response.statusCode != 200) return;

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    final apiBaseUrl = json['apiBaseUrl'] as String?;
    if (apiBaseUrl != null && apiBaseUrl.isNotEmpty) {
      ApiConfig.baseUrl = apiBaseUrl;
    }

    final siteopsBaseUrl = json['siteopsBaseUrl'] as String?;
    if (siteopsBaseUrl != null && siteopsBaseUrl.isNotEmpty) {
      SiteOpsConfig.baseUrl = siteopsBaseUrl;
    }
  } on Exception {
    // No config.json to fetch (local `flutter run`, a headless test host) —
    // the dart-define default already on ApiConfig/SiteOpsConfig stands.
  }
}
