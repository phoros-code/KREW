import 'package:everyday_buddy/screens/preview_screen.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:everyday_buddy/widgets/mjpeg_player.dart';
import 'package:everyday_buddy/widgets/screen_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Widget tests for the Sprint 1 MJPEG player (designed states only — the
/// transport itself is covered by the BuddyApi mock-client tests).
void main() {
  testWidgets('shows the designed error state on a 403 grant check',
      (WidgetTester tester) async {
    final MockClient client = MockClient(
      (_) async => http.Response(
        '{"error": {"code": "consent_required", "message": "needs approval"}}',
        403,
      ),
    );
    bool retried = false;
    bool stopped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MjpegPlayer(
            streamUrl: 'https://192.168.1.10:8443/screen?consent_id=abc',
            headers: const <String, String>{'Authorization': 'Bearer t'},
            client: client,
            onRetry: () => retried = true,
            onStop: () => stopped = true,
          ),
        ),
      ),
    );

    // Mounting shows the loading state first (no auto-start violation: the
    // parent only mounts this after taps + laptop approval). pumpWidget
    // builds frame one synchronously; the mocked transport resolves after,
    // so the loading tree is visible here with no extra pump.
    expect(find.text('Starting live preview…'), findsOneWidget);

    // The 403 drains to the designed error state — never raw JSON.
    await tester.pumpAndSettle();
    expect(find.text('Stream dropped — retry'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('consent_required'), findsNothing);
    expect(find.text('Starting live preview…'), findsNothing);

    // Retry + Stop route through the parent callbacks.
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
    await tester.tap(find.text('Stop preview'));
    expect(stopped, isTrue);
  });

  testWidgets('shows the designed error state on transport failure',
      (WidgetTester tester) async {
    final MockClient client = MockClient(
      (_) async => throw http.ClientException('connection reset'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MjpegPlayer(
            streamUrl: 'https://192.168.1.10:8443/screen?consent_id=abc',
            headers: const <String, String>{'Authorization': 'Bearer t'},
            client: client,
            onRetry: () {},
            onStop: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stream dropped — retry'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('ScreenPreview shows the honest throttling copy on a 429 probe',
      (WidgetTester tester) async {
    final MockClient client = MockClient((http.BaseRequest req) async {
      if (req.url.path == '/screen/consent') {
        return http.Response(
          '{"consent_id": "abc", "status": "pending"}',
          200,
        );
      }
      return http.Response(
        '{"error": {"code": "rate_limited", "message": "slow down"}}',
        429,
      );
    });
    final BuddyApi api = BuddyApi(
      host: '192.168.1.10',
      token: 't',
      client: client,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenPreview(
            api: api,
            proximity: ProximityMode.near,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Request preview'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for laptop approval'), findsOneWidget);

    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    // Honest copy (Task A) — never the unreachable "No route" text, never
    // the raw envelope code.
    expect(
      find.text(
        'The laptop is throttling requests — wait a few seconds, then retry.',
      ),
      findsOneWidget,
    );
    expect(find.text('rate_limited'), findsNothing);
    expect(
      find.text('No route to the laptop — check the IP and Wi-Fi, then retry.'),
      findsNothing,
    );

    // The grant is kept through throttling: Retry re-probes (still 429 →
    // same copy) instead of dropping back to needsConsent.
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The laptop is throttling requests — wait a few seconds, then retry.',
      ),
      findsOneWidget,
    );
    expect(find.text('Request preview'), findsNothing);
    api.close();
  });

  testWidgets('toggling source resets consent state and drops the old grant',
      (WidgetTester tester) async {
    final List<String> calls = <String>[];
    final MockClient client = MockClient((http.BaseRequest req) async {
      calls.add('${req.method} ${req.url.path}?${req.url.query}');
      if (req.url.path == '/screen/consent') {
        return http.Response(
          '{"consent_id": "screen-grant", "status": "pending"}',
          200,
        );
      }
      return http.Response(
        '{"error": {"code": "consent_required", "message": "pending"}}',
        403,
      );
    });
    final BuddyApi api = BuddyApi(
      host: '192.168.1.10',
      token: 't',
      client: client,
    );
    Widget frame(PreviewSource source) => MaterialApp(
          home: Scaffold(
            body: ScreenPreview(
              api: api,
              proximity: ProximityMode.near,
              source: source,
            ),
          ),
        );

    await tester.pumpWidget(frame(PreviewSource.screen));
    expect(find.text('Laptop screen'), findsOneWidget);
    await tester.tap(find.text('Request preview'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for laptop approval'), findsOneWidget);

    // Toggle to webcam: back to needsConsent with webcam copy — the screen
    // grant is dropped, never probed against /webcam.
    await tester.pumpWidget(frame(PreviewSource.webcam));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for laptop approval'), findsNothing);
    expect(find.text('Laptop webcam'), findsOneWidget);
    expect(find.text('Request preview'), findsOneWidget);
    expect(
      find.text(
        'This shows the laptop camera feed — everything the camera sees, streamed live. Frames are never saved.',
      ),
      findsOneWidget,
    );
    expect(
      calls
          .where((String c) => c.contains('screen-grant') && c.contains('/webcam'))
          .toList(),
      isEmpty,
    );
    api.close();
  });

  testWidgets('webcam source requests and probes /webcam, never /screen',
      (WidgetTester tester) async {
    final List<String> paths = <String>[];
    final MockClient client = MockClient((http.BaseRequest req) async {
      paths.add(req.url.path);
      if (req.url.path == '/webcam/consent') {
        return http.Response(
          '{"consent_id": "cam1", "status": "pending"}',
          200,
        );
      }
      return http.Response(
        '{"error": {"code": "consent_required", "message": "pending"}}',
        403,
      );
    });
    final BuddyApi api = BuddyApi(
      host: '192.168.1.10',
      token: 't',
      client: client,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenPreview(
            api: api,
            proximity: ProximityMode.near,
            source: PreviewSource.webcam,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Request preview'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for laptop approval'), findsOneWidget);

    // Still pending → stays waiting, no error.
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for laptop approval'), findsOneWidget);
    expect(paths, contains('/webcam/consent'));
    expect(paths.any((String p) => p.contains('/screen')), isFalse);
    api.close();
  });

  testWidgets('PreviewScreen SegmentedButton switches the preview source',
      (WidgetTester tester) async {
    final BuddyApi api = BuddyApi(
      host: '192.168.1.10',
      token: 't',
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewScreen(
            api: api,
            proximity: ProximityMode.near,
          ),
        ),
      ),
    );
    // Header + preview card both read "Laptop screen".
    expect(find.text('Laptop screen'), findsNWidgets(2));

    await tester.tap(find.text('Webcam'));
    await tester.pumpAndSettle();
    expect(find.text('Laptop webcam'), findsNWidgets(2));
    expect(find.text('Laptop screen'), findsNothing);

    await tester.tap(find.text('Screen'));
    await tester.pumpAndSettle();
    expect(find.text('Laptop screen'), findsNWidgets(2));
    api.close();
  });
}
