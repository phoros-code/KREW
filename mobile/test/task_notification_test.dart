import 'package:everyday_buddy/models/buddy_event.dart';
import 'package:everyday_buddy/models/task_item.dart';
import 'package:everyday_buddy/models/task_notification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BuddyEvent sse(String type, Map<String, dynamic> data) =>
      BuddyEvent.fromSse(type, data);

  group('TaskNotification.fromEvent', () {
    test('task_started maps to RUNNING with the command text', () {
      final TaskNotification? notice = TaskNotification.fromEvent(
        sse('task_started', <String, dynamic>{
          'task_id': 'b7e1aa99',
          'text': 'research local LLMs',
        }),
      );
      expect(notice, isNotNull);
      expect(notice!.kind, TaskNotificationKind.started);
      expect(notice.status, TaskStatus.running);
      expect(notice.title, 'Task started');
      expect(notice.summary, 'research local LLMs');
      expect(notice.shortId, 'b7e1aa');
    });

    test('task_completed maps to DONE with the result as summary', () {
      final TaskNotification? notice = TaskNotification.fromEvent(
        sse('task_completed', <String, dynamic>{
          'task_id': 'abc123',
          'result': 'here is the summary',
        }),
        fallbackTitle: 'research local LLMs',
      );
      expect(notice, isNotNull);
      expect(notice!.kind, TaskNotificationKind.completed);
      expect(notice.status, TaskStatus.done);
      expect(notice.title, 'Task done');
      expect(notice.summary, 'here is the summary');
    });

    test('task_failed maps to FAILED with the error as summary', () {
      final TaskNotification? notice = TaskNotification.fromEvent(
        sse('task_failed', <String, dynamic>{
          'task_id': 'abc123',
          'error': 'shell blocked',
        }),
        fallbackTitle: 'research local LLMs',
      );
      expect(notice, isNotNull);
      expect(notice!.kind, TaskNotificationKind.failed);
      expect(notice.status, TaskStatus.failed);
      expect(notice.title, 'Task failed');
      expect(notice.summary, 'shell blocked');
    });

    test('completed without a result falls back to the task title', () {
      final TaskNotification? notice = TaskNotification.fromEvent(
        sse('task_completed', <String, dynamic>{'task_id': 'abc123'}),
        fallbackTitle: 'research local LLMs',
      );
      expect(notice, isNotNull);
      expect(notice!.summary, 'research local LLMs');
    });

    test('started without text falls back to title, then task id', () {
      final TaskNotification? withTitle = TaskNotification.fromEvent(
        sse('task_started', <String, dynamic>{'task_id': 'abc123'}),
        fallbackTitle: 'queued command',
      );
      expect(withTitle, isNotNull);
      expect(withTitle!.summary, 'queued command');

      final TaskNotification? bare = TaskNotification.fromEvent(
        sse('task_started', <String, dynamic>{'task_id': 'abc123'}),
      );
      expect(bare, isNotNull);
      expect(bare!.summary, 'abc123');
    });

    test('long summaries are truncated to one line', () {
      final String long = List<String>.filled(200, 'w').join();
      final TaskNotification? notice = TaskNotification.fromEvent(
        sse('task_completed', <String, dynamic>{
          'task_id': 'abc123',
          'result': long,
        }),
      );
      expect(notice, isNotNull);
      expect(notice!.summary.length, lessThanOrEqualTo(141));
      expect(notice.summary, endsWith('…'));
    });

    test('multiline results are flattened to one line', () {
      final TaskNotification? notice = TaskNotification.fromEvent(
        sse('task_failed', <String, dynamic>{
          'task_id': 'abc123',
          'error': 'line one\nline two',
        }),
      );
      expect(notice, isNotNull);
      expect(notice!.summary, 'line one line two');
    });

    test('tool_call and unknown events produce no notification', () {
      expect(
        TaskNotification.fromEvent(
          sse('tool_call', <String, dynamic>{
            'task_id': 'b7e1aa',
            'tool': 'web_search',
            'args': <String, dynamic>{'query': 'x'},
          }),
        ),
        isNull,
      );
      expect(
        TaskNotification.fromEvent(
          sse('heartbeat', <String, dynamic>{'task_id': 'b7e1aa'}),
        ),
        isNull,
      );
    });

    test('events without a task id produce no notification', () {
      expect(
        TaskNotification.fromEvent(
          BuddyEvent(type: 'task_started', receivedAt: DateTime.now()),
        ),
        isNull,
      );
      expect(
        TaskNotification.fromEvent(
          sse('task_started', <String, dynamic>{
            'task_id': '',
            'text': 'x',
          }),
        ),
        isNull,
      );
    });
  });

  group('TaskNotification display', () {
    TaskNotification noticeFor(TaskNotificationKind kind) {
      switch (kind) {
        case TaskNotificationKind.started:
          return TaskNotification.fromEvent(
            sse('task_started', <String, dynamic>{
              'task_id': 'abc123',
              'text': 'do it',
            }),
          )!;
        case TaskNotificationKind.completed:
          return TaskNotification.fromEvent(
            sse('task_completed', <String, dynamic>{
              'task_id': 'abc123',
              'result': 'ok',
            }),
          )!;
        case TaskNotificationKind.failed:
          return TaskNotification.fromEvent(
            sse('task_failed', <String, dynamic>{
              'task_id': 'abc123',
              'error': 'boom',
            }),
          )!;
      }
    }

    test('failures stay longest, starts shortest', () {
      final Duration started =
          noticeFor(TaskNotificationKind.started).displayDuration;
      final Duration completed =
          noticeFor(TaskNotificationKind.completed).displayDuration;
      final Duration failed =
          noticeFor(TaskNotificationKind.failed).displayDuration;
      expect(started < completed, isTrue);
      expect(completed < failed, isTrue);
    });

    test('semantic labels carry the kind and the summary', () {
      expect(
        noticeFor(TaskNotificationKind.started).semanticLabel,
        'Task started: do it',
      );
      expect(
        noticeFor(TaskNotificationKind.completed).semanticLabel,
        'Task done: ok',
      );
      expect(
        noticeFor(TaskNotificationKind.failed).semanticLabel,
        'Task failed: boom',
      );
    });
  });

  group('TaskList.byId', () {
    test('returns the folded task for the SSE fallback title', () {
      final TaskList tasks = TaskList();
      tasks.setQueued('t1', 'do research');
      expect(tasks.byId('t1')?.title, 'do research');
      expect(tasks.byId('missing'), isNull);
    });
  });
}
