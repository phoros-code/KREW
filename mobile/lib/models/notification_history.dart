import 'task_notification.dart';

/// Track C3: in-memory bounded store of the last [maxSize] task
/// notifications for the "Recent notifications" section in the Tasks tab.
///
/// Pure Dart — no widget imports — unit-tested. Newest first. Owned by the
/// app shell (lives and dies with the process; nothing is persisted).
class NotificationHistory {
  NotificationHistory({this.maxSize = 50});

  /// Bound required by the Track C3 spec: the last 50.
  final int maxSize;

  final List<TaskNotification> _items = <TaskNotification>[];

  List<TaskNotification> get items => List<TaskNotification>.unmodifiable(_items);

  int get length => _items.length;

  bool get isEmpty => _items.isEmpty;

  void add(TaskNotification notice) {
    _items.insert(0, notice);
    if (_items.length > maxSize) {
      _items.removeRange(maxSize, _items.length);
    }
  }

  void clear() => _items.clear();
}
