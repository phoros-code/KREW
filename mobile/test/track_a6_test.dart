import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:everyday_buddy/app.dart';
import 'package:everyday_buddy/models/buddy_event.dart';
import 'package:everyday_buddy/models/task_item.dart';
import 'package:everyday_buddy/models/task_notification.dart';
import 'package:everyday_buddy/screens/calibrate_screen.dart';
import 'package:everyday_buddy/screens/chat_screen.dart';
import 'package:everyday_buddy/screens/pairing_screen.dart';
import 'package:everyday_buddy/screens/task_list_screen.dart';
import 'package:everyday_buddy/services/ble_proximity.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:everyday_buddy/services/secure_store.dart';
import 'package:everyday_buddy/theme/buddy_theme.dart';
import 'package:everyday_buddy/widgets/command_bar.dart';
import 'package:everyday_buddy/widgets/console_column.dart';
import 'package:everyday_buddy/widgets/mjpeg_player.dart';
import 'package:everyday_buddy/widgets/screen_preview.dart';
import 'package:everyday_buddy/widgets/status_badge.dart';
import 'package:everyday_buddy/widgets/status_header.dart';
import 'package:everyday_buddy/widgets/task_notification_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Track A6 gap-closure tests. Mock transports only; DESIGN.md tokens are
/// asserted (hexes/spacing/radii), never modified. No new dependencies.
///
/// Production change in this track: ONE test-only seam —
/// [BuddyApi.probeClientFactory] — so validatePairing's 200/401/403/429
/// branches are drivable without a TLS handshake. Null in production;
/// pinning behavior untouched. Everything else is test code.
///
/// FakeAsync hazards documented where they bite (all verified in isolation):
/// - checkScreen's 200-probe `listen().cancel()` never settles under
///   FakeAsync (every later pump hangs) — those flows use [_settleReal].
/// - Cancelling an async* SSE subscription suspended mid-await-for hangs
///   both `cancel()` and a later `controller.close()` — the cancel test uses
///   take(2) auto-cancel and never closes the transport.
/// - Track C1: google_fonts removed — no runtime font futures, so
///   [_ignoreFontNoise] is a plain passthrough kept for call-site stability.

/// Scaffold frame for widget tests. No extra scroll view: ConsoleColumn
/// screens already own their scroll region + bottom bar.
Widget _frame(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Pump a bounded ~1s (10 x 100ms) instead of pumpAndSettle: mounted MJPEG
/// players arm a 5s bytes-idle watchdog, and a full settle would advance
/// past it and flip the player into the ended state mid-assertion.
Future<void> _settleShort(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Track C1: google_fonts removed — no font load futures exist, so this is a
/// plain passthrough kept so the two re-probe call sites stay unchanged.
Future<void> _ignoreFontNoise(Future<void> Function() body) async {
  await body();
}

/// Real-async settle for flows that cancel an idle streamed response:
/// checkScreen's 200-probe (`listen().cancel()`) never settles under
/// FakeAsync — the cancel poisons the fake microtask queue and every later
/// pump hangs (verified in isolation). Mock transports resolve in
/// microseconds; the short real delay drains them. Timers created inside
/// stay real, so the 5s player watchdog cannot fire mid-test.
Future<void> _settleReal(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  // Four frames: ready setState renders, the player mounts + streams, frame
  // setState renders, stream-done setState renders.
  for (int i = 0; i < 4; i++) {
    await tester.pump();
  }
}

/// HttpClient that fails fast (microtask, FakeAsync-friendly) with a refused
/// socket — hermetic paired-boot with zero real sockets: errors arrive while
/// the shell is subscribed, so onError handles them deterministically and
/// nothing leaks across tests. Only openUrl is ever touched (plus the
/// callback setter newPinnedClient installs and close); the rest throws.
class _FailFastClient implements HttpClient {
  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? cb,
  ) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    throw const SocketException('refused');
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FailFastOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FailFastClient();
}

/// Real 8x8 red JPEG (633 bytes, generated once via System.Drawing) -
/// decodable by Image.memory AND accepted by MjpegPreprocessor (>100 bytes).
const List<int> _tinyJpeg = <int>[
  255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 1,
  1, 1, 0, 96, 0, 96, 0, 0, 255, 219, 0, 67,
  0, 13, 9, 10, 11, 10, 8, 13, 11, 11, 11, 15,
  14, 13, 16, 20, 33, 21, 20, 18, 18, 20, 40, 29,
  30, 24, 33, 48, 42, 50, 49, 47, 42, 46, 45, 52,
  59, 75, 64, 52, 56, 71, 57, 45, 46, 66, 89, 66,
  71, 78, 80, 84, 85, 84, 51, 63, 93, 99, 92, 82,
  98, 75, 83, 84, 81, 255, 219, 0, 67, 1, 14, 15,
  15, 20, 17, 20, 39, 21, 21, 39, 81, 54, 46, 54,
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81,
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81,
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81,
  81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81, 81,
  81, 81, 255, 192, 0, 17, 8, 0, 8, 0, 8, 3,
  1, 34, 0, 2, 17, 1, 3, 17, 1, 255, 196, 0,
  31, 0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0,
  0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5,
  6, 7, 8, 9, 10, 11, 255, 196, 0, 181, 16, 0,
  2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0,
  0, 1, 125, 1, 2, 3, 0, 4, 17, 5, 18, 33,
  49, 65, 6, 19, 81, 97, 7, 34, 113, 20, 50, 129,
  145, 161, 8, 35, 66, 177, 193, 21, 82, 209, 240, 36,
  51, 98, 114, 130, 9, 10, 22, 23, 24, 25, 26, 37,
  38, 39, 40, 41, 42, 52, 53, 54, 55, 56, 57, 58,
  67, 68, 69, 70, 71, 72, 73, 74, 83, 84, 85, 86,
  87, 88, 89, 90, 99, 100, 101, 102, 103, 104, 105, 106,
  115, 116, 117, 118, 119, 120, 121, 122, 131, 132, 133, 134,
  135, 136, 137, 138, 146, 147, 148, 149, 150, 151, 152, 153,
  154, 162, 163, 164, 165, 166, 167, 168, 169, 170, 178, 179,
  180, 181, 182, 183, 184, 185, 186, 194, 195, 196, 197, 198,
  199, 200, 201, 202, 210, 211, 212, 213, 214, 215, 216, 217,
  218, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 241,
  242, 243, 244, 245, 246, 247, 248, 249, 250, 255, 196, 0,
  31, 1, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5,
  6, 7, 8, 9, 10, 11, 255, 196, 0, 181, 17, 0,
  2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0,
  1, 2, 119, 0, 1, 2, 3, 17, 4, 5, 33, 49,
  6, 18, 65, 81, 7, 97, 113, 19, 34, 50, 129, 8,
  20, 66, 145, 161, 177, 193, 9, 35, 51, 82, 240, 21,
  98, 114, 209, 10, 22, 36, 52, 225, 37, 241, 23, 24,
  25, 26, 38, 39, 40, 41, 42, 53, 54, 55, 56, 57,
  58, 67, 68, 69, 70, 71, 72, 73, 74, 83, 84, 85,
  86, 87, 88, 89, 90, 99, 100, 101, 102, 103, 104, 105,
  106, 115, 116, 117, 118, 119, 120, 121, 122, 130, 131, 132,
  133, 134, 135, 136, 137, 138, 146, 147, 148, 149, 150, 151,
  152, 153, 154, 162, 163, 164, 165, 166, 167, 168, 169, 170,
  178, 179, 180, 181, 182, 183, 184, 185, 186, 194, 195, 196,
  197, 198, 199, 200, 201, 202, 210, 211, 212, 213, 214, 215,
  216, 217, 218, 226, 227, 228, 229, 230, 231, 232, 233, 234,
  242, 243, 244, 245, 246, 247, 248, 249, 250, 255, 218, 0,
  12, 3, 1, 0, 2, 17, 3, 17, 0, 63, 0, 231,
  232, 162, 138, 241, 143, 210, 79, 255, 217,
];

/// Open SSE transport: 200 with caller-owned stream (mid-stream cancel test).
class _OpenSseClient extends http.BaseClient {
  final StreamController<List<int>> controller = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(controller.stream, 200);
}

/// Open MJPEG transport over a caller-owned byte stream.
class _StreamClient extends http.BaseClient {
  _StreamClient(this.stream);

  final Stream<List<int>> stream;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200);
}

