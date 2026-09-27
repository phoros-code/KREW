import 'package:flutter/material.dart';

import '../models/task_notification.dart';
import '../theme/buddy_theme.dart';
import 'status_badge.dart';

/// In-app task notification (Phase 4.3, LAN-only scope).
///
/// A floating SnackBar shown from the app shell's already-subscribed SSE
/// listener when a task_started / task_completed / task_failed event
/// arrives. This is NOT a push/FCM service — it only fires while the app is
/// open and streaming, which is exactly the /events "notifications only"
/// contract from API.md (it works in FAR mode too).
///
/// DESIGN.md conformance:
/// - No new layout shape: the SnackBar overlays the existing console-column
///   screens instead of adding banner rows or cards to them.
/// - Status comes ONLY from the status meaning table via [StatusBadge]
///   (table color + text label), so the frozen status table needs no change.
/// - Background is the base/neutral dark token in both themes; the "View"
///   action uses the sparing accent token. Spacing (4/16) and radii (12)
///   come from BuddySpacing/BuddyRadii only. No gradients, no Inter, no
///   emoji — title uses the IBM Plex Sans label style from the theme,
///   summary uses the JetBrains Mono token.
/// - Tapping "View" jumps to the Tasks tab (cheap: the shell already owns
///   an IndexedStack). The notice itself already carries the result/error
///   summary, so nothing is lost if it is swiped away.
class TaskNotificationContent extends StatelessWidget {
  const TaskNotificationContent({super.key, required this.notification});

  final TaskNotification notification;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: notification.semanticLabel,
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // SnackBar bg is baseDark in both themes — force dark brightness
          // so the badge picks the OnDark text variants (≥4.5:1 on dark).
          // Light variants would be dark-on-dark (∼3.1:1, fail).
          Theme(
            data: Theme.of(context).copyWith(brightness: Brightness.dark),
            child: StatusBadge(status: notification.status),
          ),
          const SizedBox(width: BuddySpacing.s3),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  notification.title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: BuddyColors.inkOnDark,
                  ),
                ),
                const SizedBox(height: BuddySpacing.s1),
                Text(
                  '[${notification.shortId}] ${notification.summary}',
                  style: BuddyTheme.mono(
                    BuddyColors.inkMutedOnDark,
                    size: 12,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Track C4 SnackBar cap: at most 1 visible + 1 queued. Every new task
/// notice dismisses the current one first ([removeCurrentSnackBar]), so the
/// queue never grows — the newest notice is always one tap away.
///
/// Track C4 dedupe: the same task+status within 10s is swallowed (the SSE
/// stream can re-deliver; the user already saw it). Keyed on
/// taskId+kind — a started→done transition for the same task still shows.
String _lastNoticeKey = '';
DateTime? _lastNoticeAt;

/// Test seam: reset the dedupe latch between widget tests.
@visibleForTesting
void resetTaskNotificationDedupe() {
  _lastNoticeKey = '';
  _lastNoticeAt = null;
}

/// Pure dedupe predicate — unit-tested. Returns true when [notice] duplicates
/// the last shown key within [window] (default 10s).
@visibleForTesting
bool isDuplicateTaskNotification(
  TaskNotification notification, {
  required String lastKey,
  required DateTime? lastAt,
  required DateTime now,
  Duration window = const Duration(seconds: 10),
}) {
  final String key = '${notification.taskId}:${notification.kind.name}';
  if (key != lastKey || lastAt == null) return false;
  return now.difference(lastAt) < window;
}

/// Show [notification] as a floating SnackBar. [onView] navigates to the
/// relevant task content (the shell passes a jump to the Tasks tab).
void showTaskNotification(
  ScaffoldMessengerState messenger, {
  required TaskNotification notification,
  required VoidCallback onView,
  DateTime? nowForTest,
}) {
  final DateTime now = nowForTest ?? DateTime.now();
  final String key = '${notification.taskId}:${notification.kind.name}';
  if (isDuplicateTaskNotification(
    notification,
    lastKey: _lastNoticeKey,
    lastAt: _lastNoticeAt,
    now: now,
  )) {
    return;
  }
  _lastNoticeKey = key;
  _lastNoticeAt = now;
  // Cap: dismiss the visible SnackBar before queuing the new one — at most
  // one visible + one queued can ever exist.
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: notification.displayDuration,
      backgroundColor: BuddyColors.baseDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(BuddyRadii.container),
        ),
      ),
      margin: const EdgeInsets.all(BuddySpacing.s4),
      padding: const EdgeInsets.all(BuddySpacing.s4),
      showCloseIcon: true,
      closeIconColor: BuddyColors.inkMutedOnDark,
      content: TaskNotificationContent(notification: notification),
      action: SnackBarAction(
        label: 'View',
        textColor: BuddyColors.accent,
        onPressed: () {
          messenger.hideCurrentSnackBar();
          onView();
        },
      ),
    ),
  );
}
