import 'buddy_event.dart';
import 'task_item.dart';

/// In-app notification trigger logic for task lifecycle events (Phase 4.3).
///
/// Pure Dart — no widget imports — so it is unit-testable without a device.
/// Only the three SSE task lifecycle events produce a notification;
/// `tool_call` and unknown frames return null (too noisy to alert on).
/// Status values come ONLY from the DESIGN.md status table via [TaskStatus]
/// (rendered with StatusBadge — no ad-hoc dots).
enum TaskNotificationKind { started, completed, failed }

class TaskNotification {
  const TaskNotification({
    required this.kind,
    required this.status,
    required this.taskId,
    required this.title,
    required this.summary,
    required this.receivedAt,
  });

  final TaskNotificationKind kind;
  final TaskStatus status;
  final String taskId;
  final String title;
  final String summary;
  final DateTime receivedAt;

  /// Build a notification from one SSE frame, or null when the frame must
  /// stay silent (tool_call, unknown types, missing task id).
  ///
  /// [fallbackTitle] is the already-folded task title (see TaskList.byId):
  /// completed/failed frames carry result/error, not the command text, so
  /// the summary falls back to it when the payload field is empty.
  static TaskNotification? fromEvent(
    BuddyEvent event, {
    String? fallbackTitle,
  }) {
    final String? id = event.taskId;
    if (id == null || id.isEmpty) return null;

    final TaskNotificationKind kind;
    final TaskStatus status;
    final String title;
    final String? raw;
    switch (event.type) {
      case 'task_started':
        kind = TaskNotificationKind.started;
        status = TaskStatus.running;
        title = 'Task started';
        raw = event.text;
      case 'task_completed':
        kind = TaskNotificationKind.completed;
        status = TaskStatus.done;
        title = 'Task done';
        raw = event.result;
      case 'task_failed':
        kind = TaskNotificationKind.failed;
        status = TaskStatus.failed;
        title = 'Task failed';
        raw = event.error;
      default:
        return null;
    }

    final String base;
    if (raw != null && raw.isNotEmpty) {
      base = raw;
    } else if (fallbackTitle != null && fallbackTitle.isNotEmpty) {
      base = fallbackTitle;
    } else {
      base = id;
    }
    return TaskNotification(
      kind: kind,
      status: status,
      taskId: id,
      title: title,
      summary: _oneLine(base),
      receivedAt: event.receivedAt,
    );
  }

  /// Short id for correlating the notice with the Tasks tab — same 6-char
  /// rule as BuddyEvent.describe.
  String get shortId => taskId.length < 6 ? taskId : taskId.substring(0, 6);

  /// How long the SnackBar stays up. Failures keep the error readable;
  /// starts are the most transient. (DESIGN.md sets no durations, so these
  /// are a stated assumption — see the session report.)
  Duration get displayDuration {
    switch (kind) {
      case TaskNotificationKind.started:
        return const Duration(seconds: 4);
      case TaskNotificationKind.completed:
        return const Duration(seconds: 6);
      case TaskNotificationKind.failed:
        return const Duration(seconds: 8);
    }
  }

  /// Screen-reader announcement for the notice.
  String get semanticLabel => '$title: $summary';

  /// Same 140-char one-line rule as BuddyEvent.describe so notices read
  /// like the chat log lines they summarize.
  static String _oneLine(String value) {
    final String flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '—';
    return flat.length > 140 ? '${flat.substring(0, 140)}…' : flat;
  }
}
