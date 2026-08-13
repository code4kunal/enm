import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../repositories.dart';

/// Where the API lives, and whether to use it at all.
///
/// Both come from `--dart-define` so a build can be pointed at a real backend
/// without a code change:
///
/// ```sh
/// flutter run -d chrome \
///   --dart-define=API_BASE_URL=http://localhost:8123/api/v1 \
///   --dart-define=USE_API=true
/// ```
abstract final class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8123/api/v1',
  );

  /// Off by default so the app runs standalone against the in-memory fakes.
  static const bool useApi = bool.fromEnvironment('USE_API');
}

/// What the connected backend can actually do.
///
/// The client speaks the site vocabulary throughout. A backend that still
/// speaks `depot` and has no site/config/import endpoints is detected once at
/// sign-in, and the features it lacks fail with a message that says so rather
/// than a raw 404.
class ApiCapabilities {
  ApiCapabilities({this.siteManagement = false});

  /// True once `/sites` answers — i.e. the site rename and the config/import
  /// endpoints have landed.
  bool siteManagement;

  /// Query parameter naming the tenant. Flips to `site` with the rename.
  String get scopeParam => siteManagement ? 'site' : 'depot';
}

/// Thrown when the connected backend predates a feature.
class UnsupportedByBackend extends ApiException {
  const UnsupportedByBackend(super.message);
}

/// JSON transport with bearer auth and one transparent refresh on 401.
class ApiClient {
  ApiClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = (baseUrl ?? ApiConfig.baseUrl).replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  final ApiCapabilities capabilities = ApiCapabilities();

  String? _accessToken;
  String? _refreshToken;

  static const _accessKey = 'transvolt.access_token';
  static const _refreshKey = 'transvolt.refresh_token';

  bool get isAuthenticated => _accessToken != null;

  /// Restores a session from the last run so a page reload does not sign out.
  Future<void> restoreSession() async {
    final prefs = await _prefs();
    if (prefs == null) return;
    _accessToken = prefs.getString(_accessKey);
    _refreshToken = prefs.getString(_refreshKey);
  }

  Future<void> setTokens(String? access, String? refresh) async {
    // The in-memory copy is the one the request path reads, so it is set first
    // and unconditionally; persistence is a convenience on top.
    _accessToken = access;
    _refreshToken = refresh;

    final prefs = await _prefs();
    if (prefs == null) return;
    if (access == null) {
      await prefs.remove(_accessKey);
      await prefs.remove(_refreshKey);
    } else {
      await prefs.setString(_accessKey, access);
      if (refresh != null) await prefs.setString(_refreshKey, refresh);
    }
  }

