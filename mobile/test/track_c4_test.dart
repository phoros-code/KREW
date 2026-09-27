import 'dart:async';

import 'package:everyday_buddy/models/buddy_event.dart';
import 'package:everyday_buddy/models/task_item.dart';
import 'package:everyday_buddy/models/task_notification.dart';
import 'package:everyday_buddy/screens/chat_screen.dart';
import 'package:everyday_buddy/screens/task_detail_screen.dart';
import 'package:everyday_buddy/services/buddy_api.dart';
import 'package:everyday_buddy/services/proximity_service.dart';
import 'package:everyday_buddy/widgets/console_column.dart';
import 'package:everyday_buddy/widgets/mjpeg_player.dart';
import 'package:everyday_buddy/widgets/status_header.dart';
import 'package:everyday_buddy/widgets/task_notification_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Track C4 (performance + motion) tests. No new deps, no visual/copy
/// changes except the pill cross-fade + jump-to-newest pill.

Widget _frame(Widget child) => MaterialApp(home: Scaffold(body: child));

BuddyApi _mockApi(Future<http.Response> Function(http.BaseRequest) handler) =>
    BuddyApi(host: '192.168.1.10', token: 't', client: MockClient(handler));

class _StreamClient extends http.BaseClient {
  _StreamClient(this.stream);
  final Stream<List<int>> stream;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200);
}

/// Real 8x8 red JPEG (same bytes as track_a6/track_c2 — decodable +
/// preprocessor-OK).
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

List<BuddyEvent> _events(int n, {int start = 0}) => List<BuddyEvent>.generate(
  n,
  (int i) => BuddyEvent(
    type: 'task_started',
    receivedAt: DateTime(2026, 9, 27, 10, 0, start + i),
    taskId: 'task-${start + i}',
    text: 'command number ${start + i} with some text to fill a row',
  ),
);

