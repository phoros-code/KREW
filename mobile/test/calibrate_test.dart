import 'dart:convert';

import 'package:everyday_buddy/screens/calibrate_screen.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Sprint 2.3c calibration UX: the threshold POST contract plus the
/// CalibrateScreen live/disabled states (mock transports only).
void main() {
  group('BuddyApi.setProximityThreshold', () {
    BuddyApi apiWith(MockClient client) =>
        BuddyApi(host: '192.168.1.10', token: 't', client: client);

    test('posts the threshold body and parses the 200', () async {
      String? seenMethod;
      String? seenPath;
      String? seenAuth;
      String? seenContentType;
      Map<String, dynamic>? seenBody;
      final api = apiWith(
        MockClient((http.BaseRequest req) async {
          seenMethod = req.method;
          seenPath = req.url.path;
          seenAuth = req.headers['Authorization'];
          seenContentType = req.headers['Content-Type'];
          if (req is http.Request) {
            seenBody = jsonDecode(req.body) as Map<String, dynamic>;
          }
          return http.Response(
            '{"mode": "lan_plus_bluetooth", "rssi_near_threshold": -65}',
            200,
          );
        }),
      );
      final ProximityConfig cfg = await api.setProximityThreshold(-65);
      expect(seenMethod, 'POST');
      expect(seenPath, '/proximity/threshold');
      expect(seenAuth, 'Bearer t');
      expect(seenContentType, contains('application/json'));
      expect(seenBody, <String, dynamic>{'rssi_near_threshold': -65});
      expect(cfg.mode, 'lan_plus_bluetooth');
      expect(cfg.rssiNearThreshold, -65);
      api.close();
    });

    test('rejects out-of-range values client-side without network',
        () async {
      bool hitNetwork = false;
      final api = apiWith(
        MockClient((_) async {
          hitNetwork = true;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        api.setProximityThreshold(-20),
        throwsA(
          isA<BuddyApiException>()
              .having((BuddyApiException e) => e.code, 'code', 'bad_request'),
        ),
      );
      expect(hitNetwork, isFalse);
      api.close();
    });

    test('non-200 surfaces the typed envelope', () async {
      final api = apiWith(
        MockClient((_) async => http.Response(
          '{"error": {"code": "forbidden", "message": "Requires near proximity"}}',
          403,
        )),
      );
      await expectLater(
        api.setProximityThreshold(-65),
        throwsA(
          isA<BuddyApiException>()
              .having((BuddyApiException e) => e.code, 'code', 'forbidden'),
        ),
      );
      api.close();
    });
  });

  group('CalibrateScreen', () {
    testWidgets('renders live RSSI and threshold', (
      WidgetTester tester,
    ) async {
      final ProximityService proximity = ProximityService();
      proximity.updateRssi(-55);
      final BuddyApi api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CalibrateScreen(
                api: api,
                proximity: proximity,
                onThresholdApplied: () async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Calibrate proximity'), findsOneWidget);
      expect(find.text('-55 dBm'), findsOneWidget);
      expect(find.text('Threshold -60 dBm'), findsOneWidget);
      expect(find.text('NEAR'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      final ElevatedButton button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Set threshold'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('Set threshold is disabled when unpaired', (
      WidgetTester tester,
    ) async {
      final ProximityService proximity = ProximityService();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CalibrateScreen(
                api: null,
                proximity: proximity,
                onThresholdApplied: () async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Calibrate proximity'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('Threshold -60 dBm'), findsOneWidget);
      final ElevatedButton button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Set threshold'),
      );
      expect(button.onPressed, isNull);
      expect(
        find.textContaining('Pair with the laptop first'),
        findsOneWidget,
      );
    });
  });
}
