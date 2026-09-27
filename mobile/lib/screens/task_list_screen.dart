import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/task_item.dart';
import '../models/task_notification.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';
import '../widgets/status_badge.dart';

/// Task list screen: task id, status, and timestamp folded from /events.
/// Status indicators come ONLY from the DESIGN.md status table (rendered via
/// [StatusBadge] — no ad-hoc dots anywhere on this screen).
///
/// Track C3: a "Recent notifications" history section sits above the list
/// (in-memory, last 50, owned by the shell — NO new tab). Tapping a task
/// row or a history row opens the per-task log view via [onOpenTask].
/// Pull-to-refresh re-runs the shell reconnect via [onRefresh].
class TaskListScreen extends StatelessWidget {
  const TaskListScreen({
    super.key,
    required this.tasks,
    required this.isPaired,
    required this.streamError,
    required this.onRetry,
    this.notifications = const <TaskNotification>[],
    this.onClearHistory,
    this.onOpenTask,
    this.onRefresh,
  });

  final TaskList tasks;
  final bool isPaired;
  final String? streamError;
  final VoidCallback onRetry;

  /// Bounded notification history (newest first). Empty by default (tests).
  final List<TaskNotification> notifications;
  final VoidCallback? onClearHistory;

  /// Opens the per-task log view for [taskId]. Null renders rows static.
  final void Function(String taskId)? onOpenTask;

  /// Pull-to-refresh handler (shell reconnect + config fetch).
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted = dark
        ? BuddyColors.inkMutedOnDark
        : BuddyColors.inkMutedOnLight;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;
    final Color errorText = dark
        ? BuddyColors.errorOnDark
        : BuddyColors.errorOnLight;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;

    final List<TaskItem> items = tasks.items;

    return ConsoleColumn(
      onRefresh: onRefresh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            AppStrings.tasksTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: BuddySpacing.s2),
          Text(AppStrings.tasksSubtitle, style: small),
          const SizedBox(height: BuddySpacing.s4),

          // Error state: the event stream backing this list failed.
          if (streamError != null)
            Semantics(
              label: '${AppStrings.tasksErrorTitle}: $streamError',
              container: true,
              child: Container(
                padding: const EdgeInsets.all(BuddySpacing.s4),
                decoration: BoxDecoration(
                  border: Border.all(color: errorText),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(BuddyRadii.container),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        ExcludeSemantics(
                          child: Icon(
                            Icons.error_outline,
                            size: 18,
                            color: errorText,
                          ),
                        ),
                        const SizedBox(width: BuddySpacing.s2),
                        Text(
                          AppStrings.tasksErrorTitle,
                          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: errorText,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: BuddySpacing.s2),
                    Text(streamError!, style: small),
                    const SizedBox(height: BuddySpacing.s3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 48,
                        minWidth: 48,
                      ),
                      child: OutlinedButton(
                        onPressed: onRetry,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                        child: const Text(AppStrings.actionReconnect),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (streamError != null) const SizedBox(height: BuddySpacing.s4),

          // Track C3: notification history (in-memory, last 50). Above the
          // list, inside the same console column — no new tab.
          if (isPaired) ...<Widget>[
            _HistorySection(
              notifications: notifications,
              hairline: hairline,
              muted: muted,
              small: small,
              onClearHistory: onClearHistory,
              onOpenTask: onOpenTask,
            ),
            const SizedBox(height: BuddySpacing.s4),
          ],

          // Empty states. The no-tasks box renders independently of the
          // stream error (Track A5.12): with zero tasks AND a dead stream
          // the user sees both the error and the empty state, never a bare
          // error with no orientation.
          if (!isPaired)
            _EmptyBox(
              hairline: hairline,
              muted: muted,
              icon: Icons.laptop_outlined,
              title: AppStrings.tasksEmptyUnpairedTitle,
              hint: AppStrings.tasksEmptyUnpairedHint,
            )
          else if (items.isEmpty)
            _EmptyBox(
              hairline: hairline,
              muted: muted,
              icon: Icons.assignment_outlined,
              title: AppStrings.tasksEmptyTitle,
              hint: AppStrings.tasksEmptyHint,
            )
          else
            for (final TaskItem task in items)
              Padding(
                padding: const EdgeInsets.only(bottom: BuddySpacing.s3),
                child: _TaskRow(
                  task: task,
                  hairline: hairline,
                  muted: muted,
                  onTap: onOpenTask == null
                      ? null
                      : () => onOpenTask!(task.id),
                ),
              ),
        ],
      ),
    );
  }
}

/// Track C3 "Recent notifications" section: time + status + summary rows,
/// tap opens the task detail, Clear-history button empties the store.
class _HistorySection extends StatelessWidget {
  const _HistorySection({
    required this.notifications,
    required this.hairline,
    required this.muted,
    required this.small,
    required this.onClearHistory,
    required this.onOpenTask,
  });

