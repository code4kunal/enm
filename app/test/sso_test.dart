import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:transvolt_em/data/auth/ms_sso.dart';
import 'package:transvolt_em/data/auth/pkce.dart';

/// Builds an unsigned token shaped like an Entra id_token. Only the nonce
/// claim is read on this side — everything else is the server's to verify —
/// so an unsigned one is enough to exercise the client's half.
String idTokenWithNonce(String? nonce) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg(<String, dynamic>{'alg': 'RS256'})}.'
      '${seg(<String, dynamic>{if (nonce != null) 'nonce': nonce, 'sub': 'x'})}.'
      'not-a-real-signature';
}

void main() {
  group('PKCE', () {
    test('the verifier is long enough and uses only unreserved characters', () {
      // RFC 7636 §4.1. A verifier outside this set gets rejected by Entra, and
      // one that is too short weakens the exchange.
      final pkce = Pkce.generate();
      expect(pkce.verifier.length, inInclusiveRange(43, 128));
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(pkce.verifier), isTrue);
    });

    test('the challenge is the S256 of the verifier, unpadded', () {
      // The one vector in RFC 7636 appendix B.
      expect(
        Pkce.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
      expect(Pkce.challengeFor('abc'), isNot(contains('=')));
    });

    test('two sign-ins share no secrets', () {
      final a = Pkce.generate();
      final b = Pkce.generate();
      expect(a.verifier, isNot(b.verifier));
      expect(a.state, isNot(b.state));
      expect(a.nonce, isNot(b.nonce));
    });

    test('a seeded generator still produces a valid shape', () {
      // Only to prove the generator is injectable for tests; production always
      // takes Random.secure().
      final pkce = Pkce.generate(random: Random(1));
      expect(pkce.challenge, Pkce.challengeFor(pkce.verifier));
    });

    test('survives a round trip through storage', () {
      final pkce = Pkce.generate();
      final back = Pkce.fromJson(
        jsonDecode(jsonEncode(pkce.toJson())) as Map<String, dynamic>,
      );
      expect(back!.verifier, pkce.verifier);
      expect(back.state, pkce.state);
      expect(back.nonce, pkce.nonce);
    });

    test('a half-written pending record is treated as absent', () {
      expect(Pkce.fromJson(null), isNull);
      expect(Pkce.fromJson(<String, dynamic>{'verifier': 'only'}), isNull);
    });
  });

  group('reading the nonce back', () {
    test('finds the claim in a well-formed token', () {
      expect(nonceOf(idTokenWithNonce('n-123')), 'n-123');
    });

    test('a token without a nonce reads as null, not as a match', () {
      // Null must never compare equal to a stored nonce, or the replay check
      // passes for any token that simply omits the claim.
      expect(nonceOf(idTokenWithNonce(null)), isNull);
    });

    test('garbage does not throw', () {
      expect(nonceOf('not.a.token'), isNull);
      expect(nonceOf('one-segment'), isNull);
      expect(nonceOf(''), isNull);
    });
  });

  group('SsoConfig', () {
    test('reads what the server serves', () {
      final config = SsoConfig.fromJson(<String, dynamic>{
        'enabled': true,
        'tenant_id': 't',
        'client_id': 'c',
        'authority': 'https://login.microsoftonline.com/t',
        'scopes': <dynamic>['openid', 'profile', 'email'],
      });
      expect(config.enabled, isTrue);
      expect(config.clientId, 'c');
      expect(config.scopes, contains('openid'));
    });

    test('a deployment without SSO is off, not half-configured', () {
      final config = SsoConfig.fromJson(<String, dynamic>{'enabled': false});
      expect(config.enabled, isFalse);
      expect(config.usable, isFalse);
      expect(SsoConfig.off.usable, isFalse);
    });

    test('enabled but missing a client id is still not usable', () {
      // Better no button than a button that fails when tapped.
      final config = SsoConfig.fromJson(<String, dynamic>{
        'enabled': true,
        'authority': 'https://login.microsoftonline.com/t',
      });
      expect(config.usable, isFalse);
    });

    test('scopes fall back rather than arriving empty', () {
      final config = SsoConfig.fromJson(<String, dynamic>{
        'enabled': true,
        'scopes': <dynamic>[],
      });
      expect(config.scopes, contains('openid'));
    });
  });
}