/// Probe wrapper that records close() — pins validatePairing's finally.
class _ProbeClient extends http.BaseClient {
  _ProbeClient(this.inner);

  final MockClient inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);

  @override
  void close() {
    closed = true;
    inner.close();
  }
}

/// Stand-in HttpClient that records the badCertificateCallback production
/// code installs. Every other member throws via noSuchMethod — production
/// only sets the callback on it (then wraps it in an IOClient the test
/// closes), so nothing else is ever touched.
class _CallbackCatcher implements HttpClient {
  bool Function(X509Certificate cert, String host, int port)? callback;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? cb,
  ) {
    callback = cb;
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Routes the real HttpClient construction in newPinnedClient through a
/// [_CallbackCatcher], so the test invokes the PRODUCTION callback.
/// Test-only harness: the factory constructor consults HttpOverrides, and
/// production code is untouched.
class _CaptureOverrides extends HttpOverrides {
  _CallbackCatcher? catcher;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    catcher = _CallbackCatcher();
    return catcher!;
  }
}

/// Minimal X509Certificate stand-in carrying caller-chosen DER bytes.
class _FakeCert implements X509Certificate {
  _FakeCert(this.der);

  @override
  final Uint8List der;

  @override
  String get pem => '';

  @override
  Uint8List get sha1 => Uint8List(0);

  @override
  String get subject => '';

  @override
  String get issuer => '';

  @override
  DateTime get startValidity => DateTime.fromMillisecondsSinceEpoch(0);

  @override
  DateTime get endValidity => DateTime.fromMillisecondsSinceEpoch(0);
}

/// In-memory FlutterSecureStorage backend for SecureStore tests.
class _MemoryStorage extends FlutterSecureStorage {
  _MemoryStorage() : super();

  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => map[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    map.remove(key);
  }
}

/// Boot-store stub for app-shell smoke tests (null = unpaired).
class _FakeBootStore extends SecureStore {
  _FakeBootStore({this.pairing}) : super(storage: _MemoryStorage());

  final PairingInfo? pairing;

  @override
  Future<PairingInfo?> readPairing() async => pairing;

  @override
  Future<String?> readBtDeviceId() async => null;

  @override
  Future<String?> readCertFingerprint() async => null;
}

/// One sighting without inline record-literal parsing quirks.
({String id, int rssi}) _sight(String id, int rssi) => (id: id, rssi: rssi);

BuddyApi _mockApi(Future<http.Response> Function(http.BaseRequest) handler) =>
    BuddyApi(
      host: '192.168.1.10',
      token: 't',
      client: MockClient(handler),
    );

