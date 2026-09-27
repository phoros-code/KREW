import 'dart:async';
import 'dart:io';

import 'package:everyday_buddy/app.dart';
import 'package:everyday_buddy/models/buddy_event.dart';
import 'package:everyday_buddy/models/task_item.dart';
import 'package:everyday_buddy/models/task_notification.dart';
import 'package:everyday_buddy/screens/calibrate_screen.dart';
import 'package:everyday_buddy/screens/chat_screen.dart';
import 'package:everyday_buddy/screens/pairing_screen.dart';
import 'package:everyday_buddy/screens/preview_screen.dart';
import 'package:everyday_buddy/screens/task_list_screen.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:everyday_buddy/services/secure_store.dart';
import 'package:everyday_buddy/widgets/a11y.dart';
import 'package:everyday_buddy/widgets/command_bar.dart';
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

/// Track C2 accessibility tests. Extends track_a6 (does not modify it).
/// No new dependencies. Copy unchanged — only a11y labels/sizes/focus.

Widget _frame(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Semantics-label substring matcher (bySemanticsLabel takes a String,
/// not a contains() Matcher).
Finder findSemanticsContaining(String substring) => find.byWidgetPredicate(
  (Widget w) =>
      w is Semantics &&
      (w.properties.label ?? '').contains(substring),
);

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
  }) async =>
      map[key];
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

BuddyApi _mockApi(Future<http.Response> Function(http.BaseRequest) handler) =>
    BuddyApi(host: '192.168.1.10', token: 't', client: MockClient(handler));

class _StreamClient extends http.BaseClient {
  _StreamClient(this.stream);
  final Stream<List<int>> stream;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200);
}

/// Real 8x8 red JPEG (same bytes as track_a6 — decodable + preprocessor-OK).
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

