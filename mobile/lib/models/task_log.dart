import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'buddy_event.dart';

/// Track C3 helpers for the per-task log view ([TaskDetailScreen]).
///
/// Tool-call args may carry secrets, so the detail view never renders them
/// raw: [redactedArgsSummary] shows only the JSON length plus a short SHA-256
/// prefix (same "length+sha" contract as the server-side redaction in
/// SECURITY.md). Pure Dart — unit-tested.
String redactedArgsSummary(Map<String, dynamic>? args) {
  if (args == null || args.isEmpty) return 'no args';
  final String json = jsonEncode(args);
  final String sha = sha256.convert(utf8.encode(json)).toString();
  return 'args ${json.length} chars · sha ${sha.substring(0, 12)}…';
}

/// All events for one task, oldest first (detail reads top-down; the chat
/// log stays newest-first). Pure — unit tested.
List<BuddyEvent> eventsForTask(List<BuddyEvent> events, String taskId) {
  final List<BuddyEvent> filtered = events
      .where((BuddyEvent e) => e.taskId == taskId)
      .toList();
  filtered.sort((BuddyEvent a, BuddyEvent b) => a.receivedAt.compareTo(b.receivedAt));
  return filtered;
}

/// Human title per SSE type for the detail event rows.
String taskEventTitle(BuddyEvent event) {
  switch (event.type) {
    case 'task_started':
      return 'Task started';
    case 'tool_call':
      return 'Tool: ${event.tool ?? 'unknown'}';
    case 'task_completed':
      return 'Task done';
    case 'task_failed':
      return 'Task failed';
    default:
      return event.type;
  }
}