void main() {
  // Track C1: google_fonts removed — no test font config needed.

  group('A6.1 watchEvents parser', () {
    test('multi-line data: frames fold into one JSON payload', () async {
      final api = _mockApi(
        (_) async => http.Response(
          'event: task_completed\n'
          'data: {"task_id": "t1",\n'
          'data: "result": "all done"}\n'
          '\n',
          200,
        ),
      );
      addTearDown(api.close);
      final events = await api.watchEvents().toList();
      expect(events.map((e) => e.type), <String>[
        'connected',
        'task_completed',
      ]);
      expect(events[1].taskId, 't1');
      expect(events[1].result, 'all done');
    });

    test('data:-before-event: order still dispatches', () async {
      final api = _mockApi(
        (_) async => http.Response(
          'data: {"task_id": "t9", "text": "hi"}\n'
          'event: task_started\n'
          '\n',
          200,
        ),
      );
      addTearDown(api.close);
      final events = await api.watchEvents().toList();
      expect(events.map((e) => e.type), <String>[
        'connected',
        'task_started',
      ]);
      expect(events[1].taskId, 't9');
      expect(events[1].text, 'hi');
    });

    test('malformed-JSON and non-object frames are skipped', () async {
      final api = _mockApi(
        (_) async => http.Response(
          'event: task_started\n'
          'data: not-json-at-all\n'
          '\n'
          'event: tool_call\n'
          'data: 42\n'
          '\n'
          'event: task_started\n'
          'data: {"task_id": "ok1", "text": "hi"}\n'
          '\n',
          200,
        ),
      );
      addTearDown(api.close);
      final events = await api.watchEvents().toList();
      expect(events.map((e) => e.type), <String>[
        'connected',
        'task_started',
      ]);
      expect(events[1].taskId, 'ok1');
    });

    test(': ping comments count as activity but yield no frame', () async {
      final api = _mockApi(
        (_) async => http.Response(
          ': ping\n'
          '\n'
          'event: task_started\n'
          'data: {"task_id": "c1", "text": "hey"}\n'
          '\n'
          ': ping\n',
          200,
        ),
      );
      addTearDown(api.close);
      int activities = 0;
      final events = await api
          .watchEvents(onActivity: () => activities++)
          .toList();
      expect(events.map((e) => e.type), <String>[
        'connected',
        'task_started',
      ]);
      expect(activities, greaterThanOrEqualTo(3));
    });

    test('non-200 surfaces the typed envelope, never the raw body', () async {
      final api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "forbidden", "message": "Requires near"}}',
          403,
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.watchEvents(),
        emitsError(
          isA<BuddyApiException>().having((e) => e.code, 'code', 'forbidden'),
        ),
      );
    });

    test('cancellation mid-stream drops without error', () async {
      final transport = _OpenSseClient();
      // NOTE: no controller.close() in teardown. Verified in isolation:
      // closing a controller whose transformed stream was abandoned
      // mid-await-for by a cancelled async* generator never completes, and
      // explicitly awaiting sub.cancel() hangs the same way. take(2)
      // auto-cancels mid-stream while the response stays open — the
      // hasListener assertion below proves the teardown propagated.
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: transport,
      );
      addTearDown(api.close);
      final Future<List<BuddyEvent>> taken = api
          .watchEvents()
          .take(2)
          .toList();
      transport.controller.add(
        utf8.encode('event: task_started\ndata: {"task_id": "x"}\n\n'),
      );
      final List<BuddyEvent> events = await taken;
      expect(events.map((e) => e.type), <String>[
        'connected',
        'task_started',
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(transport.controller.hasListener, isFalse);
    });

    test('clean close yields connected, then onDone', () async {
      final api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final events = await api.watchEvents().toList();
      expect(events.map((e) => e.type), <String>['connected']);
    });
  });

  group('A6.2 postCommand', () {
    test('sends {text} + X-RSSI and parses task_id/status', () async {
      String? seenAuth;
      String? seenRssi;
      String? seenContentType;
      Map<String, dynamic>? seenBody;
      final api = _mockApi((http.BaseRequest req) async {
        seenAuth = req.headers['Authorization'];
        seenRssi = req.headers['X-RSSI'];
        seenContentType = req.headers['Content-Type'];
        seenBody = jsonDecode((req as http.Request).body)
            as Map<String, dynamic>;
        return http.Response('{"task_id": "ab12", "status": "queued"}', 200);
      });
      addTearDown(api.close);
      final CommandResult result = await api.postCommand(
        'hello',
        rssi: '-55',
      );
      expect(result.taskId, 'ab12');
      expect(result.status, 'queued');
      expect(seenBody, <String, dynamic>{'text': 'hello'});
      expect(seenRssi, '-55');
      expect(seenAuth, 'Bearer t');
      expect(seenContentType, contains('application/json'));
    });

    test('omits X-RSSI when no reading exists', () async {
      String? seenRssi = 'unset';
      final api = _mockApi((http.BaseRequest req) async {
        seenRssi = req.headers['X-RSSI'];
        return http.Response('{"task_id": "ab12", "status": "queued"}', 200);
      });
      addTearDown(api.close);
      await api.postCommand('hello');
      expect(seenRssi, isNull);
    });

    test('401 maps to unauthorized', () async {
      final api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "unauthorized", "message": "bad token"}}',
          401,
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.postCommand('hi'),
        throwsA(
          isA<BuddyApiException>().having(
            (e) => e.code,
            'code',
            'unauthorized',
          ),
        ),
      );
    });

    test('403 maps to forbidden', () async {
      final api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "forbidden", "message": "near only"}}',
          403,
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.postCommand('hi'),
        throwsA(
          isA<BuddyApiException>().having(
            (e) => e.code,
            'code',
            'forbidden',
          ),
        ),
      );
    });

    test('429 maps to locked_out', () async {
      final api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "locked_out", "message": "slow down"}}',
          429,
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.postCommand('hi'),
        throwsA(
          isA<BuddyApiException>().having(
            (e) => e.code,
            'code',
            'locked_out',
          ),
        ),
      );
    });
  });

  group('A6.3 validatePairing (probe seam)', () {
    Future<({BuddyApi api, _ProbeClient probe})> setup(
      http.Response probeResp,
    ) async {
      final probe = _ProbeClient(
        MockClient((_) async => probeResp),
      );
      BuddyApi.probeClientFactory = (_) => probe;
      addTearDown(() {
        BuddyApi.probeClientFactory = null;
      });
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => http.Response('{"status":"ok"}', 200)),
      );
      addTearDown(api.close);
      return (api: api, probe: probe);
    }

    test('200-then-cancel completes and closes the probe', () async {
      final s = await setup(
        http.Response(
          'event: task_started\ndata: {"task_id": "a", "text": "hi"}\n\n',
          200,
        ),
      );
      await s.api.validatePairing();
      expect(s.probe.closed, isTrue);
    });

    test('401 probe maps to unauthorized and still closes', () async {
      final s = await setup(
        http.Response(
          '{"error": {"code": "unauthorized", "message": "bad token"}}',
          401,
        ),
      );
      await expectLater(
        s.api.validatePairing(),
        throwsA(
          isA<BuddyApiException>().having(
            (e) => e.code,
            'code',
            'unauthorized',
          ),
        ),
      );
      expect(s.probe.closed, isTrue);
    });

    test('403 probe maps to forbidden and still closes', () async {
      final s = await setup(
        http.Response(
          '{"error": {"code": "forbidden", "message": "near only"}}',
          403,
        ),
      );
      await expectLater(
        s.api.validatePairing(),
        throwsA(
          isA<BuddyApiException>().having(
            (e) => e.code,
            'code',
            'forbidden',
          ),
        ),
      );
      expect(s.probe.closed, isTrue);
    });

    test('429 probe maps to locked_out and still closes', () async {
      final s = await setup(
        http.Response(
          '{"error": {"code": "locked_out", "message": "slow down"}}',
          429,
        ),
      );
      await expectLater(
        s.api.validatePairing(),
        throwsA(
          isA<BuddyApiException>().having(
            (e) => e.code,
            'code',
            'locked_out',
          ),
        ),
      );
      expect(s.probe.closed, isTrue);
    });
  });

  group('A6.4 badCertificateCallback (capture harness)', () {
    // SHA-256("") — fixed public vector, no cert needed.
    const emptySha256 =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    bool checkPin(String? pin, List<int> der) {
      final overrides = _CaptureOverrides();
      // Save/restore: the widget binding owns a global 400-mock — never
      // null it out (that would leak real sockets into later tests).
      final HttpOverrides? previous = HttpOverrides.current;
      HttpOverrides.global = overrides;
      try {
        final client = BuddyApi.newPinnedClient(pin);
        final cb = overrides.catcher?.callback;
        expect(cb, isNotNull, reason: 'pin: $pin');
        final bool result = cb!(
          _FakeCert(Uint8List.fromList(der)),
          'laptop',
          443,
        );
        client.close();
        return result;
      } finally {
        HttpOverrides.global = previous;
      }
    }

    test('empty pin trusts nothing', () {
      expect(checkPin('', <int>[]), isFalse);
      expect(checkPin(null, <int>[]), isFalse);
      // Even the exact DER match is refused with no pin (fail closed).
      expect(checkPin('  ', <int>[]), isFalse);
    });

    test('matching DER is trusted', () {
      expect(checkPin(emptySha256, <int>[]), isTrue);
    });

    test('mismatched DER is refused', () {
      expect(checkPin(emptySha256, <int>[0]), isFalse);
      expect(checkPin('00' * 32, <int>[]), isFalse);
    });
  });

  group('A6.5 displayHost + splitHostPort', () {
    test('displayHost hides the default 8443, shows overrides', () {
      final bare = _mockApi((_) async => http.Response('', 200));
      addTearDown(bare.close);
      expect(bare.displayHost, '192.168.1.10');
      final custom = BuddyApi(
        host: '192.168.1.10:9443',
        token: 't',
        client: MockClient((_) async => http.Response('', 200)),
      );
      addTearDown(custom.close);
      expect(custom.displayHost, '192.168.1.10:9443');
      final v6 = BuddyApi(
        host: '[::1]:9443',
        token: 't',
        client: MockClient((_) async => http.Response('', 200)),
      );
      addTearDown(v6.close);
      expect(v6.displayHost, '[::1]:9443');
    });

    test('rejects userinfo, whitespace, ?/# remnants', () {
      for (final h in <String>[
        'user@host',
        'user:pass@host',
        'lap top',
        'host?x=1',
        'host#frag',
      ]) {
        expect(BuddyApi.isValidHost(h), isFalse, reason: h);
        expect(
          () => BuddyApi(
            host: h,
            token: 't',
            client: MockClient((_) async => http.Response('', 200)),
          ),
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

    test('rejects out-of-range ports, keeps IPv6 intact', () {
      for (final h in <String>['host:70000', '192.168.1.10:70000']) {
        expect(BuddyApi.isValidHost(h), isFalse, reason: h);
      }
      expect(BuddyApi.isValidHost('[::1]:8443'), isTrue);
      expect(BuddyApi.isValidHost('::1'), isTrue);
      final parsed = BuddyApi.splitHostPort('[::1]:9443');
      expect(parsed.host, '[::1]');
      expect(parsed.port, 9443);
      final bare6 = BuddyApi.splitHostPort('::1');
      expect(bare6.host, '::1');
      expect(bare6.port, 8443);
    });
  });

  group('A6.6 smoke: app boot', () {
    testWidgets('unpaired boot shows Pair tab + 4 tabs', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(BuddyApp(store: _FakeBootStore()));
      await tester.pumpAndSettle();
      expect(find.text('Pair with your laptop'), findsOneWidget);
      for (final label in <String>['Pair', 'Chat', 'Tasks', 'Screen']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('paired boot lands on Chat + 4 tabs', (
      WidgetTester tester,
    ) async {
      // Hermetic: fail-fast transport instead of real sockets (a refused
      // localhost connection otherwise completes on the real event loop at
      // an arbitrary moment — possibly after unmount, as an uncaught error).
      // Save/restore: the widget binding owns a global 400-mock — resetting
      // to null would leak real sockets into later tests.
      final HttpOverrides? previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _FailFastOverrides();
      addTearDown(() => HttpOverrides.global = previousOverrides);
      await tester.pumpWidget(
        BuddyApp(
          store: _FakeBootStore(
            pairing: const PairingInfo(host: '127.0.0.1', token: 'tok12345'),
          ),
        ),
      );
      // Bounded pumps only: the shell opens a stream + a 30s stall timer —
      // settling would loop on the reconnect path.
      for (int i = 0; i < 5; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 100));
      // Track C1: M3 NavigationBar (not M2 BottomNavigationBar).
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
      for (final label in <String>['Pair', 'Chat', 'Tasks', 'Screen']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Agent log'), findsOneWidget);
      // Unmount cancels the pending stream/stall timers — clean teardown.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(tester.takeException(), isNull);
    });
  });

  group('A6.6 smoke: chat', () {
    ChatScreen chatOf({
      BuddyApi? api,
      List<BuddyEvent> events = const <BuddyEvent>[],
      ProximityService? proximity,
      String? streamError,
      bool streamConnected = false,
    }) =>
        ChatScreen(
          api: api,
          events: events,
          proximity: proximity ?? ProximityService(),
          onSend: (_) async {},
          streamError: streamError,
          streamConnected: streamConnected,
          onRetryStream: () {},
        );

    testWidgets('unpaired empty state', (WidgetTester tester) async {
      await tester.pumpWidget(_frame(chatOf()));
      expect(find.text('No laptop paired yet'), findsOneWidget);
    });

    testWidgets('stream error state with Reconnect', (
      WidgetTester tester,
    ) async {
      final api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          chatOf(
            api: api,
            streamError: 'The live stream closed. Reconnect to resume.',
          ),
        ),
      );
      expect(find.text('Live updates paused'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
    });

    testWidgets('log rows render status + mono line', (
      WidgetTester tester,
    ) async {
      final api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final proximity = ProximityService()
        ..markNear()
        ..setOnline();
      await tester.pumpWidget(
        _frame(
          chatOf(
            api: api,
            proximity: proximity,
            streamConnected: true,
            events: <BuddyEvent>[
              BuddyEvent(
                type: 'task_started',
                receivedAt: DateTime.now(),
                taskId: 'abcdef12',
                text: 'do the thing',
              ),
            ],
          ),
        ),
      );
      expect(find.text('Task started'), findsOneWidget);
      expect(find.textContaining('do the thing'), findsOneWidget);
      expect(find.text('Live updates paused'), findsNothing);
    });
  });

  group('A6.6 smoke: pairing validators', () {
    testWidgets('empty submit shows all three field errors', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(PairingScreen(store: SecureStore(), onPaired: (_, __, ___) {})),
      );
      await tester.ensureVisible(find.text('Test connection and save'));
      await tester.tap(find.text('Test connection and save'));
      await tester.pump();
      expect(
        find.text('Enter the laptop IP shown by the pairing script.'),
        findsOneWidget,
      );
      expect(
        find.text('Enter the pairing token from the laptop.'),
        findsOneWidget,
      );
      expect(
        find.text('Paste the cert fingerprint from the laptop pairing script.'),
        findsOneWidget,
      );
    });

    testWidgets('bad host + short token show field copy, no network', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(PairingScreen(store: SecureStore(), onPaired: (_, __, ___) {})),
      );
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'user@host',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'short');
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'ab' * 32,
      );
      await tester.ensureVisible(find.text('Test connection and save'));
      await tester.tap(find.text('Test connection and save'));
      await tester.pump();
      expect(
        find.text(
          'That host does not look valid — use an IP or hostname, with an optional :port.',
        ),
        findsOneWidget,
      );
      expect(find.text('That token looks too short.'), findsOneWidget);
      expect(find.text('Pairing failed'), findsNothing);
    });
  });

  group('A6.6 smoke: task list', () {
    testWidgets('paired empty state', (WidgetTester tester) async {
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: TaskList(),
            isPaired: true,
            streamError: null,
            onRetry: () {},
          ),
        ),
      );
      expect(find.text('No tasks yet'), findsOneWidget);
    });

    testWidgets('unpaired empty state', (WidgetTester tester) async {
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: TaskList(),
            isPaired: false,
            streamError: null,
            onRetry: () {},
          ),
        ),
      );
      expect(find.text('No laptop paired yet'), findsOneWidget);
    });

    testWidgets('rows render badge + title', (WidgetTester tester) async {
      final tasks = TaskList()..setQueued('t1', 'do research');
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: tasks,
            isPaired: true,
            streamError: null,
            onRetry: () {},
          ),
        ),
      );
      expect(find.text('QUEUED'), findsOneWidget);
      expect(find.text('do research'), findsOneWidget);
      expect(find.text('t1'), findsOneWidget);
    });
  });

  group('A6.6 smoke: command bar', () {
    testWidgets('disabled reason renders, Send is dead', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(
          CommandBar(
            enabled: false,
            disabledReason: 'FAR mode: notifications only.',
            onSend: (_) async {},
          ),
        ),
      );
      expect(find.text('FAR mode: notifications only.'), findsOneWidget);
      final send = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Send'),
      );
      expect(send.onPressed, isNull);
    });

    testWidgets('busy shows the spinner', (WidgetTester tester) async {
      await tester.pumpWidget(
        _frame(
          CommandBar(enabled: true, sending: true, onSend: (_) async {}),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Busy replaces the Send label with the spinner — find by type.
      final send = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(send.onPressed, isNull);
    });

    testWidgets('enabled send delivers text and clears', (
      WidgetTester tester,
    ) async {
      String? seen;
      await tester.pumpWidget(
        _frame(
          CommandBar(
            enabled: true,
            onSend: (String text) async {
              seen = text;
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'hello laptop');
      await tester.tap(find.text('Send'));
      await tester.pump();
      expect(seen, 'hello laptop');
      expect(find.text('hello laptop'), findsNothing);
    });
  });

  group('A6.6 smoke: console column, header, badge, banner', () {
    testWidgets('console column renders child + bottom bar', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConsoleColumn(
              bottomBar: Text('bottom-bar'),
              child: Text('body-content'),
            ),
          ),
        ),
      );
      expect(find.text('body-content'), findsOneWidget);
      expect(find.text('bottom-bar'), findsOneWidget);
    });

    testWidgets(
        'status header: near/far x online/offline/connecting x running/idle',
        (WidgetTester tester) async {
      const connLabels = <BuddyConnection, String>{
        BuddyConnection.online: 'ONLINE',
        BuddyConnection.offline: 'OFFLINE',
        BuddyConnection.unknown: 'CONNECTING',
      };
      for (final prox in ProximityMode.values) {
        for (final conn in BuddyConnection.values) {
          for (final running in <int>[0, 2]) {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  appBar: StatusHeader(
                    proximity: prox,
                    connection: conn,
                    runningCount: running,
                  ),
                ),
              ),
            );
            expect(tester.takeException(), isNull);
            expect(
              find.text(prox == ProximityMode.near ? 'NEAR' : 'FAR'),
              findsOneWidget,
            );
            expect(find.text(connLabels[conn]!), findsOneWidget);
            expect(
              find.text(running > 0 ? '$running RUNNING' : 'IDLE'),
              findsOneWidget,
            );
          }
        }
      }
    });

    testWidgets('status badge renders all four states', (
      WidgetTester tester,
    ) async {
      for (final status in TaskStatus.values) {
        await tester.pumpWidget(_frame(StatusBadge(status: status)));
        expect(find.text(status.label), findsOneWidget);
      }
    });

    testWidgets('task notification content renders title + summary', (
      WidgetTester tester,
    ) async {
      final notice = TaskNotification.fromEvent(
        BuddyEvent.fromSse('task_failed', <String, dynamic>{
          'task_id': 'abc123',
          'error': 'boom',
        }),
      )!;
      await tester.pumpWidget(
        _frame(TaskNotificationContent(notification: notice)),
      );
      expect(find.text('Task failed'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
    });

    testWidgets('showTaskNotification: View routes to onView', (
      WidgetTester tester,
    ) async {
      final notice = TaskNotification.fromEvent(
        BuddyEvent.fromSse('task_completed', <String, dynamic>{
          'task_id': 'abc123',
          'result': 'ok',
        }),
      )!;
      bool viewed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext ctx) => ElevatedButton(
                onPressed: () => showTaskNotification(
                  ScaffoldMessenger.of(ctx),
                  notification: notice,
                  onView: () => viewed = true,
                ),
                child: const Text('ping'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ping'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('View'), findsOneWidget);
      await tester.tap(find.text('View'));
      await tester.pump();
      expect(viewed, isTrue);
    });
  });

  group('A6.7 ScreenPreview missing phases', () {
    BuddyApi consentApi({
      required http.Response Function() probe,
      String consentId = 'g1',
    }) =>
        _mockApi((http.BaseRequest req) async {
          if (req.method == 'POST' && req.url.path == '/screen/consent') {
            return http.Response(
              '{"consent_id": "$consentId", "status": "pending"}',
              200,
            );
          }
          if (req.method == 'GET' && req.url.path == '/screen') {
            return probe();
          }
          return http.Response('not found', 404);
        });

    Future<void> toAwaiting(WidgetTester tester, BuddyApi api) async {
      await tester.pumpWidget(
        _frame(ScreenPreview(api: api, proximity: ProximityMode.near)),
      );
      await tester.tap(find.text('Request preview'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for laptop approval'), findsOneWidget);
    }

    testWidgets('consentRequired -> ready mounts the player with frames', (
      WidgetTester tester,
    ) async {
      await _ignoreFontNoise(() async {
        int gets = 0;
        final api = consentApi(
          probe: () {
            gets++;
            if (gets == 1) {
              return http.Response(
                '{"error": {"code": "consent_required", "message": "pending"}}',
                403,
              );
            }
            return http.Response('', 200);
          },
        );
        addTearDown(api.close);
        await toAwaiting(tester, api);
        await tester.tap(find.text('Check again'));
        // 403 consent_required travels the bytesToString path
        // (FakeAsync-safe).
        await _settleShort(tester);
        // Still pending — grant kept, back to waiting.
        expect(find.text('Waiting for laptop approval'), findsOneWidget);
        await tester.tap(find.text('Check again'));
        // 200 available travels the listen().cancel() probe path — clock.
        await _settleReal(tester);
        expect(find.text('Live preview'), findsOneWidget);
        // The grant mounts an authenticated player pointed at THIS grant:
        // stream URL carries ?consent_id= and the header echoes it. (Frame
        // bytes themselves are covered by A6.9: under the widget-test
        // binding every real HttpClient answers 400, so the player can only
        // mount here, never stream — production wires the pinned client.)
        final MjpegPlayer player = tester.widget<MjpegPlayer>(
          find.byType(MjpegPlayer),
        );
        expect(player.streamUrl, contains('consent_id=g1'));
        expect(player.headers['X-Consent-Id'], 'g1');
        expect(player.headers['Authorization'], 'Bearer t');
        // Tear down mounted: unmount first so dispose cancels the player
        // before the next test pumps its own tree.
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      });
    });

    testWidgets('consentDenied shows the denied copy, Retry re-requests', (
      WidgetTester tester,
    ) async {
      int posts = 0;
      final api = _mockApi((http.BaseRequest req) async {
        if (req.method == 'POST' && req.url.path == '/screen/consent') {
          posts++;
          return http.Response(
            '{"consent_id": "g$posts", "status": "pending"}',
            200,
          );
        }
        return http.Response(
          '{"error": {"code": "consent_denied", "message": "no"}}',
          403,
        );
      });
      addTearDown(api.close);
      await toAwaiting(tester, api);
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The laptop denied this preview request. Request again if that was a mistake.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      // Dead grant was cleared — Retry requested a FRESH consent.
      expect(posts, 2);
      expect(find.text('Waiting for laptop approval'), findsOneWidget);
    });

    testWidgets('notImplemented shows the 501 state', (
      WidgetTester tester,
    ) async {
      final api = consentApi(
        probe: () => http.Response(
          '{"error": {"code": "not_implemented", "message": "later"}}',
          501,
        ),
      );
      addTearDown(api.close);
      await toAwaiting(tester, api);
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('is not on this server yet'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('unauthorized shows the re-pair copy', (
      WidgetTester tester,
    ) async {
      final api = consentApi(
        probe: () => http.Response(
          '{"error": {"code": "unauthorized", "message": "bad token"}}',
          401,
        ),
      );
      addTearDown(api.close);
      await toAwaiting(tester, api);
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(
        find.text('The pairing token was rejected. Re-pair from the Pair tab.'),
        findsOneWidget,
      );
    });

    testWidgets('forbidden shows the near-proximity copy', (
      WidgetTester tester,
    ) async {
      final api = consentApi(
        probe: () => http.Response(
          '{"error": {"code": "forbidden", "message": "near only"}}',
          403,
        ),
      );
      addTearDown(api.close);
      await toAwaiting(tester, api);
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Screen preview needs near proximity. Move closer to the laptop and try again.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('FAR blocks with the near-only copy', (
      WidgetTester tester,
    ) async {
      final api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(ScreenPreview(api: api, proximity: ProximityMode.far)),
      );
      expect(find.text('Preview unavailable while FAR'), findsOneWidget);
      expect(find.text('Request preview'), findsNothing);
    });

    testWidgets('unpaired shows the pair-first empty state', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(
          const ScreenPreview(api: null, proximity: ProximityMode.far),
        ),
      );
      expect(find.text('No laptop paired yet'), findsOneWidget);
    });

    testWidgets('_handleStreamError re-probes and bumps the stream key', (
      WidgetTester tester,
    ) async {
      await _ignoreFontNoise(() async {
        final api = consentApi(probe: () => http.Response('', 200));
        addTearDown(api.close);
        await toAwaiting(tester, api);
        await tester.tap(find.text('Check again'));
        // 200-probe path (listen/cancel) needs the real clock — see helper.
        await _settleReal(tester);
        expect(find.text('Live preview'), findsOneWidget);
        // The mounted player cannot stream under the widget-test binding
        // (every real HttpClient answers 400 there), so it lands in the
        // dropped state — whose Retry is the mid-stream re-probe trigger.
        expect(find.text('Stream dropped — retry'), findsOneWidget);
        final Key? before = tester
            .widget<MjpegPlayer>(find.byType(MjpegPlayer))
            .key;
        await tester.tap(find.text('Retry'));
        await _settleReal(tester);
        // Re-probe said available again: fresh player key, still live.
        final Key? after = tester
            .widget<MjpegPlayer>(find.byType(MjpegPlayer))
            .key;
        expect(after, isNotNull);
        expect(after, isNot(equals(before)));
        expect(find.text('Live preview'), findsOneWidget);
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      });
    });
  });

  group('A6.8 CalibrateScreen apply + errors + controls', () {
    CalibrateScreen calibrateOf({
      required BuddyApi? api,
      required ProximityService proximity,
      Future<void> Function()? onApplied,
      bool Function()? appliedFlag,
    }) =>
        CalibrateScreen(
          api: api,
          proximity: proximity,
          onThresholdApplied: () async {
            if (appliedFlag != null) appliedFlag();
            if (onApplied != null) await onApplied();
          },
        );

    testWidgets('apply success posts, refreshes, and snacks', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      bool applied = false;
      final api = _mockApi(
        (_) async => http.Response(
          '{"mode": "lan_plus_bluetooth", "rssi_near_threshold": -65}',
          200,
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          calibrateOf(
            api: api,
            proximity: proximity,
            appliedFlag: () => applied = true,
          ),
        ),
      );
      await tester.tap(find.text('Set threshold'));
      await _settleShort(tester);
      expect(find.text('Threshold set to -65 dBm.'), findsOneWidget);
      expect(applied, isTrue);
      expect(proximity.rssiNearThreshold, -65);
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Set threshold'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('unauthorized maps to the re-pair copy', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      final api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "unauthorized", "message": "bad"}}',
          401,
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(calibrateOf(api: api, proximity: proximity)),
      );
      await tester.tap(find.text('Set threshold'));
      await tester.pumpAndSettle();
      expect(
        find.text('The pairing token was rejected. Re-pair from the Pair tab.'),
        findsOneWidget,
      );
    });

    testWidgets('bad_request maps to the range copy', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      final api = _mockApi(
        (_) async => http.Response(
          '{"error": {"code": "bad_request", "message": "range"}}',
          400,
        ),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(calibrateOf(api: api, proximity: proximity)),
      );
      await tester.tap(find.text('Set threshold'));
      await tester.pumpAndSettle();
      expect(find.textContaining('out of range'), findsOneWidget);
    });

    testWidgets('unreachable passes the route copy through', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      final api = BuddyApi(
        host: '192.168.1.10',
        token: 't',
        client: MockClient((_) async => throw const SocketException('refused')),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(calibrateOf(api: api, proximity: proximity)),
      );
      await tester.tap(find.text('Set threshold'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No route to the laptop'), findsOneWidget);
    });

    testWidgets('stepper and slider move the draft', (
      WidgetTester tester,
    ) async {
      final proximity = ProximityService();
      final api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(calibrateOf(api: api, proximity: proximity)),
      );
      expect(find.text('New threshold: -60 dBm'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      expect(find.text('New threshold: -59 dBm'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
      expect(find.text('New threshold: -60 dBm'), findsOneWidget);
      await tester.drag(find.byType(Slider), const Offset(200, 0));
      await tester.pump();
      expect(find.text('New threshold: -60 dBm'), findsNothing);
    });
  });

  group('A6.9 MjpegPlayer happy path', () {
    testWidgets('jpeg bytes render Image; dispose cancels the subscription', (
      WidgetTester tester,
    ) async {
      final controller = StreamController<List<int>>();
      addTearDown(() async {
        if (!controller.isClosed) await controller.close();
      });
      await tester.pumpWidget(
        _frame(
          MjpegPlayer(
            streamUrl: 'https://192.168.1.10:8443/screen?consent_id=g1',
            headers: const <String, String>{'Authorization': 'Bearer t'},
            client: _StreamClient(controller.stream),
            stallTimeout: const Duration(minutes: 5),
            onRetry: () {},
            onStop: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Starting live preview…'), findsOneWidget);
      controller.add(_tinyJpeg);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(controller.hasListener, isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      expect(controller.hasListener, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('A6.10 BleProximityReader lifecycle', () {
    BleProximityReader readerOf({
      required Stream<Sightings> sightings,
      required Future<void> Function(List<String>) startScan,
      required Future<void> Function() stopScan,
      Duration staleAfter = const Duration(milliseconds: 30),
      Duration rescanBase = const Duration(seconds: 5),
      Duration rescanMax = const Duration(seconds: 60),
    }) =>
        BleProximityReader(
          sightings: sightings,
          startScan: startScan,
          stopScan: stopScan,
          staleAfter: staleAfter,
          rescanBase: rescanBase,
          rescanMax: rescanMax,
        );

    test('stale triggers a backed-off rescan', () async {
      final sightings = StreamController<Sightings>.broadcast();
      addTearDown(sightings.close);
      int starts = 0;
      final reader = readerOf(
        sightings: sightings.stream,
        startScan: (_) async {
          starts++;
        },
        stopScan: () async {},
        staleAfter: const Duration(milliseconds: 20),
        rescanBase: const Duration(milliseconds: 20),
        rescanMax: const Duration(milliseconds: 60),
      );
      final seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('AA:BB:CC:DD:EE:FF');
      expect(starts, 1);
      sightings.add(<({String id, int rssi})>[_sight('aa:bb:cc:dd:ee:ff', -55)]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, contains(-55));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(seen, contains(null));
      expect(starts, greaterThanOrEqualTo(2));
      await sub.cancel();
      await reader.dispose();
    });

    test('double start() restarts cleanly with one subscription', () async {
      final sightings = StreamController<Sightings>.broadcast();
      addTearDown(sightings.close);
      int starts = 0;
      int stops = 0;
      final reader = readerOf(
        sightings: sightings.stream,
        startScan: (_) async {
          starts++;
        },
        stopScan: () async {
          stops++;
        },
        staleAfter: const Duration(milliseconds: 200),
      );
      final seen = <int?>[];
      final sub = reader.rssi.listen(seen.add);
      await reader.start('AA:BB:CC:DD:EE:FF');
      await reader.start('AA:BB:CC:DD:EE:FF');
      expect(starts, 2);
      expect(stops, greaterThanOrEqualTo(1));
      expect(reader.isWatching, isTrue);
      sightings.add(<({String id, int rssi})>[_sight('aa:bb:cc:dd:ee:ff', -55)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.where((int? r) => r == -55), hasLength(1));
      await sub.cancel();
      await reader.dispose();
    });

    test('dispose is idempotent', () async {
      final sightings = StreamController<Sightings>.broadcast();
      addTearDown(sightings.close);
      final reader = readerOf(
        sightings: sightings.stream,
        startScan: (_) async {},
        stopScan: () async {},
      );
      await reader.start('AA:BB:CC:DD:EE:FF');
      await reader.dispose();
      await reader.dispose();
      expect(reader.isWatching, isFalse);
    });

    test('stop-while-scanning never throws, watch stays down', () async {
      final sightings = StreamController<Sightings>.broadcast();
      addTearDown(sightings.close);
      final gate = Completer<void>();
      final reader = readerOf(
        sightings: sightings.stream,
        startScan: (_) => gate.future,
        stopScan: () async {},
      );
      final Future<void> starting = reader.start('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await reader.stop();
      expect(reader.isWatching, isFalse);
      gate.complete();
      await starting;
      expect(reader.isWatching, isFalse);
      await reader.dispose();
    });
  });

  group('A6.11 TaskList folding', () {
    test('multi-task items sort newest-first', () {
      final tasks = TaskList();
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_started',
          receivedAt: DateTime(2026, 1, 1, 0, 0, 1),
          taskId: 'a',
          text: 'first',
        ),
      );
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_started',
          receivedAt: DateTime(2026, 1, 1, 0, 0, 3),
          taskId: 'c',
          text: 'third',
        ),
      );
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_started',
          receivedAt: DateTime(2026, 1, 1, 0, 0, 2),
          taskId: 'b',
          text: 'second',
        ),
      );
      expect(tasks.items.map((t) => t.id).toList(), <String>['c', 'b', 'a']);
    });

    test('clear() empties the list and the running count', () {
      final tasks = TaskList()
        ..setQueued('a', 'one')
        ..setQueued('b', 'two');
      expect(tasks.runningCount, 2);
      tasks.clear();
      expect(tasks.items, isEmpty);
      expect(tasks.runningCount, 0);
    });

    test('unknown-task tool_call creates a phantom RUNNING entry', () {
      final tasks = TaskList();
      tasks.applyEvent(
        BuddyEvent(
          type: 'tool_call',
          receivedAt: DateTime.now(),
          taskId: 'ghost',
          tool: 'web_search',
        ),
      );
      expect(tasks.items, hasLength(1));
      expect(tasks.items.single.status, TaskStatus.running);
      expect(tasks.items.single.title, 'web_search');

      tasks.applyEvent(
        BuddyEvent(
          type: 'tool_call',
          receivedAt: DateTime.now(),
          taskId: 'nameless',
        ),
      );
      expect(tasks.byId('nameless')?.title, 'nameless');
    });

    test('task_started overwrites the queued title', () {
      final tasks = TaskList()..setQueued('t', 'old title');
      expect(tasks.byId('t')?.title, 'old title');
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_started',
          receivedAt: DateTime.now(),
          taskId: 't',
          text: 'new title',
        ),
      );
      expect(tasks.byId('t')?.title, 'new title');
      expect(tasks.byId('t')?.status, TaskStatus.running);
    });
  });

  group('A6.12 SecureStore', () {
    test('pairing round-trips trimmed, missing reads null', () async {
      final store = SecureStore(storage: _MemoryStorage());
      expect(await store.readPairing(), isNull);
      await store.savePairing(host: '  192.168.1.10  ', token: '  tok123  ');
      final pairing = await store.readPairing();
      expect(pairing?.host, '192.168.1.10');
      expect(pairing?.token, 'tok123');
    });

    test('cert fingerprint + bt id round-trip; blank deletes the key',
        () async {
      final store = SecureStore(storage: _MemoryStorage());
      expect(await store.readCertFingerprint(), isNull);
      expect(await store.readBtDeviceId(), isNull);
      await store.saveCertFingerprint('  ABC123  ');
      expect(await store.readCertFingerprint(), 'ABC123');
      await store.saveBtDeviceId('AA:BB:CC:DD:EE:FF');
      expect(await store.readBtDeviceId(), 'AA:BB:CC:DD:EE:FF');
      await store.saveCertFingerprint('   ');
      expect(await store.readCertFingerprint(), isNull);
      await store.saveBtDeviceId('');
      expect(await store.readBtDeviceId(), isNull);
    });

    test('clear() wipes every key', () async {
      final store = SecureStore(storage: _MemoryStorage());
      await store.savePairing(host: 'h', token: 'tok12345');
      await store.saveCertFingerprint('fp');
      await store.saveBtDeviceId('bt');
      await store.clear();
      expect(await store.readPairing(), isNull);
      expect(await store.readCertFingerprint(), isNull);
      expect(await store.readBtDeviceId(), isNull);
    });
  });

  group('A6.13 theme tokens match DESIGN.md', () {
    test('palette hexes (base hues unchanged)', () {
      expect(BuddyColors.primary, const Color(0xFF1E5F4A));
      expect(BuddyColors.baseDark, const Color(0xFF12131A));
      expect(BuddyColors.baseLight, const Color(0xFFF5F4F0));
      expect(BuddyColors.accent, const Color(0xFFE8A33D));
      expect(BuddyColors.success, const Color(0xFF3A8B5C));
      expect(BuddyColors.warning, const Color(0xFFD9932A));
      expect(BuddyColors.error, const Color(0xFFC4453D));
    });

    test('spacing scale membership (4/8/12/16/24/32/48/64)', () {
      expect(
        <double>[
          BuddySpacing.s1,
          BuddySpacing.s2,
          BuddySpacing.s3,
          BuddySpacing.s4,
          BuddySpacing.s5,
          BuddySpacing.s6,
          BuddySpacing.s7,
          BuddySpacing.s8,
        ],
        <double>[4, 8, 12, 16, 24, 32, 48, 64],
      );
    });

    test('radii are 8 interactive / 12 containers only', () {
      expect(BuddyRadii.interactive, 8);
      expect(BuddyRadii.container, 12);
    });
  });

  group('C1 design-system integrity (DESIGN.md contract)', () {
    test('accessible OnLight/OnDark variants match DESIGN.md hexes', () {
      expect(BuddyColors.warningOnLight, const Color(0xFF8A5A12));
      expect(BuddyColors.warningOnDark, const Color(0xFFE1A955));
      expect(BuddyColors.successOnLight, const Color(0xFF2E6F4A));
      expect(BuddyColors.successOnDark, const Color(0xFF4E976C));
      expect(BuddyColors.errorOnLight, const Color(0xFFB03E37));
      expect(BuddyColors.errorOnDark, const Color(0xFFD06A64));
      expect(BuddyColors.outlineOnDark, const Color(0xFF6E6F7A));
    });

    test('font families resolve to DESIGN.md choices with Roboto fallback '
        '(fails if google_fonts is re-added)', () {
      expect(BuddyTheme.headlineFamily, 'Space Grotesk');
      expect(BuddyTheme.bodyFamily, 'IBM Plex Sans');
      expect(BuddyTheme.monoFamily, 'JetBrains Mono');
      expect(BuddyTheme.fallbackFamily, 'Roboto');
      final ThemeData light = BuddyTheme.light();
      final ThemeData dark = BuddyTheme.dark();
      // Headlines prefer Space Grotesk, body prefers IBM Plex Sans.
      expect(light.textTheme.headlineSmall?.fontFamily, 'Space Grotesk');
      expect(light.textTheme.titleLarge?.fontFamily, 'Space Grotesk');
      expect(light.textTheme.bodyLarge?.fontFamily, 'IBM Plex Sans');
      expect(light.textTheme.bodySmall?.fontFamily, 'IBM Plex Sans');
      expect(light.textTheme.labelLarge?.fontFamily, 'IBM Plex Sans');
      expect(dark.textTheme.headlineSmall?.fontFamily, 'Space Grotesk');
      expect(dark.textTheme.bodyMedium?.fontFamily, 'IBM Plex Sans');
      // Every text style degrades to Roboto explicitly (no CDN).
      for (final TextStyle? s in <TextStyle?>[
        light.textTheme.headlineSmall,
        light.textTheme.titleLarge,
        light.textTheme.titleMedium,
        light.textTheme.bodyLarge,
        light.textTheme.bodyMedium,
        light.textTheme.bodySmall,
        light.textTheme.labelLarge,
      ]) {
        expect(s?.fontFamilyFallback, contains('Roboto'));
      }
      // Mono helper prefers JetBrains Mono with the same fallback.
      final TextStyle mono = BuddyTheme.mono(const Color(0xFF000000));
      expect(mono.fontFamily, 'JetBrains Mono');
      expect(mono.fontFamilyFallback, contains('Roboto'));
    });

    test('M3 ColorScheme is complete — no Material-default purple leaks', () {
      const List<Color> purples = <Color>[
        Color(0xFF6750A4),
        Color(0xFF625B71),
        Color(0xFF7D5260),
        Color(0xFFB3261E),
        Color(0xFF6200EE),
        Color(0xFF03DAC6),
        Color(0xFFBB86FC),
        Color(0xFFCF6679),
      ];
      final ThemeData light = BuddyTheme.light();
      final ThemeData dark = BuddyTheme.dark();
      for (final ColorScheme scheme in <ColorScheme>[
        light.colorScheme,
        dark.colorScheme,
      ]) {
        for (final Color c in <Color>[
          scheme.primary,
          scheme.onPrimary,
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
          scheme.secondary,
          scheme.onSecondary,
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
          scheme.tertiary,
          scheme.onTertiary,
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
          scheme.error,
          scheme.onError,
          scheme.errorContainer,
          scheme.onErrorContainer,
          scheme.surface,
          scheme.onSurface,
          scheme.surfaceContainerLowest,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
          scheme.outline,
          scheme.outlineVariant,
          scheme.inverseSurface,
          scheme.onInverseSurface,
          scheme.inversePrimary,
        ]) {
          expect(purples, isNot(contains(c)), reason: 'leaked $c');
        }
      }
      // Error slots use the accessible variants per brightness.
      expect(light.colorScheme.error, BuddyColors.errorOnLight);
      expect(dark.colorScheme.error, BuddyColors.errorOnDark);
      expect(light.colorScheme.outlineVariant, BuddyColors.hairlineOnLight);
      expect(dark.colorScheme.outline, BuddyColors.outlineOnDark);
      expect(dark.colorScheme.outlineVariant, BuddyColors.hairlineOnDark);
      expect(light.colorScheme.onSurfaceVariant, BuddyColors.inkMutedOnLight);
      expect(dark.colorScheme.onSurfaceVariant, BuddyColors.inkMutedOnDark);
    });

    testWidgets('NavigationBar present with 4 destinations, 8px indicator, '
        'no M2 bar', (WidgetTester tester) async {
      await tester.pumpWidget(BuddyApp(store: _FakeBootStore()));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsNothing);
      for (final label in <String>['Pair', 'Chat', 'Tasks', 'Screen']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // Indicator shape comes from the token scale (8px interactive).
      final ThemeData light = BuddyTheme.light();
      final ShapeBorder? shape =
          light.navigationBarTheme.indicatorShape;
      expect(shape, isA<RoundedRectangleBorder>());
      final RoundedRectangleBorder rounded = shape! as RoundedRectangleBorder;
      expect(rounded.borderRadius, const BorderRadius.all(Radius.circular(8)));
      expect(tester.takeException(), isNull);
    });
  });
}
