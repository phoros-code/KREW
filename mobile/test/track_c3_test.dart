import 'package:everyday_buddy/app.dart';
import 'package:everyday_buddy/l10n/strings.dart';
import 'package:everyday_buddy/models/buddy_event.dart';
import 'package:everyday_buddy/models/notification_history.dart';
import 'package:everyday_buddy/models/task_item.dart';
import 'package:everyday_buddy/models/task_log.dart';
import 'package:everyday_buddy/models/task_notification.dart';
import 'package:everyday_buddy/screens/chat_screen.dart';
import 'package:everyday_buddy/screens/pairing_screen.dart';
import 'package:everyday_buddy/screens/settings_screen.dart';
import 'package:everyday_buddy/screens/task_detail_screen.dart';
import 'package:everyday_buddy/screens/task_list_screen.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:everyday_buddy/services/secure_store.dart';
import 'package:everyday_buddy/widgets/onboarding_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Track C3 (new surfaces) tests. Follows the track_c2_test.dart patterns
/// (framed widgets, semantics-substring matcher, memory secure storage).

Widget _frame(Widget child) => MaterialApp(home: Scaffold(body: child));

Finder findSemanticsContaining(String substring) => find.byWidgetPredicate(
  (Widget w) =>
      w is Semantics && (w.properties.label ?? '').contains(substring),
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

/// Fake app-shell store with pairing + onboarding control.
class _FakeC3Store extends SecureStore {
  _FakeC3Store({this.pairing, this.seen = true}) : super(storage: _MemoryStorage());
  final PairingInfo? pairing;
  final bool seen;
  bool seenSaved = false;
  @override
  Future<PairingInfo?> readPairing() async => pairing;
  @override
  Future<String?> readBtDeviceId() async => 'AA:BB:CC:DD:EE:FF';
  @override
  Future<String?> readCertFingerprint() async => null;
  @override
  Future<String?> readPairedOn() async =>
      pairing == null ? null : '2026-09-27T10:00:00.000';
  @override
  Future<bool> readNotificationsEnabled() async => true;
  @override
  Future<bool> readOnboardingSeen() async => seen || seenSaved;
  @override
  Future<void> saveOnboardingSeen() async {
    seenSaved = true;
  }
}

BuddyApi _mockApi(Future<http.Response> Function(http.BaseRequest) handler) =>
    BuddyApi(host: '192.168.1.10', token: 't', client: MockClient(handler));

TaskNotification _notice(String id, String kind) {
  final String type = kind == 'done'
      ? 'task_completed'
      : kind == 'failed'
      ? 'task_failed'
      : 'task_started';
  final Map<String, dynamic> data = <String, dynamic>{'task_id': id};
  if (kind == 'done') {
    data['result'] = 'result for $id';
  } else if (kind == 'failed') {
    data['error'] = 'error for $id';
  } else {
    data['text'] = 'run $id';
  }
  return TaskNotification.fromEvent(BuddyEvent.fromSse(type, data))!;
}

void main() {
  group('C3.0 strings table', () {
    test('no empty values', () {
      expect(AppStrings.all, isNotEmpty);
      for (final String s in AppStrings.all) {
        expect(s.trim(), isNotEmpty, reason: 'empty string in AppStrings.all');
      }
    });

    test('tab labels match the nav contract', () {
      expect(AppStrings.tabPair, 'Pair');
      expect(AppStrings.tabChat, 'Chat');
      expect(AppStrings.tabTasks, 'Tasks');
      expect(AppStrings.tabScreen, 'Screen');
      expect(AppStrings.tabSettings, 'Settings');
    });
  });

  group('C3.1 settings tab + unpair flow', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'buddy',
        packageName: 'com.everydaybuddy',
        version: '0.2.0',
        buildNumber: '1',
        buildSignature: '',
      );
    });

    testWidgets('settings renders all five sections', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      bool toggled = false;
      await tester.pumpWidget(
        _frame(
          SettingsScreen(
            api: api,
            host: '192.168.1.10',
            pairedOn: '2026-09-27T10:00:00.000',
            btDeviceId: 'AA:BB:CC:DD:EE:FF',
            threshold: -60,
            notificationsEnabled: true,
            onNotificationsChanged: (_) => toggled = true,
            onClearBt: () {},
            onUnpair: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.settingsTitle), findsOneWidget);
      expect(find.text(AppStrings.settingsPairingSection), findsOneWidget);
      expect(find.text(AppStrings.settingsBtSection), findsOneWidget);
      expect(find.text(AppStrings.settingsThresholdSection), findsOneWidget);
      expect(
        find.text(AppStrings.settingsNotificationsSection),
        findsOneWidget,
      );
      expect(find.text(AppStrings.settingsAboutSection), findsOneWidget);
      // Pairing status row shows host + paired-on.
      expect(find.textContaining('192.168.1.10'), findsOneWidget);
      expect(find.textContaining('2026-09-27'), findsOneWidget);
      // Threshold is a compact read with the Screen-tab note.
      expect(find.textContaining('-60 dBm'), findsWidgets);
      expect(find.text(AppStrings.settingsThresholdNote), findsOneWidget);
      // Toggle flips through the callback.
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(toggled, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('settings test connection surfaces failures', (
      WidgetTester tester,
    ) async {
      // NOTE: the 200-success probe path (listen+cancel on the probe
      // stream) stalls under FakeAsync — success is covered by the plain
      // unit test below instead. The 401 path (bytesToString) completes
      // fine in widget tests (same seam as track_c2).
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      BuddyApi.probeClientFactory = (_) => MockClient(
        (_) async => http.Response(
          '{"error": {"code": "unauthorized", "message": "bad token"}}',
          401,
        ),
      );
      addTearDown(() => BuddyApi.probeClientFactory = null);
      await tester.pumpWidget(
        _frame(
          SettingsScreen(
            api: api,
            host: '192.168.1.10',
            pairedOn: null,
            btDeviceId: null,
            threshold: -60,
            notificationsEnabled: true,
            onNotificationsChanged: (_) {},
            onClearBt: () {},
            onUnpair: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(AppStrings.settingsTestButton));
      await tester.tap(find.text(AppStrings.settingsTestButton));
      await tester.pumpAndSettle();
      // Curated server message surfaces — never the raw payload.
      expect(find.textContaining('bad token'), findsNothing);
      expect(find.textContaining('Wrong token'), findsOneWidget);
    });

    test('validatePairing success path (real async)', () async {
      // Plain unit test (NOT testWidgets): the 200 probe path uses
      // listen+cancel, which stalls under FakeAsync but completes on the
      // real event loop — exactly like production.
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      BuddyApi.probeClientFactory = (_) =>
          MockClient((_) async => http.Response('', 200));
      addTearDown(() => BuddyApi.probeClientFactory = null);
      await api.validatePairing().timeout(const Duration(seconds: 5));
    });

    testWidgets('settings unpair flow confirms then calls back', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      bool unpaired = false;
      await tester.pumpWidget(
        _frame(
          SettingsScreen(
            api: api,
            host: '192.168.1.10',
            pairedOn: null,
            btDeviceId: null,
            threshold: -60,
            notificationsEnabled: true,
            onNotificationsChanged: (_) {},
            onClearBt: () {},
            onUnpair: () => unpaired = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(OutlinedButton, AppStrings.actionUnpair),
      );
      await tester.tap(
        find.widgetWithText(OutlinedButton, AppStrings.actionUnpair),
      );
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.unpairTitle), findsOneWidget);
      expect(find.text(AppStrings.unpairMessage), findsOneWidget);
      await tester.tap(
        find.widgetWithText(TextButton, AppStrings.actionUnpair),
      );
      await tester.pumpAndSettle();
      expect(unpaired, isTrue);
    });

    testWidgets('app has 5 destinations, settings reachable, no strip', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(BuddyApp(store: _FakeC3Store()));
      await tester.pumpAndSettle();
      final Finder navBar = find.byType(NavigationBar);
      expect(navBar, findsOneWidget);
      for (final String label in <String>[
        AppStrings.tabPair,
        AppStrings.tabChat,
        AppStrings.tabTasks,
        AppStrings.tabScreen,
        AppStrings.tabSettings,
      ]) {
        // Scoped to the bar: the Settings screen title duplicates the label.
        expect(
          find.descendant(of: navBar, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      final List<NavigationDestination> dests = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .toList();
      expect(dests, hasLength(5));
      // The old Pair-tab unpair strip is gone — no second unpair path.
      expect(find.text(AppStrings.actionUnpair), findsNothing);
      await tester.tap(
        find.descendant(of: navBar, matching: find.text(AppStrings.tabSettings)),
      );
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.settingsPairingSection), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('C3.2 notification history bounded + clear', () {
    test('bounded to the last 50, newest first', () {
      final NotificationHistory history = NotificationHistory();
      for (int i = 0; i < 55; i++) {
        history.add(_notice('task-$i', 'done'));
      }
      expect(history.length, 50);
      expect(history.items.first.taskId, 'task-54');
      expect(history.items.last.taskId, 'task-5');
    });

    test('clear empties', () {
      final NotificationHistory history = NotificationHistory();
      history.add(_notice('a', 'done'));
      history.add(_notice('b', 'failed'));
      expect(history.isEmpty, isFalse);
      history.clear();
      expect(history.isEmpty, isTrue);
      expect(history.items, isEmpty);
    });

    testWidgets('history section renders rows + clear', (
      WidgetTester tester,
    ) async {
      final List<TaskNotification> notices = <TaskNotification>[
        _notice('abc123', 'done'),
        _notice('def456', 'failed'),
      ];
      bool cleared = false;
      String? opened;
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: TaskList(),
            isPaired: true,
            streamError: null,
            onRetry: () {},
            notifications: notices,
            onClearHistory: () => cleared = true,
            onOpenTask: (String id) => opened = id,
          ),
        ),
      );
      expect(find.text(AppStrings.historyTitle), findsOneWidget);
      expect(find.textContaining('result for abc123'), findsOneWidget);
      expect(find.textContaining('error for def456'), findsOneWidget);
      // Tapping a history row opens the task log.
      await tester.tap(find.textContaining('result for abc123'));
      await tester.pump();
      expect(opened, 'abc123');
      // Clear-history button fires the callback.
      await tester.tap(find.text(AppStrings.historyClear));
      await tester.pump();
      expect(cleared, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty history shows the empty line', (
      WidgetTester tester,
    ) async {
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
      expect(find.text(AppStrings.historyTitle), findsOneWidget);
      expect(find.text(AppStrings.historyEmpty), findsOneWidget);
      // No clear button when there is nothing to clear.
      expect(find.text(AppStrings.historyClear), findsNothing);
    });
  });

  group('C3.3 per-task log view', () {
    test('eventsForTask filters + sorts oldest first', () {
      final DateTime base = DateTime(2026, 9, 27, 10);
      final List<BuddyEvent> events = <BuddyEvent>[
        BuddyEvent(type: 'task_completed', receivedAt: base.add(const Duration(seconds: 3)), taskId: 't1', result: 'r'),
        BuddyEvent(type: 'task_started', receivedAt: base, taskId: 't1', text: 'hi'),
        BuddyEvent(type: 'task_started', receivedAt: base, taskId: 'other', text: 'x'),
        BuddyEvent(type: 'tool_call', receivedAt: base.add(const Duration(seconds: 1)), taskId: 't1', tool: 'shell', args: const <String, dynamic>{'cmd': 'ls'}),
      ];
      final List<BuddyEvent> filtered = eventsForTask(events, 't1');
      expect(filtered.map((BuddyEvent e) => e.type).toList(), <String>[
        'task_started',
        'tool_call',
        'task_completed',
      ]);
    });

    test('redacted args hide secrets, show length+sha', () {
      const Map<String, dynamic> args = <String, dynamic>{
        'cmd': 'cat /home/user/supersecret-token-12345',
      };
      final String summary = redactedArgsSummary(args);
      expect(summary, isNot(contains('supersecret-token-12345')));
      expect(summary, contains('args'));
      expect(summary, contains('sha'));
      expect(redactedArgsSummary(null), 'no args');
      expect(redactedArgsSummary(const <String, dynamic>{}), 'no args');
    });

    testWidgets('task rows show chevron + open the detail', (
      WidgetTester tester,
    ) async {
      final TaskList tasks = TaskList();
      tasks.setQueued('abc123', 'list the home dir');
      String? opened;
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: tasks,
            isPaired: true,
            streamError: null,
            onRetry: () {},
            onOpenTask: (String id) => opened = id,
          ),
        ),
      );
      expect(find.byIcon(Icons.chevron_right), findsWidgets);
      await tester.tap(find.text('list the home dir'));
      await tester.pump();
      expect(opened, 'abc123');
    });

    testWidgets('detail shows full events + copy, no raw args', (
      WidgetTester tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final DateTime base = DateTime(2026, 9, 27, 10);
      final TaskItem task = TaskItem(
        id: 'abc123',
        title: 'list the home dir',
        status: TaskStatus.done,
        updatedAt: base,
        detail: 'file1\nfile2',
      );
      final List<BuddyEvent> events = <BuddyEvent>[
        BuddyEvent(type: 'task_started', receivedAt: base, taskId: 'abc123', text: 'list the home dir'),
        BuddyEvent(
          type: 'tool_call',
          receivedAt: base.add(const Duration(seconds: 1)),
          taskId: 'abc123',
          tool: 'shell',
          args: const <String, dynamic>{'cmd': 'ls supersecret-dir'},
        ),
        BuddyEvent(type: 'task_completed', receivedAt: base.add(const Duration(seconds: 2)), taskId: 'abc123', result: 'file1\nfile2'),
      ];
      await tester.pumpWidget(_frame(TaskDetailScreen(task: task, events: events)));
      expect(find.text(AppStrings.taskDetailTitle), findsOneWidget);
      expect(find.text('Tool: shell'), findsOneWidget);
      // Redacted: secret arg value never renders, length+sha does.
      expect(find.textContaining('supersecret-dir'), findsNothing);
      expect(find.textContaining('sha'), findsOneWidget);
      // Full result renders (not the 2-line preview).
      expect(find.textContaining('file1'), findsWidgets);
      // Tap-to-copy confirms.
      await tester.tap(find.text(AppStrings.taskDetailCopy).first);
      await tester.pump();
      expect(find.text(AppStrings.taskDetailCopied), findsOneWidget);
      // Close pops.
      expect(find.text(AppStrings.actionClose), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('C3.4 onboarding shows once + skip', () {
    testWidgets('overlay pages + skip calls back', (
      WidgetTester tester,
    ) async {
      bool done = false;
      await tester.pumpWidget(
        _frame(OnboardingOverlay(onDone: () => done = true)),
      );
      expect(find.text(AppStrings.onboardingTrustTitle), findsOneWidget);
      expect(find.text(AppStrings.onboardingSkip), findsOneWidget);
      await tester.tap(find.text(AppStrings.onboardingSkip));
      await tester.pump();
      expect(done, isTrue);
    });

    testWidgets('paired boot shows tour once, skip persists', (
      WidgetTester tester,
    ) async {
      final _FakeC3Store store = _FakeC3Store(
        pairing: const PairingInfo(host: '127.0.0.1', token: 'tok12345'),
        seen: false,
      );
      await tester.pumpWidget(BuddyApp(store: store));
      for (int i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(find.text(AppStrings.onboardingTrustTitle), findsOneWidget);
      await tester.tap(find.text(AppStrings.onboardingSkip));
      for (int i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(find.text(AppStrings.onboardingTrustTitle), findsNothing);
      expect(store.seenSaved, isTrue);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });

    testWidgets('seen tour never shows', (WidgetTester tester) async {
      await tester.pumpWidget(
        BuddyApp(
          store: _FakeC3Store(
            pairing: const PairingInfo(host: '127.0.0.1', token: 'tok12345'),
          ),
        ),
      );
      for (int i = 0; i < 5; i++) {
        await tester.pump();
      }
      expect(find.text(AppStrings.onboardingTrustTitle), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('C3.5 pull-to-refresh triggers reconnect', () {
    testWidgets('chat refresh calls back', (WidgetTester tester) async {
      bool refreshed = false;
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
            onRefresh: () async {
              refreshed = true;
            },
          ),
        ),
      );
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(refreshed, isTrue);
    });

    testWidgets('task list refresh calls back', (WidgetTester tester) async {
      bool refreshed = false;
      await tester.pumpWidget(
        _frame(
          TaskListScreen(
            tasks: TaskList(),
            isPaired: true,
            streamError: null,
            onRetry: () {},
            onRefresh: () async {
              refreshed = true;
            },
          ),
        ),
      );
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();
      expect(refreshed, isTrue);
    });
  });

  group('C3.7 curated pairing errors', () {
    test('curated mapping per code, no raw payloads', () {
      expect(
        curatedPairingMessage(
          const BuddyApiException(code: 'unauthorized', message: 'bad token'),
        ),
        AppStrings.pairErrorUnauthorized,
      );
      expect(
        curatedPairingMessage(
          const BuddyApiException(code: 'token_expired', message: 'old'),
        ),
        AppStrings.pairErrorTokenExpired,
      );
      expect(
        curatedPairingMessage(
          const BuddyApiException(code: 'locked_out', message: 'x'),
        ),
        AppStrings.pairErrorLockedOut,
      );
      expect(
        curatedPairingMessage(
          const BuddyApiException(code: 'forbidden', message: 'x'),
        ),
        AppStrings.pairErrorForbidden,
      );
      // Unreachable envelopes are already curated (route vs cert).
      expect(
        curatedPairingMessage(BuddyApi.routeError),
        BuddyApi.routeError.message,
      );
      // Unknown codes fall back to generic curated copy — and never echo
      // the raw server message.
      expect(
        curatedPairingMessage(
          const BuddyApiException(code: 'weird_code', message: 'raw blob'),
        ),
        AppStrings.pairErrorGeneric,
      );
      expect(
        curatedPairingMessage(
          const BuddyApiException(code: 'weird_code', message: 'raw blob'),
        ),
        isNot(contains('raw blob')),
      );
      // No curated value leaks a "laptop said" interpolation.
      for (final String s in <String>[
        AppStrings.pairErrorUnauthorized,
        AppStrings.pairErrorTokenExpired,
        AppStrings.pairErrorLockedOut,
        AppStrings.pairErrorForbidden,
        AppStrings.pairErrorGeneric,
      ]) {
        expect(s, isNot(contains('laptop said')));
      }
    });

    testWidgets('raw code hidden until Details opens', (
      WidgetTester tester,
    ) async {
      // NOTE: PairingScreen builds its own pinned client, so checkHealth
      // hits real sockets here. 127.0.0.1:1 refuses instantly (loopback
      // RST) — and even a listener would fail TLS → still an error card
      // with the code behind Details. checkHealth caps at 10s regardless.
      await tester.pumpWidget(
        _frame(PairingScreen(store: SecureStore(), onPaired: (_, __, ___) {})),
      );
      await tester.enterText(find.byType(TextFormField).at(0), '127.0.0.1:1');
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'validtoken123',
      );
      await tester.enterText(find.byType(TextFormField).at(2), 'ab' * 32);
      await tester.ensureVisible(find.text(AppStrings.pairSaveButton));
      await tester.tap(find.text(AppStrings.pairSaveButton));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(find.text(AppStrings.pairFailedTitle), findsOneWidget);
      // Raw code hidden until Details opens; no raw JSON ever.
      expect(find.textContaining('unreachable'), findsNothing);
      expect(find.textContaining('{'), findsNothing);
      await tester.ensureVisible(find.text(AppStrings.pairDetailsLabel));
      await tester.tap(find.text(AppStrings.pairDetailsLabel));
      await tester.pumpAndSettle();
      expect(find.textContaining('unreachable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