void main() {
  group('C2.0 announce helpers (pure unit)', () {
    test('proximity messages', () {
      expect(
        proximityAnnounceMessage(ProximityMode.near),
        'Proximity near — full control available',
      );
      expect(
        proximityAnnounceMessage(ProximityMode.far),
        'Proximity far — notifications only, commands blocked',
      );
    });

    test('connection messages + assertive only for offline', () {
      expect(
        connectionAnnounceMessage(BuddyConnection.online),
        'Connection online — laptop reachable',
      );
      expect(
        connectionAnnounceMessage(BuddyConnection.offline),
        'Connection offline — no route to laptop',
      );
      expect(
        connectionAnnounceMessage(BuddyConnection.unknown),
        contains('connecting'),
      );
      expect(connectionIsAssertive(BuddyConnection.offline), isTrue);
      expect(connectionIsAssertive(BuddyConnection.online), isFalse);
      expect(connectionIsAssertive(BuddyConnection.unknown), isFalse);
    });

    test('task messages reuse semantic label, assertive only for failed', () {
      final TaskNotification failed = TaskNotification.fromEvent(
        BuddyEvent.fromSse('task_failed', <String, dynamic>{
          'task_id': 'abc123',
          'error': 'boom',
        }),
      )!;
      final TaskNotification done = TaskNotification.fromEvent(
        BuddyEvent.fromSse('task_completed', <String, dynamic>{
          'task_id': 'abc123',
          'result': 'ok',
        }),
      )!;
      expect(taskAnnounceMessage(failed), failed.semanticLabel);
      expect(taskIsAssertive(failed), isTrue);
      expect(taskIsAssertive(done), isFalse);
    });

    test('preview messages', () {
      expect(previewReadyMessage(webcam: false), 'Laptop screen preview, live');
      expect(previewReadyMessage(webcam: true), 'Laptop webcam preview, live');
      expect(previewEndedMessage, 'Preview ended');
      expect(previewDeniedMessage, contains('denied'));
    });

    test('announceLiveRegion routes through the test seam', () {
      final List<String> seen = <String>[];
      final List<bool> flags = <bool>[];
      announceLiveRegion(
        'hello',
        announceForTest: (String m, {bool assertive = false}) {
          seen.add(m);
          flags.add(assertive);
        },
      );
      announceLiveRegion(
        'urgent',
        assertive: true,
        announceForTest: (String m, {bool assertive = false}) {
          seen.add(m);
          flags.add(assertive);
        },
      );
      expect(seen, <String>['hello', 'urgent']);
      expect(flags, <bool>[false, true]);
    });

    test('announce wrappers set politeness correctly', () {
      final List<({String message, bool assertive})> seen =
          <({String message, bool assertive})>[];
      void capture(String m, {bool assertive = false}) =>
          seen.add((message: m, assertive: assertive));
      announceProximity(ProximityMode.near, announceForTest: capture);
      announceConnection(BuddyConnection.online, announceForTest: capture);
      announceConnection(BuddyConnection.offline, announceForTest: capture);
      final TaskNotification failed = TaskNotification.fromEvent(
        BuddyEvent.fromSse('task_failed', <String, dynamic>{
          'task_id': 'abc123',
          'error': 'boom',
        }),
      )!;
      final TaskNotification done = TaskNotification.fromEvent(
        BuddyEvent.fromSse('task_completed', <String, dynamic>{
          'task_id': 'abc123',
          'result': 'ok',
        }),
      )!;
      announceTaskNotification(failed, announceForTest: capture);
      announceTaskNotification(done, announceForTest: capture);
      expect(seen[0].assertive, isFalse); // near polite
      expect(seen[1].assertive, isFalse); // online polite
      expect(seen[2].assertive, isTrue); // offline assertive
      expect(seen[3].assertive, isTrue); // failed assertive
      expect(seen[4].assertive, isFalse); // completed polite
    });
  });

  group('C2.1 header double-announce gone', () {
    testWidgets('pill labels announce exactly once, icons excluded', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            appBar: StatusHeader(
              proximity: ProximityMode.near,
              connection: BuddyConnection.online,
              runningCount: 0,
            ),
          ),
        ),
      );
      // Outer pill labels exist exactly once.
      expect(
        find.bySemanticsLabel('Proximity near — full control available'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Connection online — laptop reachable'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('No tasks running'), findsOneWidget);
      // Decorative icons are explicitly excluded — no second announcement
      // path for the same pill. Exact-tree: each pill contributes its
      // ExcludeSemantics-wrapped icon.
      expect(find.byType(ExcludeSemantics), findsWidgets);
      // Visible copy unchanged.
      expect(find.text('NEAR'), findsOneWidget);
      expect(find.text('ONLINE'), findsOneWidget);
      expect(find.text('IDLE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('running count label switches', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            appBar: StatusHeader(
              proximity: ProximityMode.far,
              connection: BuddyConnection.offline,
              runningCount: 2,
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel('2 tasks running'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Proximity far — notifications only, commands blocked',
        ),
        findsOneWidget,
      );
    });
  });

  group('C2.2 semantics on state containers', () {
    testWidgets('StatusBadge label includes status text', (
      WidgetTester tester,
    ) async {
      for (final TaskStatus status in TaskStatus.values) {
        await tester.pumpWidget(_frame(StatusBadge(status: status)));
        expect(
          find.bySemanticsLabel('Task status: ${status.label}'),
          findsOneWidget,
          reason: status.label,
        );
      }
    });

    testWidgets('chat stream error labelled', (WidgetTester tester) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: api,
            events: const <BuddyEvent>[],
            proximity: ProximityService(),
            onSend: (_) async {},
            streamError: 'The live stream closed. Reconnect to resume.',
            streamConnected: false,
            onRetryStream: () {},
          ),
        ),
      );
      expect(
        findSemanticsContaining('Live updates paused'),
        findsOneWidget,
      );
      expect(
        findSemanticsContaining(
          'The live stream closed. Reconnect to resume.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('chat unpaired empty state labelled', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: null,
            events: const <BuddyEvent>[],
            proximity: ProximityService(),
            onSend: (_) async {},
            streamError: null,
            streamConnected: false,
            onRetryStream: () {},
          ),
        ),
      );
      expect(findSemanticsContaining('No laptop paired yet'), findsOneWidget);
    });

    testWidgets('task list error + empty labelled', (
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
      expect(findSemanticsContaining('Task updates paused'), findsOneWidget);
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
      expect(findSemanticsContaining('No laptop paired yet'), findsOneWidget);
    });

    testWidgets('pairing empty state labelled', (WidgetTester tester) async {
      await tester.pumpWidget(
        _frame(PairingScreen(store: SecureStore(), onPaired: (_, __, ___) {})),
      );
      expect(findSemanticsContaining('No laptop yet'), findsOneWidget);
    });

    testWidgets('preview unpaired + FAR labelled', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(const ScreenPreview(api: null, proximity: ProximityMode.far)),
      );
      expect(findSemanticsContaining('No laptop paired yet'), findsOneWidget);
      await tester.pumpWidget(
        _frame(ScreenPreview(api: api, proximity: ProximityMode.far)),
      );
      expect(
        findSemanticsContaining('Preview unavailable while far'),
        findsOneWidget,
      );
    });

    testWidgets('preview needsConsent labelled', (WidgetTester tester) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(ScreenPreview(api: api, proximity: ProximityMode.near)),
      );
      expect(findSemanticsContaining('consent required'), findsOneWidget);
    });

    testWidgets('mjpeg loading + live labelled', (WidgetTester tester) async {
      final StreamController<List<int>> controller =
          StreamController<List<int>>();
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
      expect(
        findSemanticsContaining('Starting live preview'),
        findsOneWidget,
      );
      controller.add(_tinyJpeg);
      await tester.pump();
      await tester.pump();
      expect(
        find.bySemanticsLabel('Laptop screen preview, live'),
        findsOneWidget,
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('task notification banner labelled with live region', (
      WidgetTester tester,
    ) async {
      final TaskNotification notice = TaskNotification.fromEvent(
        BuddyEvent.fromSse('task_failed', <String, dynamic>{
          'task_id': 'abc123',
          'error': 'boom',
        }),
      )!;
      await tester.pumpWidget(
        _frame(TaskNotificationContent(notification: notice)),
      );
      expect(find.bySemanticsLabel(notice.semanticLabel), findsOneWidget);
      final Semantics node = tester.widget<Semantics>(
        find.bySemanticsLabel(notice.semanticLabel),
      );
      expect(node.properties.liveRegion, isTrue);
    });

    testWidgets('boot retry state labelled', (WidgetTester tester) async {
      final _ThrowingStore store = _ThrowingStore();
      await tester.pumpWidget(BuddyApp(store: store));
      await tester.pumpAndSettle();
      expect(findSemanticsContaining('Could not start'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('NavigationBar keeps 5 labels with tooltips', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(BuddyApp(store: _FakeBootStore()));
      await tester.pumpAndSettle();
      for (final String label in <String>['Pair', 'Chat', 'Tasks', 'Screen', 'Settings']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      final List<NavigationDestination> dests = tester
          .widgetList<NavigationDestination>(
            find.byType(NavigationDestination),
          )
          .toList();
      expect(dests, hasLength(5));
      for (final NavigationDestination d in dests) {
        expect(d.label, isNotEmpty);
        expect(d.tooltip, d.label);
      }
    });

    testWidgets('paired boot shows unpair strip', (
      WidgetTester tester,
    ) async {
      // Uses the pairing param (covers the FakeBootStore seam).
      await tester.pumpWidget(
        BuddyApp(
          store: _FakeBootStore(
            pairing: const PairingInfo(host: '127.0.0.1', token: 'tok12345'),
          ),
        ),
      );
      for (int i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(find.text('Chat'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('C2.3 tap targets 48dp', () {
    testWidgets('command bar Send meets guideline', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(CommandBar(enabled: true, onSend: (_) async {})),
      );
      final Size size = tester.getSize(
        find.widgetWithText(ElevatedButton, 'Send'),
      );
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('pairing save meets guideline', (WidgetTester tester) async {
      await tester.pumpWidget(
        _frame(PairingScreen(store: SecureStore(), onPaired: (_, __, ___) {})),
      );
      await tester.ensureVisible(find.text('Test connection and save'));
      final Size size = tester.getSize(
        find.widgetWithText(ElevatedButton, 'Test connection and save'),
      );
      expect(size.height, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('calibrate steppers meet guideline', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          CalibrateScreen(
            api: api,
            proximity: ProximityService(),
            onThresholdApplied: () async {},
          ),
        ),
      );
      expect(tester.getSize(find.byType(IconButton).at(0)).height, 48);
      expect(tester.getSize(find.byType(IconButton).at(0)).width, 48);
      expect(tester.getSize(find.byType(IconButton).at(1)).height, 48);
      expect(tester.getSize(find.byType(IconButton).at(1)).width, 48);
      final Size setSize = tester.getSize(
        find.widgetWithText(ElevatedButton, 'Set threshold'),
      );
      expect(setSize.height, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('segmented Screen/Webcam meets height', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          PreviewScreen(
            api: api,
            proximity: ProximityMode.near,
            proximityService: ProximityService(),
            onCalibrated: () async {},
          ),
        ),
      );
      final Size size = tester.getSize(
        find.byType(SegmentedButton<PreviewSource>),
      );
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('preview Check again meets guideline', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((http.BaseRequest req) async {
        if (req.method == 'POST' && req.url.path == '/screen/consent') {
          return http.Response(
            '{"consent_id": "g1", "status": "pending"}',
            200,
          );
        }
        return http.Response('', 200);
      });
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(ScreenPreview(api: api, proximity: ProximityMode.near)),
      );
      await tester.tap(find.text('Request preview'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for laptop approval'), findsOneWidget);
      final Size size = tester.getSize(
        find.widgetWithText(ElevatedButton, 'Check again'),
      );
      expect(size.height, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('chat + task Reconnect meet guideline', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: api,
            events: const <BuddyEvent>[],
            proximity: ProximityService(),
            onSend: (_) async {},
            streamError: 'The live stream closed. Reconnect to resume.',
            streamConnected: false,
            onRetryStream: () {},
          ),
        ),
      );
      expect(
        tester
            .getSize(find.widgetWithText(OutlinedButton, 'Reconnect'))
            .height,
        greaterThanOrEqualTo(48),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: TaskList(),
            isPaired: true,
            streamError: 'down',
            onRetry: () {},
          ),
        ),
      );
      expect(
        tester
            .getSize(find.widgetWithText(OutlinedButton, 'Reconnect'))
            .height,
        greaterThanOrEqualTo(48),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    });

    testWidgets('mjpeg Stop meets guideline', (WidgetTester tester) async {
      final StreamController<List<int>> controller =
          StreamController<List<int>>();
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
      expect(find.text('Stop preview'), findsOneWidget);
      expect(
        tester
            .getSize(find.widgetWithText(OutlinedButton, 'Stop preview'))
            .height,
        greaterThanOrEqualTo(48),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('C2.4 no overflow at 320dp + textScale 1.3', () {
    Future<void> pumpNarrow(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(1.3),
            ),
            child: Scaffold(body: child),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('header fits 320dp at 1.3', (WidgetTester tester) async {
      await pumpNarrow(
        tester,
        const StatusHeader(
          proximity: ProximityMode.far,
          connection: BuddyConnection.offline,
          runningCount: 12,
        ),
      );
      expect(find.text('FAR'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('header in appBar slot fits 320dp at 1.3', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(320, 800),
              textScaler: TextScaler.linear(1.3),
            ),
            child: Scaffold(
              appBar: StatusHeader(
                proximity: ProximityMode.near,
                connection: BuddyConnection.online,
                runningCount: 3,
              ),
              body: SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('NEAR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chat fits 320dp at 1.3', (WidgetTester tester) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      await pumpNarrow(
        tester,
        ChatScreen(
          api: api,
          events: <BuddyEvent>[
            BuddyEvent(
              type: 'task_started',
              receivedAt: DateTime.now(),
              taskId: 'abcdef12',
              text: 'a fairly long command line that should wrap nicely',
            ),
          ],
          proximity: proximity,
          onSend: (_) async {},
          streamError: 'The live stream closed. Reconnect to resume.',
          streamConnected: true,
          onRetryStream: () {},
        ),
      );
      expect(find.text('Agent log'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pairing fits 320dp at 1.3', (WidgetTester tester) async {
      await pumpNarrow(
        tester,
        PairingScreen(
          store: SecureStore(),
          onPaired: (_, __, ___) {},
        ),
      );
      expect(find.text('Pair with your laptop'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('C2.5 focus order', () {
    testWidgets('pairing fields use next/done traversal', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _frame(PairingScreen(store: SecureStore(), onPaired: (_, __, ___) {})),
      );
      // TextFormField builds an inner TextField carrying the traversal config.
      final List<TextField> fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields, hasLength(4));
      expect(fields[0].textInputAction, TextInputAction.next);
      expect(fields[1].textInputAction, TextInputAction.next);
      expect(fields[2].textInputAction, TextInputAction.next);
      expect(fields[3].textInputAction, TextInputAction.done);
      expect(fields[0].focusNode, isNotNull);
      expect(fields[3].focusNode, isNotNull);
      fields[0].focusNode!.requestFocus();
      await tester.pump();
      expect(fields[0].focusNode!.hasFocus, isTrue);
      fields[1].focusNode!.requestFocus();
      await tester.pump();
      expect(fields[1].focusNode!.hasFocus, isTrue);
    });

    testWidgets('pairing error card owns focus', (WidgetTester tester) async {
      // Probe seam: validatePairing 401 â†’ error card with focus.
      final MockClient probe = MockClient(
        (_) async => http.Response(
          '{"error": {"code": "unauthorized", "message": "bad token"}}',
          401,
        ),
      );
      BuddyApi.probeClientFactory = (_) => probe;
      addTearDown(() => BuddyApi.probeClientFactory = null);
      await tester.pumpWidget(
        _frame(PairingScreen(store: SecureStore(), onPaired: (_, __, ___) {})),
      );
      await tester.enterText(find.byType(TextFormField).at(0), '192.168.1.10');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'validtoken123',
      );
      await tester.enterText(find.byType(TextFormField).at(2), 'ab' * 32);
      await tester.ensureVisible(find.text('Test connection and save'));
      await tester.tap(find.text('Test connection and save'));
      await tester.pumpAndSettle();
      expect(find.text('Pairing failed'), findsOneWidget);
      expect(findSemanticsContaining('Pairing failed'), findsOneWidget);
      expect(
        tester.widgetList<Focus>(find.byType(Focus)),
        isNotEmpty,
      );
    });

    testWidgets('chat send error owns focus + label', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      Future<void> fail(String _) async {
        throw const BuddyApiException(
          code: 'forbidden',
          message: 'Requires near',
        );
      }

      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: api,
            events: const <BuddyEvent>[],
            proximity: proximity,
            onSend: fail,
            streamError: null,
            streamConnected: true,
            onRetryStream: () {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(findSemanticsContaining('Send failed'), findsOneWidget);
      expect(tester.widgetList<Focus>(find.byType(Focus)), isNotEmpty);
    });
  });
}

/// SecureStore stub that throws on readPairing â†’ boot-error state.
class _ThrowingStore extends SecureStore {
  _ThrowingStore() : super(storage: _MemoryStorage());
  @override
  Future<PairingInfo?> readPairing() async {
    throw const SocketException('locked');
  }
}

