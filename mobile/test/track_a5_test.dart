import 'dart:async';

import 'package:everyday_buddy/app.dart';
import 'package:everyday_buddy/models/task_item.dart';
import 'package:everyday_buddy/screens/calibrate_screen.dart';
import 'package:everyday_buddy/screens/chat_screen.dart';
import 'package:everyday_buddy/screens/task_list_screen.dart';
import 'package:everyday_buddy/services/ble_proximity.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:everyday_buddy/services/secure_store.dart';
import 'package:everyday_buddy/widgets/mjpeg_player.dart';
import 'package:everyday_buddy/widgets/screen_preview.dart';
import 'package:everyday_buddy/widgets/status_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Track A5 regression tests — one per fix. Mock transports only; DESIGN.md
/// tokens untouched (no color/font/radius assertions beyond "renders").
///
/// Existing suites stay green: these tests only ADD coverage for the new
/// behavior (synthetic connected frame, backoff steps, revoke-on-toggle,
/// dead-grant retry, boot retry, host gate, cause surfacing).

/// SecureStore that fails every read — the locked-keystore path.
class _ThrowingStore extends SecureStore {
  _ThrowingStore() : super();

  @override
  Future<PairingInfo?> readPairing() async =>
      throw Exception('keystore locked');
}

/// Hanging MJPEG transport: 200 with a stream that stays open but silent.
class _HangingClient extends http.BaseClient {
  final StreamController<List<int>> controller =
      StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(controller.stream, 200);
}

/// Deferred MJPEG transport: completes the 200 only when the test says so.
class _DeferredClient extends http.BaseClient {
  final Completer<http.StreamedResponse> gate =
      Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      gate.future;
}

