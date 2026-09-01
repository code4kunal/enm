import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api_exception.dart';
import 'browser.dart';
import 'pkce.dart';

/// What this deployment offers for Microsoft sign-in.
class SsoConfig {
  const SsoConfig({
    this.enabled = false,
    this.tenantId,
    this.clientId,
    this.authority,
    this.scopes = const <String>['openid', 'profile', 'email'],
  });

  final bool enabled;
  final String? tenantId;
  final String? clientId;
  final String? authority;
  final List<String> scopes;

  static const SsoConfig off = SsoConfig();

  /// Usable only when the server said yes *and* we are somewhere with a
  /// browser to redirect.
  bool get usable => enabled && clientId != null && authority != null && isBrowser;

  factory SsoConfig.fromJson(Map<String, dynamic> json) => SsoConfig(
        enabled: json['enabled'] as bool? ?? false,
        tenantId: json['tenant_id'] as String?,
        clientId: json['client_id'] as String?,
        authority: json['authority'] as String?,
        scopes: <String>[
          for (final s in (json['scopes'] as List<dynamic>? ?? <dynamic>[]))
            s as String,
        ].isEmpty
            ? const <String>['openid', 'profile', 'email']
            : <String>[
                for (final s in (json['scopes'] as List<dynamic>)) s as String,
              ],
      );
}

/// Microsoft Entra ID sign-in: authorization code with PKCE.
///
/// The browser goes to Microsoft, comes back with a code, and this exchanges
/// it for an `id_token` which the API verifies against Entra's JWKS. No client
/// secret is involved and none can be — a secret shipped to a browser is not a
/// secret. PKCE is what stands in for it.
///
/// Split into [begin] and [complete] because the redirect leaves the app
/// entirely: the two halves run in different page loads, which is why the
/// one-time values are persisted rather than held in memory.
class MicrosoftSignIn {
  MicrosoftSignIn(this._api);

  final ApiClient _api;

  static const String _pendingKey = 'transvolt.sso_pending';

  /// Asks the server whether SSO is on. Never throws: a sign-in screen that
  /// cannot reach the server should still offer the password form.
  Future<SsoConfig> config() async {
    try {
      final json = await _api.get('/auth/sso/config');
      return SsoConfig.fromJson(json as Map<String, dynamic>);
    } on Object {
      return SsoConfig.off;
    }
  }

  /// Sends the browser to Microsoft. Does not return — the page is replaced.
  Future<void> begin(SsoConfig config) async {
    if (!config.usable) {
      throw const ApiException('Microsoft sign-in is not available here.');
    }
    final pkce = Pkce.generate();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingKey, jsonEncode(pkce.toJson()));

    final url = Uri.parse('${config.authority}/oauth2/v2.0/authorize').replace(
      queryParameters: <String, String>{
        'client_id': config.clientId!,
        'response_type': 'code',
        'redirect_uri': redirectUri().toString(),
        'response_mode': 'query',
        'scope': config.scopes.join(' '),
        'state': pkce.state,
        'nonce': pkce.nonce,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
      },
    );
    redirectTo(url);
  }

  /// True when this page load is Entra sending the browser back.
  bool get isReturning {
    if (!isBrowser) return false;
    final query = currentUri().queryParameters;
    return query.containsKey('code') || query.containsKey('error');
  }

  /// Finishes a sign-in that [begin] started, returning the E&M session the
  /// server minted. Null when this page load is not a return from Entra.
  ///
  /// Always clears the pending secrets and the address bar, including on
  /// failure — a half-finished attempt must not be resumable.
  ///
  /// The code is redeemed server-side (`POST /auth/sso/exchange`), not by
  /// this client directly against Microsoft: the app registration's redirect
  /// URI is typed "Web", and Azure blocks a browser from redeeming a code
  /// itself for that platform type (AADSTS9002326). E&M holds the client
  /// secret this exchange needs; the browser never sees it.
  Future<Map<String, dynamic>?> complete(SsoConfig config) async {
    if (!isReturning) return null;
    final query = currentUri().queryParameters;
    final prefs = await SharedPreferences.getInstance();
    final pending = Pkce.fromJson(
      jsonDecode(prefs.getString(_pendingKey) ?? 'null') as Map<String, dynamic>?,
    );
    await prefs.remove(_pendingKey);
    clearQuery();

    if (query['error'] != null) {
      throw ApiException(
        query['error_description'] ?? 'Microsoft sign-in was cancelled.',
      );
    }
    if (pending == null) {
      throw const ApiException(
        'That sign-in did not start here. Try signing in again.',
      );
    }
    // The state check is the whole defence against someone else's code being
    // fed to this app.
    if (query['state'] != pending.state) {
      throw const ApiException('Microsoft sign-in could not be verified.');
    }

    return await _api.post('/auth/sso/exchange', body: <String, dynamic>{
      'code': query['code']!,
      'redirect_uri': redirectUri().toString(),
      'code_verifier': pending.verifier,
    }) as Map<String, dynamic>;
  }
}

/// Where Entra sends the browser back: the app's own origin and path, with no
/// query and no fragment. This exact value has to be listed as a
/// single-page-application redirect URI on the app registration.
Uri redirectUri() {
  final here = currentUri();
  return Uri(
    scheme: here.scheme,
    host: here.host,
    port: here.hasPort ? here.port : null,
    path: here.path,
  );
}
