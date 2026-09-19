import 'package:everyday_buddy/models/buddy_event.dart';
import 'package:everyday_buddy/models/task_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BuddyEvent.fromSse', () {
    test('parses task_started', () {
      final event = BuddyEvent.fromSse('task_started', <String, dynamic>{
        'task_id': 'b7e1aa',
        'text': 'research local LLMs',
      });
      expect(event.type, 'task_started');
      expect(event.taskId, 'b7e1aa');
      expect(event.text, 'research local LLMs');
      expect(event.describe(), contains('started'));
    });

    test('parses tool_call with args', () {
      final event = BuddyEvent.fromSse('tool_call', <String, dynamic>{
        'task_id': 'b7e1aa',
        'tool': 'web_search',
        'args': <String, dynamic>{'query': 'local LLMs'},
      });
      expect(event.tool, 'web_search');
      expect(event.args?['query'], 'local LLMs');
    });

    test('parses task_completed and task_failed', () {
      final done = BuddyEvent.fromSse('task_completed', <String, dynamic>{
        'task_id': 'abc123',
        'result': 'here is the summary',
      });
      expect(done.result, 'here is the summary');

      final failed = BuddyEvent.fromSse('task_failed', <String, dynamic>{
        'task_id': 'abc123',
        'error': 'boom',
      });
      expect(failed.error, 'boom');
    });

    test('rejects non-object payloads', () {
      expect(
        () => BuddyEvent.fromSse('task_started', 'not-an-object'),
        throwsFormatException,
      );
    });
  });

  group('TaskList', () {
    test('folds queued -> running -> done', () {
      final tasks = TaskList();
      tasks.setQueued('t1', 'do research');
      expect(tasks.items.single.status, TaskStatus.queued);

      tasks.applyEvent(
        BuddyEvent(
          type: 'task_started',
          receivedAt: DateTime.now(),
          taskId: 't1',
          text: 'do research',
        ),
      );
      expect(tasks.items.single.status, TaskStatus.running);

      tasks.applyEvent(
        BuddyEvent(
          type: 'task_completed',
          receivedAt: DateTime.now(),
          taskId: 't1',
          result: 'done reading',
        ),
      );
      expect(tasks.items.single.status, TaskStatus.done);
      expect(tasks.items.single.detail, 'done reading');
    });

    test('failed keeps the error as detail', () {
      final tasks = TaskList();
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_failed',
          receivedAt: DateTime.now(),
          taskId: 't9',
          error: 'shell blocked',
        ),
      );
      expect(tasks.items.single.status, TaskStatus.failed);
      expect(tasks.items.single.detail, 'shell blocked');
    });

    test('ignores events without a task id', () {
      final tasks = TaskList();
      tasks.applyEvent(
        BuddyEvent(type: 'task_started', receivedAt: DateTime.now()),
      );
      expect(tasks.items, isEmpty);
    });

    test('runningCount covers queued and running only', () {
      final tasks = TaskList();
      tasks.setQueued('a', 'one');
      tasks.setQueued('b', 'two');
      expect(tasks.runningCount, 2);
      tasks.applyEvent(
        BuddyEvent(
          type: 'task_completed',
          receivedAt: DateTime.now(),
          taskId: 'a',
          result: 'ok',
        ),
      );
      expect(tasks.runningCount, 1);
    });
  });
}