/// Scaffold frame for widget tests. No extra scroll view: ConsoleColumn
/// screens (chat/tasks/calibrate) already own their scroll region + bottom
/// bar, and an outer scroll would unbound their Expanded.
Widget _frame(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() {
    // No font fetching in tests — fall back to the platform default.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('A5.1 fresh-pair: 200 means connected, bar decoupled from events', () {
    test('watchEvents yields a synthetic connected frame first', () async {
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient(
          (_) async => http.Response(
            'event: task_started\ndata: {"task_id": "ab12cd", "text": "hi"}\n\n',
            200,
          ),
        ),
      );
      addTearDown(api.close);
      int activities = 0;
      final events = await api
          .watchEvents(onActivity: () => activities++)
          .toList();
      expect(events.first.type, 'connected');
      expect(events.length, 2);
      expect(events[1].type, 'task_started');
      expect(activities, greaterThanOrEqualTo(1));
    });

    test('comment heartbeats count as activity but yield no frame', () async {
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => http.Response(':ping\n\n', 200)),
      );
      addTearDown(api.close);
      int activities = 0;
      final events = await api
          .watchEvents(onActivity: () => activities++)
          .toList();
      expect(events.map((e) => e.type), <String>['connected']);
      expect(activities, greaterThanOrEqualTo(1));
    });

    testWidgets('fresh pair enables the bar with an empty log', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService()
        ..markNear()
        ..setOnline();
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: api,
            events: const [],
            proximity: proximity,
            onSend: (_) async {},
            streamError: null,
            streamConnected: true,
            onRetryStream: () {},
          ),
        ),
      );
      // Enabled bar, empty-log copy — never "Connecting…" on an open stream.
      final send = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Send'),
      );
      expect(send.onPressed, isNotNull);
      expect(find.text('Connecting…'), findsNothing);
      expect(find.text('Connecting to the laptop…'), findsNothing);
      expect(find.text('No commands yet'), findsOneWidget);
    });
  });

  group('A5.2 header: 56px box, no clip at 320dp + 1.2 scale', () {
    testWidgets('pills render without overflow', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.2),
          ),
          child: MaterialApp(
            home: Scaffold(
              appBar: StatusHeader(
                proximity: ProximityMode.far,
                connection: BuddyConnection.unknown,
                runningCount: 12,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('FAR'), findsOneWidget);
      expect(find.text('CONNECTING'), findsOneWidget);
      expect(find.text('12 RUNNING'), findsOneWidget);
    });
  });

  group('A5.3 mjpeg: stream-end state + stall watchdog', () {
    testWidgets('clean close shows the preview-ended state', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(
          MjpegPlayer(
            streamUrl: 'https://192.168.1.10:8443/screen?consent_id=abc',
            headers: const <String, String>{'Authorization': 'Bearer t'},
            client: MockClient((_) async => http.Response('', 200)),
            onRetry: () {},
            onStop: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Preview ended'), findsOneWidget);
      expect(find.text('Stream dropped — retry'), findsNothing);
    });

    testWidgets('bytes-idle past the stall budget ends the preview', (
      WidgetTester tester,
    ) async {
      final hanging = _HangingClient();
      addTearDown(() async {
        if (!hanging.controller.isClosed) await hanging.controller.close();
      });
      await tester.pumpWidget(
        _frame(
          MjpegPlayer(
            streamUrl: 'https://192.168.1.10:8443/screen?consent_id=abc',
            headers: const <String, String>{'Authorization': 'Bearer t'},
            client: hanging,
            onRetry: () {},
            onStop: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Starting live preview…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Preview ended'), findsOneWidget);
    });

    testWidgets('A5.11 unmount-during-connect drops the response cleanly', (
      WidgetTester tester,
    ) async {
      final deferred = _DeferredClient();
      final open = StreamController<List<int>>();
      addTearDown(() async {
        if (!open.isClosed) await open.close();
      });
      await tester.pumpWidget(
        _frame(
          MjpegPlayer(
            streamUrl: 'https://192.168.1.10:8443/screen?consent_id=abc',
            headers: const <String, String>{'Authorization': 'Bearer t'},
            client: deferred,
            onRetry: () {},
            onStop: () {},
          ),
        ),
      );
      // Unmount while the connect is still in flight…
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      // …then the 200 lands on a dead widget: cancelled, never listened.
      deferred.gate.complete(http.StreamedResponse(open.stream, 200));
      await tester.pump(const Duration(seconds: 11));
      expect(tester.takeException(), isNull);
    });
  });

  group('A5.4 screen_preview: revoke the OLD grant on toggle + dispose', () {
    MockClient consentClient(List<String> calls) => MockClient((
      http.BaseRequest req,
    ) async {
      calls.add('${req.method} ${req.url.path}?${req.url.query}');
      if (req.url.path == '/screen/consent') {
        return http.Response(
          '{"consent_id": "screen-grant", "status": "pending"}',
          200,
        );
      }
      if (req.url.path.endsWith('/revoke')) {
        return http.Response('{"status": "revoked"}', 200);
      }
      return http.Response(
        '{"error": {"code": "consent_required", "message": "pending"}}',
        403,
      );
    });

    Future<void> toAwaiting(WidgetTester tester, BuddyApi api) async {
      await tester.pumpWidget(
        _frame(
          ScreenPreview(api: api, proximity: ProximityMode.near),
        ),
      );
      await tester.tap(find.text('Request preview'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for laptop approval'), findsOneWidget);
    }

    testWidgets('source toggle revokes the old-scope grant', (
      WidgetTester tester,
    ) async {
      final calls = <String>[];
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: consentClient(calls),
      );
      addTearDown(api.close);
      await toAwaiting(tester, api);
      // Same element, new source → didUpdateWidget revokes the old grant.
      await tester.pumpWidget(
        _frame(
          ScreenPreview(
            api: api,
            proximity: ProximityMode.near,
            source: PreviewSource.webcam,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        calls,
        contains('POST /screen/consent/screen-grant/revoke?'),
      );
      expect(find.text('Request preview'), findsOneWidget);
    });

    testWidgets('dispose revokes the live grant best-effort', (
      WidgetTester tester,
    ) async {
      final calls = <String>[];
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: consentClient(calls),
      );
      addTearDown(api.close);
      await toAwaiting(tester, api);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();
      expect(
        calls,
        contains('POST /screen/consent/screen-grant/revoke?'),
      );
    });

    testWidgets('A5.5 suspend bump stops the preview (revoke + unmount)', (
      WidgetTester tester,
    ) async {
      final calls = <String>[];
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: consentClient(calls),
      );
      addTearDown(api.close);
      Widget frame(int signal) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ScreenPreview(
              api: api,
              proximity: ProximityMode.near,
              suspendSignal: signal,
            ),
          ),
        ),
      );
      await tester.pumpWidget(frame(0));
      await tester.tap(find.text('Request preview'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for laptop approval'), findsOneWidget);
      // Tab switch / backgrounding bumps the counter…
      await tester.pumpWidget(frame(1));
      await tester.pumpAndSettle();
      expect(
        calls,
        contains('POST /screen/consent/screen-grant/revoke?'),
      );
      // …and the player area is back at the start (unmounted grant UI).
      expect(find.text('Request preview'), findsOneWidget);
      expect(find.text('Waiting for laptop approval'), findsNothing);
    });
  });

  group('A5.6 boot failure shows the designed retry state', () {
    testWidgets('keystore failure → Could not start + Retry', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(BuddyApp(store: _ThrowingStore()));
      await tester.pumpAndSettle();
      expect(find.text('Could not start'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Pair with your laptop'), findsNothing);
      // Retry re-runs boot (still failing here) without crashing.
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Could not start'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('A5.7 strict host gate', () {
    test('accepts hostnames, IPv4, IPv6, and ranged ports', () {
      for (final h in <String>[
        '192.168.1.10',
        '192.168.1.10:8443',
        'example.com',
        'laptop.local',
        'my-laptop',
        'localhost',
        'host:1',
        'host:65535',
        'https://192.168.1.10:8443/',
        '::1',
        'fe80::1',
        ' [::1] ',
        '[::1]:8443',
      ]) {
        expect(BuddyApi.isValidHost(h), isTrue, reason: h);
      }
    });

    test('rejects userinfo, spaces, fragments, queries, bad ports', () {
      for (final h in <String>[
        '',
        '   ',
        'user@host',
        'user:pass@host',
        'http://user@host/',
        'lap top',
        'host#frag',
        'host?x=1',
        r'host\name',
        'host:0',
        'host:70000',
        '192.168.1.10:70000',
        ':',
        '[::1',
        '::1]:8443',
      ]) {
        expect(BuddyApi.isValidHost(h), isFalse, reason: h);
      }
    });

    test('constructor throws unreachable for garbage', () {
      for (final h in <String>[
        'user@host',
        'lap top',
        'host#frag',
        'host:70000',
      ]) {
        expect(
          () => BuddyApi(host: h, token: 't'),
          throwsA(
            isA<BuddyApiException>().having(
              (e) => e.code,
              'code',
              'unreachable',
            ),
          ),
          reason: h,
        );
      }
    });

    test('unexpected client failures still map to unreachable', () {
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => throw StateError('weird')),
      );
      addTearDown(api.close);
      expect(
        api.checkHealth(),
        throwsA(
          isA<BuddyApiException>().having(
            (e) => e.code,
            'code',
            'unreachable',
          ),
        ),
      );
    });
  });

  group('A5.8 SSE backoff steps', () {
    test('1s/2s/4s/8s/16s then capped at 30s', () {
      expect(sseReconnectDelay(1), const Duration(seconds: 1));
      expect(sseReconnectDelay(2), const Duration(seconds: 2));
      expect(sseReconnectDelay(3), const Duration(seconds: 4));
      expect(sseReconnectDelay(4), const Duration(seconds: 8));
      expect(sseReconnectDelay(5), const Duration(seconds: 16));
      expect(sseReconnectDelay(6), const Duration(seconds: 30));
      expect(sseReconnectDelay(7), const Duration(seconds: 30));
      expect(sseReconnectDelay(100), const Duration(seconds: 30));
    });
  });

  group('A5.9 BLE causes + rescan backoff', () {
    test('rescan steps: 5s/10s/20s/40s then capped at 60s', () {
      expect(
        BleProximityReader.rescanDelay(1),
        const Duration(seconds: 5),
      );
      expect(
        BleProximityReader.rescanDelay(2),
        const Duration(seconds: 10),
      );
      expect(
        BleProximityReader.rescanDelay(3),
        const Duration(seconds: 20),
      );
      expect(
        BleProximityReader.rescanDelay(4),
        const Duration(seconds: 40),
      );
      expect(
        BleProximityReader.rescanDelay(5),
        const Duration(seconds: 60),
      );
      expect(
        BleProximityReader.rescanDelay(9),
        const Duration(seconds: 60),
      );
    });

    test('denied permission surfaces the cause, never silent FAR', () async {
      final sightings = StreamController<Sightings>.broadcast();
      addTearDown(sightings.close);
      final reader = BleProximityReader(
        sightings: sightings.stream,
        startScan: (_) async {},
        stopScan: () async {},
        staleAfter: const Duration(milliseconds: 20),
        ensurePermissions: () async => false,
      );
      final causes = <String?>[];
      final rssis = <int?>[];
      final causeSub = reader.cause.listen(causes.add);
      final rssiSub = reader.rssi.listen(rssis.add);
      await reader.start('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rssis, contains(null));
      expect(causes, contains(BleWatchCause.permissionDenied));
      expect(
        BleWatchCause.permissionDenied,
        contains('Permission denied'),
      );
      await causeSub.cancel();
      await rssiSub.cancel();
      await reader.dispose();
    });

    test('adapter-off surfaces Bluetooth off', () async {
      final sightings = StreamController<Sightings>.broadcast();
      final adapters = StreamController<BluetoothAdapterState>.broadcast();
      addTearDown(sightings.close);
      addTearDown(adapters.close);
      final reader = BleProximityReader(
        sightings: sightings.stream,
        startScan: (_) async {},
        stopScan: () async {},
        staleAfter: const Duration(seconds: 15),
        adapterStates: adapters.stream,
      );
      final causes = <String?>[];
      final causeSub = reader.cause.listen(causes.add);
      await reader.start('AA:BB:CC:DD:EE:FF');
      adapters.add(BluetoothAdapterState.off);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(causes, contains(BleWatchCause.bluetoothOff));
      await causeSub.cancel();
      await reader.dispose();
    });

    test('quiet watch re-arms with backoff and stop halts it', () async {
      final sightings = StreamController<Sightings>.broadcast();
      addTearDown(sightings.close);
      int starts = 0;
      final reader = BleProximityReader(
        sightings: sightings.stream,
        startScan: (_) async {
          starts++;
        },
        stopScan: () async {},
        staleAfter: const Duration(milliseconds: 20),
        rescanBase: const Duration(milliseconds: 20),
        rescanMax: const Duration(milliseconds: 60),
      );
      final rssiSub = reader.rssi.listen((_) {});
      await reader.start('AA:BB:CC:DD:EE:FF');
      expect(starts, 1);
      sightings.add(<({String id, int rssi})>[(id: 'aa:bb:cc:dd:ee:ff', rssi: -55)]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Stale + at least two backed-off re-arms fired.
      expect(starts, greaterThanOrEqualTo(3));
      final frozen = starts;
      await reader.stop();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(starts, frozen);
      await rssiSub.cancel();
      await reader.dispose();
    });

    testWidgets('calibrate screen shows the known FAR cause', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      proximity.setBleCause(BleWatchCause.bluetoothOff);
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          CalibrateScreen(
            api: api,
            proximity: proximity,
            onThresholdApplied: () async {},
          ),
        ),
      );
      expect(find.text(BleWatchCause.bluetoothOff), findsOneWidget);
    });
  });

  group('A5.10 dispose ordering is pinned', () {
    test('streams, then reader, then proximity', () async {
      final order = <String>[];
      await BuddyApp.shutdownOrder(
        cancelStreams: () async {
          order.add('streams');
        },
        disposeReader: () async {
          order.add('reader');
        },
        disposeProximity: () {
          order.add('proximity');
        },
      );
      expect(order, <String>['streams', 'reader', 'proximity']);
    });
  });

  group('A5.12 batch', () {
    testWidgets('task empty state renders alongside the stream error', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: TaskList(),
            isPaired: true,
            streamError: 'The live stream closed. Reconnect to resume.',
            onRetry: () {},
          ),
        ),
      );
      expect(find.text('Task updates paused'), findsOneWidget);
      expect(find.text('No tasks yet'), findsOneWidget);
    });

    testWidgets('Retry on a dead grant requests fresh consent', (
      WidgetTester tester,
    ) async {
      final calls = <String>[];
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((http.BaseRequest req) async {
          calls.add('${req.method} ${req.url.path}?${req.url.query}');
          if (req.url.path == '/screen/consent') {
            return http.Response(
              '{"consent_id": "g1", "status": "pending"}',
              200,
            );
          }
          return http.Response(
            '{"error": {"code": "forbidden", "message": "Requires near proximity"}}',
            403,
          );
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          ScreenPreview(api: api, proximity: ProximityMode.near),
        ),
      );
      await tester.tap(find.text('Request preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      // Dead grant (403): human copy, id cleared…
      expect(
        find.text(
          'Screen preview needs near proximity. Move closer to the laptop and try again.',
        ),
        findsOneWidget,
      );
      // …so Retry requests a FRESH consent instead of re-probing g1.
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      final consents = calls
          .where((c) => c.startsWith('POST /screen/consent?'))
          .toList();
      final probes = calls
          .where((c) => c.startsWith('GET /screen?'))
          .toList();
      expect(consents, hasLength(2));
      expect(probes, hasLength(1));
      expect(find.text('Waiting for laptop approval'), findsOneWidget);
    });

    testWidgets('calibrate failure unlatches the button (finally)', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient(
          (_) async => http.Response(
            '{"error": {"code": "forbidden", "message": "Requires near proximity"}}',
            403,
          ),
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          CalibrateScreen(
            api: api,
            proximity: proximity,
            onThresholdApplied: () async {},
          ),
        ),
      );
      await tester.tap(find.text('Set threshold'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Move closer to the laptop'),
        findsOneWidget,
      );
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Set threshold'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('calibrate draft follows the server threshold', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          CalibrateScreen(
            api: api,
            proximity: proximity,
            onThresholdApplied: () async {},
          ),
        ),
      );
      expect(find.text('New threshold: -60 dBm'), findsOneWidget);
      proximity.setThreshold(-70);
      await tester.pumpAndSettle();
      expect(find.text('New threshold: -70 dBm'), findsOneWidget);
    });
  });
}
