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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          StatusBadge(status: notification.status),
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

/// Show [notification] as a floating SnackBar. [onView] navigates to the
/// relevant task content (the shell passes a jump to the Tasks tab).
void showTaskNotification(
  ScaffoldMessengerState messenger, {
  required TaskNotification notification,
  required VoidCallback onView,
}) {
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
