import 'package:everyday_buddy/widgets/mjpeg_player.dart';
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
}
