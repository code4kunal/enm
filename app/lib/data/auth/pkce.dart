import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The one-time secrets an authorization-code sign-in is built on.
///
/// PKCE (RFC 7636) is what makes an authorization code safe to hand to a
/// browser: the code alone is useless without the verifier, which never leaves
/// this device. `state` and `nonce` are the other half — one proves the
/// redirect belongs to the sign-in we started, the other proves the token
/// belongs to that same request rather than being replayed from an older one.
class Pkce {
  const Pkce({
    required this.verifier,
    required this.challenge,
    required this.state,
    required this.nonce,
  });

  final String verifier;
  final String challenge;
  final String state;
  final String nonce;

  /// RFC 7636 §4.1: 43–128 characters from the unreserved set.
  static const int _verifierLength = 64;

  static const String _unreserved =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  factory Pkce.generate({Random? random}) {
    // Random.secure() or nothing — a predictable verifier defeats the whole
    // mechanism, and the default Random is seeded predictably.
    final rng = random ?? Random.secure();
    final verifier = _randomString(rng, _verifierLength);
    return Pkce(
      verifier: verifier,
      challenge: challengeFor(verifier),
      state: _randomString(rng, 32),
      nonce: _randomString(rng, 32),
    );
  }

  /// S256: base64url(sha256(verifier)), unpadded.
  static String challengeFor(String verifier) =>
      base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');

  static String _randomString(Random rng, int length) => String.fromCharCodes(
        Iterable<int>.generate(
          length,
          (_) => _unreserved.codeUnitAt(rng.nextInt(_unreserved.length)),
        ),
      );

  Map<String, String> toJson() => <String, String>{
        'verifier': verifier,
        'challenge': challenge,
        'state': state,
        'nonce': nonce,
      };

  static Pkce? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final verifier = json['verifier'] as String?;
    final challenge = json['challenge'] as String?;
    final state = json['state'] as String?;
    final nonce = json['nonce'] as String?;
    if (verifier == null || challenge == null || state == null || nonce == null) {
      return null;
    }
    return Pkce(
      verifier: verifier,
      challenge: challenge,
      state: state,
      nonce: nonce,
    );
  }
}

/// Reads the `nonce` claim out of an id_token without verifying it.
///
/// The server is what validates this token — signature, issuer, audience, the
/// lot. The client checks only the nonce, because the client is the party that
/// generated it and the server has no way to know what it was. Decoding
/// unverified claims for any other purpose would be a mistake.
String? nonceOf(String idToken) {
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final claims = jsonDecode(payload);
    if (claims is! Map<String, dynamic>) return null;
    return claims['nonce'] as String?;
  } on Object {
    return null;
  }
}
