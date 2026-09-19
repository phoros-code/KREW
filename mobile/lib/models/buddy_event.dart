/// Agent lifecycle events streamed from GET /events (SSE), per API.md.
///
/// Wire shapes:
///   event: task_started   data: {"task_id": "...", "text": "..."}
///   event: tool_call      data: {"task_id": "...", "tool": "...", "args": {...}}
///   event: task_completed data: {"task_id": "...", "result": "..."}
///   event: task_failed    data: {"task_id": "...", "error": "..."}
class BuddyEvent {
  const BuddyEvent({
    required this.type,
    required this.receivedAt,
    this.taskId,
    this.text,
    this.tool,
    this.args,
    this.result,
    this.error,
  });

  final String type;
  final DateTime receivedAt;
  final String? taskId;
  final String? text;
  final String? tool;
  final Map<String, dynamic>? args;
  final String? result;
  final String? error;

  /// Parse one SSE frame. Throws [FormatException] on unusable frames so the
  /// caller can skip them without killing the stream.
  factory BuddyEvent.fromSse(String eventType, dynamic data) {
    if (data is! Map<String, dynamic>) {
      throw const FormatException('SSE data payload is not an object');
    }
    final String? taskId = data['task_id'] is String
        ? data['task_id'] as String
        : null;
    return BuddyEvent(
      type: eventType,
      receivedAt: DateTime.now(),
      taskId: taskId,
      text: data['text'] is String ? data['text'] as String : null,
      tool: data['tool'] is String ? data['tool'] as String : null,
      args: data['args'] is Map<String, dynamic>
          ? data['args'] as Map<String, dynamic>
          : null,
      result: data['result'] is String ? data['result'] as String : null,
      error: data['error'] is String ? data['error'] as String : null,
    );
  }

  /// One human-readable log line for the chat screen (rendered in mono).
  String describe() {
    final String shortId = taskId == null || taskId!.length < 6
        ? (taskId ?? '—')
        : taskId!.substring(0, 6);
    switch (type) {
      case 'task_started':
        return '[$shortId] started: ${_oneLine(text)}';
      case 'tool_call':
        return '[$shortId] tool $tool ${_oneLine(args?.toString())}';
      case 'task_completed':
        return '[$shortId] done: ${_oneLine(result)}';
      case 'task_failed':
        return '[$shortId] failed: ${_oneLine(error)}';
      default:
        return '[$shortId] $type';
    }
  }

  static String _oneLine(String? value) {
    if (value == null || value.isEmpty) return '—';
    final String flat = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 140 ? '${flat.substring(0, 140)}…' : flat;
  }
}
