import 'dart:io';

import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('BuddyApiException.fromRaw', () {
    test('parses the API.md 401 envelope', () {
      final err = BuddyApiException.fromRaw(
        401,
        '{"error": {"code": "unauthorized", "message": "Invalid or expired token"}}',
      );
      expect(err.code, 'unauthorized');
      expect(err.message, 'Invalid or expired token');
      expect(err.statusCode, 401);
    });

    test('parses the 401 token_expired envelope', () {
      final err = BuddyApiException.fromRaw(
        401,
        '{"error": {"code": "token_expired", "message": "Pairing token exceeded its absolute age"}}',
      );
      expect(err.code, 'token_expired');
      expect(err.statusCode, 401);
    });

    test('parses the 403 proximity envelope', () {
      final err = BuddyApiException.fromRaw(
        403,
        '{"error": {"code": "forbidden", "message": "Requires near proximity"}}',
      );
      expect(err.code, 'forbidden');
    });

    test('parses the 501 screen envelope', () {
      final err = BuddyApiException.fromRaw(
        501,
        '{"error": {"code": "not_implemented", "message": "Screen preview ships in Phase 3"}}',
      );
      expect(err.code, 'not_implemented');
    });

    test('falls back gracefully on non-JSON bodies', () {
      final err = BuddyApiException.fromRaw(500, '<html>proxy exploded</html>');
      expect(err.code, 'request_failed');
      expect(err.message, isNotEmpty);
    });
  });

  group('BuddyApi.splitHostPort', () {
    test('bare IP defaults to 8443', () {
      final parsed = BuddyApi.splitHostPort('192.168.1.10');
      expect(parsed.host, '192.168.1.10');
      expect(parsed.port, 8443);
    });

    test('explicit port is honored', () {
      final parsed = BuddyApi.splitHostPort('192.168.1.10:9443');
      expect(parsed.host, '192.168.1.10');
      expect(parsed.port, 9443);
    });

    test('pasted URLs are stripped to host and port', () {
      final parsed = BuddyApi.splitHostPort('https://192.168.1.10:8443/');
      expect(parsed.host, '192.168.1.10');
      expect(parsed.port, 8443);
    });

    test('empty input yields an empty host', () {
      expect(BuddyApi.splitHostPort('  ').host, isEmpty);
    });
  });

  group('ProximityService (fail closed)', () {
    test('defaults to FAR', () {
      final proximity = ProximityService();
      expect(proximity.mode, ProximityMode.far);
      expect(proximity.commandsAllowed, isFalse);
    });

    test('null RSSI stays FAR', () {
      final proximity = ProximityService();
      proximity.markNear();
      proximity.updateRssi(null);
      expect(proximity.mode, ProximityMode.far);
    });

    test('weak RSSI is FAR, strong RSSI is NEAR', () {
      final proximity = ProximityService();
      proximity.updateRssi(-80, threshold: -60);
      expect(proximity.mode, ProximityMode.far);
      proximity.updateRssi(-40, threshold: -60);
      expect(proximity.mode, ProximityMode.near);
    });

    test('commands need NEAR plus ONLINE', () {
      final proximity = ProximityService();
      proximity.markNear();
      proximity.setOffline();
      expect(proximity.commandsAllowed, isFalse);
      proximity.setOnline();
      expect(proximity.commandsAllowed, isTrue);
      proximity.markFar();
      expect(proximity.commandsAllowed, isFalse);
    });

    test('server threshold replaces the compiled-in default', () {
      final proximity = ProximityService();
      expect(proximity.rssiNearThreshold, -60);
      proximity.setThreshold(-70);
      expect(proximity.rssiNearThreshold, -70);
      proximity.updateRssi(-65); // between old and new limit
      expect(proximity.mode, ProximityMode.near);
    });

    test('last RSSI is remembered for the decorative X-RSSI header', () {
      final proximity = ProximityService();
      expect(proximity.lastRssi, isNull);
      proximity.updateRssi(-55);
      expect(proximity.lastRssi, -55);
      proximity.updateRssi(null);
      expect(proximity.lastRssi, isNull);
    });
  });

  group('BuddyApi.fetchProximityConfig', () {
    BuddyApi apiWith(MockClient client) =>
        BuddyApi(host: '192.168.1.10', token: 't', client: client);

    test('parses mode + threshold on 200', () async {
      final api = apiWith(
        MockClient((_) async => http.Response(
          '{"mode": "lan_plus_bluetooth", "rssi_near_threshold": -65}',
          200,
        )),
      );
      final cfg = await api.fetchProximityConfig();
      expect(cfg.mode, 'lan_plus_bluetooth');
      expect(cfg.rssiNearThreshold, -65);
      expect(cfg.usesBluetooth, isTrue);
      api.close();
    });

    test('lan_only mode reports no bluetooth', () async {
      final api = apiWith(
        MockClient((_) async => http.Response(
          '{"mode": "lan_only", "rssi_near_threshold": -60}',
          200,
        )),
      );
      final cfg = await api.fetchProximityConfig();
      expect(cfg.usesBluetooth, isFalse);
      api.close();
    });

    test('401 surfaces as unauthorized (re-pair prompt)', () async {
      final api = apiWith(
        MockClient((_) async => http.Response(
          '{"error": {"code": "unauthorized", "message": "nope"}}}',
          401,
        )),
      );
      expect(
        api.fetchProximityConfig(),
        throwsA(isA<BuddyApiException>().having((e) => e.code, 'code', 'unauthorized')),
      );
      api.close();
    });

    test('garbage body becomes bad_response, never a crash', () async {
      final api = apiWith(
        MockClient((_) async => http.Response('not-json', 200)),
      );
      expect(
        api.fetchProximityConfig(),
        throwsA(isA<BuddyApiException>().having((e) => e.code, 'code', 'bad_response')),
      );
      api.close();
    });
  });

  group('BuddyApi certificate pinning', () {
    test('normalizeFingerprint strips separators and case', () {
      expect(BuddyApi.normalizeFingerprint('6C:9C:AE AC'), '6c9caeac');
      expect(
        BuddyApi.normalizeFingerprint('  6c9caeacacc945e89aBAB  '),
        '6c9caeacacc945e89abab',
      );
    });

    test('isValidFingerprint accepts 64 hex in any pasted format', () {
      const bare =
          '6c9caeacacc945e89ababdaeb5c0e2d2c6a052b97965535fdd73ec6435982fbc';
      expect(BuddyApi.isValidFingerprint(bare), isTrue);
      expect(
        BuddyApi.isValidFingerprint(
          '6C:9C:AE:AC:AC:C9:45:E8:9A:BA:BD:AE:B5:C0:E2:D2:C6:A0:52:B9:79:65:53:5F:DD:73:EC:64:35:98:2F:BC',
        ),
        isTrue,
      );
    });

    test('isValidFingerprint rejects short, empty, and non-hex', () {
      expect(BuddyApi.isValidFingerprint(''), isFalse);
      expect(BuddyApi.isValidFingerprint('abc123'), isFalse);
      expect(BuddyApi.isValidFingerprint('z' * 64), isFalse);
      expect(BuddyApi.isValidFingerprint('00' * 31 + '0'), isFalse);
    });

    test('fingerprintMatchesDer verifies SHA-256 (empty-input vector)', () {
      // SHA-256("") = e3b0c4…855 — a fixed public test vector, no cert needed.
      const emptySha256 =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      expect(BuddyApi.fingerprintMatchesDer(<int>[], emptySha256), isTrue);
      expect(
        BuddyApi.fingerprintMatchesDer(
          <int>[],
          emptySha256.toUpperCase().replaceAllMapped(
            RegExp(r'..'),
            (m) => '${m[0]}:',
          ),
        ),
        isTrue,
      );
      expect(BuddyApi.fingerprintMatchesDer(<int>[0], emptySha256), isFalse);
      expect(BuddyApi.fingerprintMatchesDer(<int>[], '00' * 32), isFalse);
    });
  });

  group('BuddyApi transport error mapping (no silent failures)', () {
    BuddyApi apiThrowing(Object err) => BuddyApi(
      host: '192.168.1.10',
      token: 't',
      client: MockClient((_) async => throw err),
    );

    test('HandshakeException becomes the cert-specific unreachable', () {
      final api = apiThrowing(const HandshakeException('handshake failure'));
      expect(
        api.checkHealth(),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'unreachable')
              .having((e) => e.message, 'message', contains('fingerprint')),
        ),
      );
      api.close();
    });

    test('TlsException becomes the cert-specific unreachable', () {
      final api = apiThrowing(const TlsException('bad cert'));
      expect(
        api.checkHealth(),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'unreachable')
              .having((e) => e.message, 'message', contains('fingerprint')),
        ),
      );
      api.close();
    });

    test('SocketException becomes the route unreachable', () {
      final api = apiThrowing(const SocketException('refused'));
      expect(
        api.checkHealth(),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'unreachable')
              .having((e) => e.message, 'message', contains('Wi-Fi')),
        ),
      );
      api.close();
    });
  });

  group('BuddyApi screen consent flow', () {
    BuddyApi apiWith(MockClient client) =>
        BuddyApi(host: '192.168.1.10', token: 't', client: client);

    test('requestScreenConsent returns the pending id', () async {
      String? seenPath;
      final api = apiWith(
        MockClient((http.BaseRequest req) async {
          seenPath = req.url.path;
          return http.Response('{"consent_id": "abc123", "status": "pending"}', 200);
        }),
      );
      expect(await api.requestScreenConsent(), 'abc123');
      expect(seenPath, '/screen/consent');
      api.close();
    });

    test('consent request 403 surfaces as forbidden', () async {
      final api = apiWith(
        MockClient((_) async => http.Response(
          '{"error": {"code": "forbidden", "message": "near only"}}',
          403,
        )),
      );
      expect(
        api.requestScreenConsent(),
        throwsA(isA<BuddyApiException>().having((e) => e.code, 'code', 'forbidden')),
      );
      api.close();
    });

    test('checkScreen sends the grant and maps pending to consentRequired', () async {
      String? seenQuery;
      final api = apiWith(
        MockClient((http.BaseRequest req) async {
          seenQuery = req.url.query;
          return http.Response(
            '{"error": {"code": "consent_required", "message": "needs approval"}}',
            403,
          );
        }),
      );
      expect(
        await api.checkScreen(consentId: 'abc123'),
        ScreenStatus.consentRequired,
      );
      expect(seenQuery, contains('consent_id=abc123'));
      api.close();
    });

    test('checkScreen maps denied grants to consentDenied', () async {
      final api = apiWith(
        MockClient((_) async => http.Response(
          '{"error": {"code": "consent_denied", "message": "denied"}}',
          403,
        )),
      );
      expect(
        await api.checkScreen(consentId: 'dead'),
        ScreenStatus.consentDenied,
      );
      api.close();
    });

    test('checkScreen without a grant probes the bare endpoint', () async {
      String? seenQuery;
      final api = apiWith(
        MockClient((http.BaseRequest req) async {
          seenQuery = req.url.query;
          return http.Response('jpeg-bytes', 200);
        }),
      );
      expect(await api.checkScreen(), ScreenStatus.available);
      expect(seenQuery, isEmpty);
      api.close();
    });
  });

  group('BuddyApi screen revoke + stream URL (Sprint 1)', () {
    BuddyApi apiWith(MockClient client) =>
        BuddyApi(host: '192.168.1.10', token: 't', client: client);

    test('revokeScreenConsent posts the revoke path and returns on 200',
        () async {
      String? seenPath;
      String? seenMethod;
      final api = apiWith(
        MockClient((http.BaseRequest req) async {
          seenPath = req.url.path;
          seenMethod = req.method;
          return http.Response(
            '{"consent_id": "abc", "status": "revoked"}',
            200,
          );
        }),
      );
      await api.revokeScreenConsent('abc');
      expect(seenMethod, 'POST');
      expect(seenPath, '/screen/consent/abc/revoke');
      api.close();
    });

    test('revokeScreenConsent throws the typed envelope on 404', () async {
      final api = apiWith(
        MockClient((_) async => http.Response(
          '{"error": {"code": "not_found", "message": "Unknown consent"}}',
          404,
        )),
      );
      expect(
        api.revokeScreenConsent('gone'),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'not_found')
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
      api.close();
    });

    test('revokeScreenConsent maps transport failure to unreachable', () {
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => throw const SocketException('refused')),
      );
      expect(
        api.revokeScreenConsent('abc'),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'unreachable'),
        ),
      );
      api.close();
    });

    test('revokeScreenConsent rejects an empty grant without network',
        () async {
      bool hitNetwork = false;
      final api = apiWith(
        MockClient((_) async {
          hitNetwork = true;
          return http.Response('{}', 200);
        }),
      );
      expect(
        api.revokeScreenConsent(''),
        throwsA(
          isA<BuddyApiException>()
              .having((e) => e.code, 'code', 'bad_request'),
        ),
      );
      expect(hitNetwork, isFalse);
      api.close();
    });

    test('screenStreamUrl carries the grant as consent_id query', () {
      final api = apiWith(MockClient((_) async => http.Response('', 200)));
      final Uri url = api.screenStreamUrl('abc123');
      expect(url.scheme, 'https');
      expect(url.path, '/screen');
      expect(url.queryParameters['consent_id'], 'abc123');
      api.close();
    });

    test('authHeaders carries the bearer token the player sends', () async {
      String? seenAuth;
      final api = apiWith(
        MockClient((http.BaseRequest req) async {
          seenAuth = req.headers['Authorization'];
          return http.Response(
            '{"consent_id": "x", "status": "pending"}',
            200,
          );
        }),
      );
      expect(api.authHeaders['Authorization'], 'Bearer t');
      await api.requestScreenConsent();
      expect(seenAuth, 'Bearer t');
      api.close();
    });
  });
}