void main() {
  group('C4.1 rebuild scoping: proximity pulse rebuilds header, not log', () {
    testWidgets('BLE pulse updates subtitle+bar, log element identical', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      final List<BuddyEvent> events = _events(3);
      ChatScreen chatOf() => ChatScreen(
        api: api,
        events: events,
        proximity: proximity,
        onSend: (_) async {},
        streamError: null,
        streamConnected: true,
        onRetryStream: () {},
      );
      await tester.pumpWidget(_frame(chatOf()));
      await tester.pump();
      // Live subtitle before the pulse.
      expect(find.textContaining('Live task activity'), findsOneWidget);
      final Element logBefore = tester.element(
        find.textContaining('command number 0'),
      );
      // Pulse: NEAR -> FAR. No parent rebuild — only ListenableBuilders.
      proximity.markFar();
      await tester.pump();
      // Subtitle flipped to FAR copy…
      expect(find.textContaining('FAR mode'), findsWidgets);
      // …but the log row element is the identical object (never rebuilt).
      final Element logAfter = tester.element(
        find.textContaining('command number 0'),
      );
      expect(identical(logBefore, logAfter), isTrue);
      // Bar disabled reason follows too.
      expect(
        find.textContaining('notifications only'),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('C4.2 log virtualization: ListView + follow + jump pill', () {
    testWidgets('chat uses ListView.builder with a ScrollController', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: api,
            events: _events(5),
            proximity: proximity,
            onSend: (_) async {},
            streamError: null,
            streamConnected: true,
            onRetryStream: () {},
          ),
        ),
      );
      await tester.pump();
      final ListView list = tester.widget<ListView>(
        find.byType(ListView).first,
      );
      expect(list.controller, isNotNull);
      // Virtualized: builder delegate, not an eager Column of 200 rows.
      expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
      expect(tester.takeException(), isNull);
    });

    testWidgets('scrolled-away arrivals raise jump pill; tap follows', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      List<BuddyEvent> events = _events(30);
      ChatScreen chatOf() => ChatScreen(
        api: api,
        events: events,
        proximity: proximity,
        onSend: (_) async {},
        streamError: null,
        streamConnected: true,
        onRetryStream: () {},
      );
      await tester.pumpWidget(_frame(chatOf()));
      await tester.pump();
      expect(find.text('Jump to newest'), findsNothing);
      // Scroll away from the newest edge (top).
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pump();
      // New arrivals while scrolled away…
      events = <BuddyEvent>[..._events(2, start: 100), ...events];
      await tester.pumpWidget(_frame(chatOf()));
      await tester.pump();
      expect(find.text('Jump to newest'), findsOneWidget);
      // A11y label present.
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Semantics &&
              (w.properties.label ?? '').contains('jump to newest'),
        ),
        findsOneWidget,
      );
      // Tap jumps to the newest edge and drops the pill.
      await tester.tap(find.text('Jump to newest'));
      await tester.pump();
      expect(find.text('Jump to newest'), findsNothing);
      final ScrollController controller =
          tester.widget<ListView>(find.byType(ListView).first).controller!;
      expect(controller.offset, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('pinned arrivals follow with no pill', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      List<BuddyEvent> events = _events(30);
      ChatScreen chatOf() => ChatScreen(
        api: api,
        events: events,
        proximity: proximity,
        onSend: (_) async {},
        streamError: null,
        streamConnected: true,
        onRetryStream: () {},
      );
      await tester.pumpWidget(_frame(chatOf()));
      await tester.pump();
      // Stay pinned at the newest edge (offset 0)…
      final ScrollController before =
          tester.widget<ListView>(find.byType(ListView).first).controller!;
      expect(before.offset, 0);
      // …new arrivals follow silently.
      events = <BuddyEvent>[..._events(2, start: 200), ...events];
      await tester.pumpWidget(_frame(chatOf()));
      await tester.pump();
      await tester.pump();
      expect(find.text('Jump to newest'), findsNothing);
      final ScrollController after =
          tester.widget<ListView>(find.byType(ListView).first).controller!;
      expect(after.offset, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('task detail uses the same controller pattern', (
      WidgetTester tester,
    ) async {
      final DateTime base = DateTime(2026, 9, 27, 10);
      final TaskItem task = TaskItem(
        id: 'abc123',
        title: 'list the home dir',
        status: TaskStatus.done,
        updatedAt: base,
      );
      final List<BuddyEvent> events = List<BuddyEvent>.generate(
        20,
        (int i) => BuddyEvent(
          type: 'task_completed',
          receivedAt: base.add(Duration(seconds: i)),
          taskId: 'abc123',
          result: 'step $i result payload',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: TaskDetailScreen(task: task, events: events)),
      );
      await tester.pump();
      final ListView list = tester.widget<ListView>(
        find.byType(ListView).first,
      );
      expect(list.controller, isNotNull);
      expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
      expect(find.textContaining('step 0 result'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('C4.3 TaskList pruning: cap 200, oldest-done first, never running', () {
    test('default bound is 200', () {
      expect(TaskList().maxItems, 200);
    });

    test('over budget evicts oldest done first', () {
      final TaskList tasks = TaskList(maxItems: 3);
      final DateTime base = DateTime(2026, 1, 1);
      for (int i = 0; i < 3; i++) {
        tasks.applyEvent(
          BuddyEvent(
            type: 'task_completed',
            receivedAt: base.add(Duration(seconds: i)),
            taskId: 'done-$i',
            result: 'r$i',
          ),
        );
      }
      expect(tasks.items, hasLength(3));
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_completed',
          receivedAt: base.add(const Duration(seconds: 10)),
          taskId: 'done-new',
          result: 'new',
        ),
      );
      final List<String> ids = tasks.items.map((t) => t.id).toList();
      expect(ids, isNot(contains('done-0')));
      expect(ids, containsAll(<String>['done-1', 'done-2', 'done-new']));
    });

    test('running entries are never dropped', () {
      final TaskList tasks = TaskList(maxItems: 3);
      final DateTime base = DateTime(2026, 1, 1);
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_started',
          receivedAt: base,
          taskId: 'run-a',
          text: 'a',
        ),
      );
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_started',
          receivedAt: base.add(const Duration(seconds: 1)),
          taskId: 'run-b',
          text: 'b',
        ),
      );
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_completed',
          receivedAt: base.add(const Duration(seconds: 2)),
          taskId: 'done-old',
          result: 'old',
        ),
      );
      // Over budget with live work present: the done entry drops, both
      // running entries survive.
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_completed',
          receivedAt: base.add(const Duration(seconds: 3)),
          taskId: 'done-new',
          result: 'new',
        ),
      );
      final List<String> ids = tasks.items.map((t) => t.id).toList();
      expect(ids, containsAll(<String>['run-a', 'run-b', 'done-new']));
      expect(ids, isNot(contains('done-old')));
    });

    test('all-running map keeps every entry instead of dropping work', () {
      final TaskList tasks = TaskList(maxItems: 2);
      final DateTime base = DateTime(2026, 1, 1);
      for (int i = 0; i < 3; i++) {
        tasks.applyEvent(
          BuddyEvent(
            type: 'task_started',
            receivedAt: base.add(Duration(seconds: i)),
            taskId: 'run-$i',
            text: 't$i',
          ),
        );
      }
      expect(tasks.items, hasLength(3));
      expect(
        tasks.items.map((t) => t.id),
        containsAll(<String>['run-0', 'run-1', 'run-2']),
      );
    });

    test('200-cap holds at scale', () {
      final TaskList tasks = TaskList();
      final DateTime base = DateTime(2026, 1, 1);
      for (int i = 0; i < 210; i++) {
        tasks.applyEvent(
          BuddyEvent(
            type: 'task_completed',
            receivedAt: base.add(Duration(seconds: i)),
            taskId: 'done-$i',
            result: 'r',
          ),
        );
      }
      expect(tasks.items, hasLength(200));
      expect(tasks.byId('done-0'), isNull);
      expect(tasks.byId('done-209'), isNotNull);
    });
  });

  group('C4.4 frame bytes: split chunks render exact frame bytes', () {
    testWidgets('Image.memory receives the exact JPEG bytes', (
      WidgetTester tester,
    ) async {
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
      // Split the frame across two chunks (SOI in the first, EOI in the
      // second) plus junk bytes around it — the player must reassemble the
      // exact frame, byte for byte.
      final int split = _tinyJpeg.length ~/ 2;
      controller.add(<int>[0, 1, 2, ..._tinyJpeg.sublist(0, split)]);
      await tester.pump();
      controller.add(<int>[..._tinyJpeg.sublist(split), 9, 9]);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      final Image image = tester.widget<Image>(find.byType(Image));
      final MemoryImage mem = image.image as MemoryImage;
      expect(mem.bytes, orderedEquals(_tinyJpeg));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    });
  });

  group('C4.5 SnackBar cap + dedupe', () {
    test('dedupe predicate: same task+status <10s dupes, else not', () {
      final DateTime t0 = DateTime(2026, 9, 27, 12);
      TaskNotification noticeOf(String id, TaskNotificationKind kind) =>
          TaskNotification(
            kind: kind,
            status: TaskStatus.running,
            taskId: id,
            title: 'Task started',
            summary: 'hi',
            receivedAt: t0,
          );
      final TaskNotification n = noticeOf('abc123', TaskNotificationKind.started);
      const String key = 'abc123:started';
      expect(
        isDuplicateTaskNotification(
          n,
          lastKey: key,
          lastAt: t0,
          now: t0.add(const Duration(seconds: 5)),
        ),
        isTrue,
      );
      expect(
        isDuplicateTaskNotification(
          n,
          lastKey: key,
          lastAt: t0,
          now: t0.add(const Duration(seconds: 11)),
        ),
        isFalse,
      );
      expect(
        isDuplicateTaskNotification(
          noticeOf('abc123', TaskNotificationKind.completed),
          lastKey: key,
          lastAt: t0,
          now: t0.add(const Duration(seconds: 5)),
        ),
        isFalse,
      );
      expect(
        isDuplicateTaskNotification(
          noticeOf('other', TaskNotificationKind.started),
          lastKey: key,
          lastAt: t0,
          now: t0.add(const Duration(seconds: 5)),
        ),
        isFalse,
      );
      expect(
        isDuplicateTaskNotification(
          n,
          lastKey: key,
          lastAt: null,
          now: t0,
        ),
        isFalse,
      );
    });

    testWidgets('new notice replaces the visible one (cap 1+1)', (
      WidgetTester tester,
    ) async {
      resetTaskNotificationDedupe();
      ScaffoldMessengerState? messenger;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                messenger = ScaffoldMessenger.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final DateTime t0 = DateTime(2026, 9, 27, 12);
      TaskNotification noticeOf(String id, String summary) => TaskNotification(
        kind: TaskNotificationKind.started,
        status: TaskStatus.running,
        taskId: id,
        title: 'Task started',
        summary: summary,
        receivedAt: t0,
      );
      showTaskNotification(
        messenger!,
        notification: noticeOf('task-aaa', 'first command'),
        onView: () {},
        nowForTest: t0,
      );
      await tester.pump();
      expect(find.textContaining('first command'), findsOneWidget);
      showTaskNotification(
        messenger!,
        notification: noticeOf('task-bbb', 'second command'),
        onView: () {},
        nowForTest: t0.add(const Duration(seconds: 1)),
      );
      await tester.pump();
      // Capped: the second replaced the first — both are never visible.
      expect(find.textContaining('second command'), findsOneWidget);
      expect(find.textContaining('first command'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('same task+status within 10s is swallowed', (
      WidgetTester tester,
    ) async {
      resetTaskNotificationDedupe();
      ScaffoldMessengerState? messenger;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                messenger = ScaffoldMessenger.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final DateTime t0 = DateTime(2026, 9, 27, 12);
      TaskNotification dup() => TaskNotification(
        kind: TaskNotificationKind.completed,
        status: TaskStatus.done,
        taskId: 'task-dup',
        title: 'Task done',
        summary: 'same result',
        receivedAt: t0,
      );
      showTaskNotification(
        messenger!,
        notification: dup(),
        onView: () {},
        nowForTest: t0,
      );
      await tester.pump();
      expect(find.textContaining('same result'), findsOneWidget);
      // Duplicate 5s later: swallowed, still exactly one SnackBar.
      showTaskNotification(
        messenger!,
        notification: dup(),
        onView: () {},
        nowForTest: t0.add(const Duration(seconds: 5)),
      );
      await tester.pump();
      expect(find.textContaining('same result'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('C4.6 motion: the ONE animation is the NEAR/FAR cross-fade', () {
    testWidgets('header pill cross-fades via AnimatedSwitcher 200ms', (
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
      await tester.pump();
      expect(find.text('NEAR'), findsOneWidget);
      final AnimatedSwitcher switcher = tester.widget<AnimatedSwitcher>(
        find.byType(AnimatedSwitcher).first,
      );
      expect(switcher.duration, const Duration(milliseconds: 200));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            appBar: StatusHeader(
              proximity: ProximityMode.far,
              connection: BuddyConnection.online,
              runningCount: 0,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('FAR'), findsOneWidget);
      // No decorative motion elsewhere on the header: exactly one switcher.
      expect(find.byType(AnimatedSwitcher), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('send button keeps its real busy progress state', (
      WidgetTester tester,
    ) async {
      final BuddyApi api = _mockApi((_) async => http.Response('', 200));
      addTearDown(api.close);
      final ProximityService proximity = ProximityService()
        ..markNear()
        ..setOnline();
      final Completer<void> gate = Completer<void>();
      await tester.pumpWidget(
        _frame(
          ChatScreen(
            api: api,
            events: const <BuddyEvent>[],
            proximity: proximity,
            onSend: (_) => gate.future,
            streamError: null,
            streamConnected: true,
            onRetryStream: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.text('Send'));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Semantics &&
              (w.properties.label ?? '').contains('Sending command'),
        ),
        findsOneWidget,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('C4 console-column controller seam', () {
    testWidgets('ConsoleColumn accepts an external ScrollController', (
      WidgetTester tester,
    ) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _frame(
          ConsoleColumn(
            controller: controller,
            child: const Column(
              children: <Widget>[Text('hello column')],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('hello column'), findsOneWidget);
      expect(controller.hasClients, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}
