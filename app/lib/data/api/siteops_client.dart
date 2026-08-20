import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../repositories.dart';

/// SiteOps platform API — vehicle master, site dropdown, onboarding.
///
/// Base URL from `--dart-define=SITEOPS_BASE_URL=...` ([SiteOpsConfig.baseUrl]).
/// Auth tokens are written by [ApiAuthRepository.signInWithCredentials], which
/// signs in against SiteOps and persists the bearer token under the same keys
/// as [ApiClient].
abstract final class SiteOpsConfig {
  static const String baseUrl = String.fromEnvironment(
    'SITEOPS_BASE_URL',
    defaultValue: 'https://dev-siteops-platform.transvolt.org/api/v1',
  );
}

class SiteOpsClient {
  SiteOpsClient({String? baseUrl, http.Client? httpClient})
      : baseUrl =
            (baseUrl ?? SiteOpsConfig.baseUrl).replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  static const _accessKey = 'transvolt.access_token';

  Future<String?> _accessToken() async {
    final prefs = await _prefs();
    return prefs?.getString(_accessKey);
  }

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } on Exception {
      return null;
    } on Error {
      return null;
    }
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  Future<dynamic> post(String path, {Object? body}) =>
      _send('POST', path, body: body);

  Future<dynamic> put(String path, {Object? body}) =>
      _send('PUT', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Form/multipart write used by vehicle create and update.
  Future<dynamic> multipart(
    String method,
    String path,
    Map<String, dynamic> fields,
  ) async {
    Future<http.StreamedResponse> attempt() async {
      final request = http.MultipartRequest('POST', _uri(path, null));
      if (method != 'POST') {
        request.headers['X-HTTP-Method-Override'] = method;
      }
      _flattenFields(request.fields, fields);
      final token = await _accessToken();
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }
      return _http.send(request);
    }

    http.StreamedResponse streamed;
    try {
      streamed = await attempt();
    } on Exception catch (e) {
      throw ApiException('Cannot reach SiteOps at $baseUrl — $e');
    }
    return _decode(await http.Response.fromStream(streamed));
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
  }) async {
    Future<http.Response> attempt() async {
      final uri = _uri(path, query);
      final token = await _accessToken();
      final headers = <String, String>{
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
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
      throw ApiException('Cannot reach SiteOps at $baseUrl — $e');
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

  void _flattenFields(
    Map<String, String> target,
    Map<String, dynamic> source,
  ) {
    for (final entry in source.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (value is List) {
        for (final item in value) {
          target['${entry.key}[]'] = item.toString();
        }
      } else if (value is bool || value is num) {
        target[entry.key] = value.toString();
      } else {
        target[entry.key] = value.toString();
      }
    }
  }

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
      if (json['message'] is String) {
        message = json['message'] as String;
      }
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
