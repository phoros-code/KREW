import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
