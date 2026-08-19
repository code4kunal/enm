import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Thin HTTP client that points at the SiteOps backend and re-uses the
/// access token that the user obtained during login.
class SiteOpsClient {
  SiteOpsClient() : selectedSiteId = null;
  String? selectedSiteId;

  static const String _baseUrl = String.fromEnvironment(
    'SITEOPS_BASE_URL',
    defaultValue: 'https://dev-siteops-platform.transvolt.org/api/v1',
  );

  Future<String?> _accessToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('transvolt.access_token');
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _headers(String? token) => <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _uri(String path, {Map<String, String>? query}) {
    final cleaned = path.startsWith('/') ? path : '/$path';
    var finalQuery = query;
    if (selectedSiteId != null && selectedSiteId!.isNotEmpty) {
      if (query == null || !query.containsKey('site_id')) {
        finalQuery = <String, String>{
          ...?query,
          'site_id': selectedSiteId!,
        };
      }
    }
    final uri = Uri.parse('$_baseUrl$cleaned');
    if (finalQuery == null || finalQuery.isEmpty) return uri;
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      ...finalQuery,
    });
  }

  Future<dynamic> get(String path, {Map<String, String>? query}) async {
    final token = await _accessToken();
    final response = await http.get(_uri(path, query: query), headers: _headers(token));
    return _decode(response);
  }

  Future<dynamic> post(String path, {Object? body}) async {
    final token = await _accessToken();
    final response = await http.post(
      _uri(path),
      headers: _headers(token),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> put(String path, {Object? body}) async {
    final token = await _accessToken();
    final response = await http.put(
      _uri(path),
      headers: _headers(token),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> patch(String path, {Object? body}) async {
    final token = await _accessToken();
    final response = await http.patch(
      _uri(path),
      headers: _headers(token),
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Future<dynamic> delete(String path) async {
    final token = await _accessToken();
    final response = await http.delete(_uri(path), headers: _headers(token));
    return _decode(response);
  }

  Future<dynamic> multipart(
    String method,
    String path,
    Map<String, dynamic> data,
  ) async {
    final token = await _accessToken();
    final boundary = 'Boundary-${DateTime.now().millisecondsSinceEpoch}';
    final List<int> bodyBytes = [];
    
    data.forEach((key, value) {
      if (value == null) return;
      if (value is List) {
        for (final item in value) {
          bodyBytes.addAll(utf8.encode('--$boundary\r\n'));
          bodyBytes.addAll(utf8.encode('Content-Disposition: form-data; name="$key"\r\n\r\n'));
          bodyBytes.addAll(utf8.encode('$item\r\n'));
        }
      } else {
        bodyBytes.addAll(utf8.encode('--$boundary\r\n'));
        bodyBytes.addAll(utf8.encode('Content-Disposition: form-data; name="$key"\r\n\r\n'));
        bodyBytes.addAll(utf8.encode('$value\r\n'));
      }
    });
    bodyBytes.addAll(utf8.encode('--$boundary--\r\n'));

    final response = await http.Response.fromStream(await http.Client().send(
      http.Request(method, _uri(path))
        ..headers.addAll({
          'Content-Type': 'multipart/form-data; boundary=$boundary',
          'Accept': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        })
        ..bodyBytes = bodyBytes,
    ));
    
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final status = response.statusCode;
    final text = response.body;

    if (status == 204 || text.isEmpty) {
      if (status >= 400) throw Exception('Request failed ($status)');
      return null;
    }

    dynamic json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      if (status >= 400) throw Exception('Request failed ($status)');
      return null;
    }

    if (status < 400) return json;

    String message = 'Request failed ($status)';
    if (json is Map<String, dynamic>) {
      final error = json['error'];
      if (error is Map<String, dynamic>) {
        message = error['message'] as String? ?? message;
      } else if (json['message'] != null) {
        message = json['message'] as String? ?? message;
      } else if (json['detail'] != null) {
        final detail = json['detail'];
        message = detail is String ? detail : jsonEncode(detail);
      }
    }
    throw Exception(message);
  }
}

final siteOpsClient = SiteOpsClient();