  final List<TaskNotification> notifications;
  final Color hairline;
  final Color muted;
  final TextStyle? small;
  final VoidCallback? onClearHistory;
  final void Function(String taskId)? onOpenTask;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppStrings.historyTitle,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  AppStrings.historyTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (notifications.isNotEmpty)
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  onPressed: onClearHistory,
                  child: const Text(AppStrings.historyClear),
                ),
            ],
          ),
          const SizedBox(height: BuddySpacing.s2),
          if (notifications.isEmpty)
            Text(AppStrings.historyEmpty, style: small)
          else
            for (final TaskNotification notice in notifications)
              Padding(
                padding: const EdgeInsets.only(bottom: BuddySpacing.s2),
                child: _HistoryRow(
                  notice: notice,
                  hairline: hairline,
                  muted: muted,
                  onTap: onOpenTask == null
                      ? null
                      : () => onOpenTask!(notice.taskId),
                ),
              ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.notice,
    required this.hairline,
    required this.muted,
    required this.onTap,
  });

  final TaskNotification notice;
  final Color hairline;
  final Color muted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Widget row = Container(
      padding: const EdgeInsets.all(BuddySpacing.s3),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(
          Radius.circular(BuddyRadii.container),
        ),
      ),
      child: Row(
        children: <Widget>[
          StatusBadge(status: notice.status),
          const SizedBox(width: BuddySpacing.s2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  notice.summary,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: BuddySpacing.s1),
                Text(
                  _formatTime(notice.receivedAt),
                  style: BuddyTheme.mono(muted, size: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: BuddySpacing.s2),
          ExcludeSemantics(
            child: Icon(Icons.chevron_right, size: 20, color: muted),
          ),
        ],
      ),
    );
    final VoidCallback? tap = onTap;
    if (tap == null) return row;
    return Semantics(
      label: '${notice.semanticLabel}, opened task log',
      button: true,
      child: InkWell(onTap: tap, child: row),
    );
  }

  static String _formatTime(DateTime at) {
    final DateTime local = at.toLocal();
    final String hour = local.hour.toString().padLeft(2, '0');
    final String minute = local.minute.toString().padLeft(2, '0');
    final String second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.hairline,
    required this.muted,
    required this.onTap,
  });

  final TaskItem task;
  final Color hairline;
  final Color muted;

  /// Null renders the row static (older call sites, unit tests).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final String when = _formatTime(task.updatedAt);
    final Widget card = Container(
      padding: const EdgeInsets.all(BuddySpacing.s3),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(
          Radius.circular(BuddyRadii.container),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusBadge(status: task.status),
              const SizedBox(width: BuddySpacing.s2),
              Expanded(
                child: Text(
                  task.id,
                  style: BuddyTheme.mono(muted, size: 11.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: BuddySpacing.s2),
              Text(when, style: BuddyTheme.mono(muted, size: 11.5)),
              // Track C3: chevron marks the row as opening the log view.
              const SizedBox(width: BuddySpacing.s1),
              ExcludeSemantics(
                child: Icon(Icons.chevron_right, size: 20, color: muted),
              ),
            ],
          ),
          const SizedBox(height: BuddySpacing.s2),
          Text(
            task.title,
            style: Theme.of(context).textTheme.bodyMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.detail != null && task.detail!.isNotEmpty) ...<Widget>[
            const SizedBox(height: BuddySpacing.s1),
            Text(
              task.detail!,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
    final VoidCallback? tap = onTap;
    if (tap == null) return card;
    return Semantics(
      label: 'Open task log for ${task.id}',
      button: true,
      child: InkWell(onTap: tap, child: card),
    );
  }

  static String _formatTime(DateTime at) {
    final DateTime local = at.toLocal();
    final String hour = local.hour.toString().padLeft(2, '0');
    final String minute = local.minute.toString().padLeft(2, '0');
    final String second = local.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox({
    required this.hairline,
    required this.muted,
    required this.icon,
    required this.title,
    required this.hint,
  });

  final Color hairline;
  final Color muted;
  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    // Track C2: empty states announce title + hint as one container.
    return Semantics(
      label: '$title. $hint',
      container: true,
      child: Container(
        padding: const EdgeInsets.all(BuddySpacing.s5),
        decoration: BoxDecoration(
          border: Border.all(color: hairline),
          borderRadius: const BorderRadius.all(
            Radius.circular(BuddyRadii.container),
          ),
        ),
        child: Column(
          children: <Widget>[
            ExcludeSemantics(child: Icon(icon, size: 32, color: muted)),
            const SizedBox(height: BuddySpacing.s3),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              hint,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