  /// Null where there is no platform channel — a plain `dart test`, or a
  /// headless run. The session then lives for the process only, which is the
  /// right degradation rather than a crash on sign-in.
  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } on Exception {
      return null;
    } on Error {
      return null;
    }
  }

  Future<void> clearTokens() => setTokens(null, null);

  /// Probes for the site-era endpoints. Safe to call more than once.
  Future<void> detectCapabilities() async {
    try {
      await get('/sites');
      capabilities.siteManagement = true;
    } on UnsupportedByBackend {
      capabilities.siteManagement = false;
    } on ApiException {
      // Auth or transport trouble — leave the previous verdict alone rather
      // than downgrading a capable backend on a transient failure.
    }
  }

  // ─── Verbs ──────────────────────────────────────────────────────────────

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  Future<dynamic> post(String path, {Object? body}) =>
      _send('POST', path, body: body);

  Future<dynamic> put(String path, {Object? body}) =>
      _send('PUT', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Multipart upload used by photo attach and spreadsheet import.
  Future<dynamic> upload(
    String path, {
    required String field,
    required String fileName,
    required Uint8List bytes,
    Map<String, String> fields = const <String, String>{},
    String? contentType,
  }) async {
    Future<http.StreamedResponse> attempt() {
      final request = http.MultipartRequest('POST', _uri(path, null))
        ..fields.addAll(fields)
        ..files.add(
          http.MultipartFile.fromBytes(field, bytes, filename: fileName),
        );
      if (_accessToken != null) {
        request.headers['Authorization'] = 'Bearer $_accessToken';
      }
      return _http.send(request);
    }

    var streamed = await attempt();
    if (streamed.statusCode == 401 && await _refresh()) {
      streamed = await attempt();
    }
    return _decode(await http.Response.fromStream(streamed));
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    Future<http.Response> attempt() {
      final uri = _uri(path, query);
      final headers = <String, String>{
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json',
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };
      final encoded = body == null ? null : jsonEncode(body);

      return switch (method) {
        'GET' => _http.get(uri, headers: headers),
        'POST' => _http.post(uri, headers: headers, body: encoded),
        'PUT' => _http.put(uri, headers: headers, body: encoded),
        'DELETE' => _http.delete(uri, headers: headers),
        _ => throw ArgumentError('Unsupported method $method'),
      };
    }

    http.Response response;
    try {
      response = await attempt();
    } on Exception catch (e) {
      throw ApiException('Cannot reach the server at $baseUrl — $e');
    }

    // One refresh, then one retry. A second 401 means the session is gone.
    if (response.statusCode == 401 && await _refresh()) {
      response = await attempt();
    }
    return _decode(response);
  }

  Uri _uri(String path, Map<String, String>? query) {
    final cleaned = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$baseUrl$cleaned');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...query,
      },
    );
  }

  Future<bool> _refresh() async {
    final token = _refreshToken;
    if (token == null) return false;
    try {
      final response = await _http.post(
        _uri('/auth/refresh', null),
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, String>{'refresh_token': token}),
      );
      if (response.statusCode >= 400) {
        await clearTokens();
        return false;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      await setTokens(
        json['access_token'] as String?,
        json['refresh_token'] as String? ?? token,
      );
      return true;
    } on Exception {
      return false;
    }
  }

  /// Maps the backend's `{ "error": { code, message, fields } }` envelope onto
  /// [ApiException] so screens can render the message verbatim.
  dynamic _decode(http.Response response) {
    final status = response.statusCode;
    final text = response.body;

    if (status == 204 || text.isEmpty) {
      if (status >= 400) throw ApiException('Request failed ($status)');
      return null;
    }

    dynamic json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      if (status >= 400) throw ApiException('Request failed ($status)');
      return null;
    }

    if (status < 400) return json;

    var message = 'Request failed ($status)';
    var fields = const <String, String>{};

    if (json is Map<String, dynamic>) {
      final error = json['error'];
      if (error is Map<String, dynamic>) {
        message = error['message'] as String? ?? message;
        final raw = error['fields'];
        if (raw is Map) {
          fields = raw.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } else if (json['detail'] != null) {
        final detail = json['detail'];
        message = detail is String ? detail : jsonEncode(detail);
      }
    }

    // A 404 on a whole route family means the backend predates the feature.
    if (status == 404 && message == 'Not Found') {
      throw const UnsupportedByBackend(
        'This backend does not support that yet — run the site-management '
        'migration on the API.',
      );
    }
    if (status == 401) throw ApiException(message, fields: fields);
    if (status == 403) {
      throw ApiException(
        message == 'Request failed (403)'
            ? 'You do not have access to that'
            : message,
        fields: fields,
      );
    }
    throw ApiException(message, fields: fields);
  }

  void close() => _http.close();
}

/// Unwraps the backend's `{ "items": [...] }` list envelope.
List<Map<String, dynamic>> itemsOf(dynamic json) {
  if (json is List) return json.cast<Map<String, dynamic>>();
  if (json is Map<String, dynamic>) {
    final items = json['items'];
    if (items is List) return items.cast<Map<String, dynamic>>();
  }
  return const <Map<String, dynamic>>[];
}
