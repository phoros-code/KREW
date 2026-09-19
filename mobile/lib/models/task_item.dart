import 'buddy_event.dart';

/// Task states — the ONLY task statuses the UI may render, per the
/// DESIGN.md status meaning table:
///   queued  -> warning #D9932A (accepted, waiting to run)
///   running -> primary #1E5F4A (agent actively working)
///   done    -> success #3A8B5C (completed with a result)
///   failed  -> error   #C4453D (failed, see error text)
enum TaskStatus { queued, running, done, failed }

extension TaskStatusLabel on TaskStatus {
  String get label {
    switch (this) {
      case TaskStatus.queued:
        return 'QUEUED';
      case TaskStatus.running:
        return 'RUNNING';
      case TaskStatus.done:
        return 'DONE';
      case TaskStatus.failed:
        return 'FAILED';
    }
  }
}

class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    required this.status,
    required this.updatedAt,
    this.detail,
  });

  final String id;
  final String title;
  final TaskStatus status;
  final DateTime updatedAt;
  final String? detail;

  TaskItem copyWith({
    TaskStatus? status,
    DateTime? updatedAt,
    String? detail,
    String? title,
  }) {
    return TaskItem(
      id: id,
      title: title ?? this.title,
      status: status ?? this.status,
      updatedAt: updatedAt ?? this.updatedAt,
      detail: detail ?? this.detail,
    );
  }
}

/// Folds the SSE event log into the task list. Pure logic — unit tested.
class TaskList {
  final Map<String, TaskItem> _items = {};

  List<TaskItem> get items {
    final List<TaskItem> sorted = _items.values.toList();
    sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  }

  /// Lookup by id for notification fallback titles (completed/failed SSE
  /// frames carry result/error, not the command text). Pure — unit tested.
  TaskItem? byId(String id) => _items[id];

  int get runningCount {
    return _items.values
        .where(
          (t) =>
              t.status == TaskStatus.queued ||
              t.status == TaskStatus.running,
        )
        .length;
  }

  /// A command accepted by POST /command starts life as QUEUED.
  void setQueued(String taskId, String title) {
    _items[taskId] = TaskItem(
      id: taskId,
      title: title,
      status: TaskStatus.queued,
      updatedAt: DateTime.now(),
    );
  }

  void applyEvent(BuddyEvent event) {
    final String? id = event.taskId;
    if (id == null || id.isEmpty) return;
    final DateTime now = event.receivedAt;
    switch (event.type) {
      case 'task_started':
        final TaskItem? existing = _items[id];
        _items[id] = TaskItem(
          id: id,
          title: event.text ?? existing?.title ?? id,
          status: TaskStatus.running,
          updatedAt: now,
        );
      case 'tool_call':
        final TaskItem? existing = _items[id];
        if (existing == null) {
          _items[id] = TaskItem(
            id: id,
            title: event.tool ?? id,
            status: TaskStatus.running,
            updatedAt: now,
          );
        } else {
          _items[id] = existing.copyWith(
            status: TaskStatus.running,
            updatedAt: now,
          );
        }
      case 'task_completed':
        final TaskItem? existing = _items[id];
        _items[id] = TaskItem(
          id: id,
          title: existing?.title ?? event.text ?? id,
          status: TaskStatus.done,
          updatedAt: now,
          detail: event.result,
        );
      case 'task_failed':
        final TaskItem? existing = _items[id];
        _items[id] = TaskItem(
          id: id,
          title: existing?.title ?? event.text ?? id,
          status: TaskStatus.failed,
          updatedAt: now,
          detail: event.error,
        );
    }
  }

  void clear() => _items.clear();
}
