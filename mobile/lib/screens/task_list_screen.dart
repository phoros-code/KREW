import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';
import '../widgets/status_badge.dart';

/// Task list screen: task id, status, and timestamp folded from /events.
/// Status indicators come ONLY from the DESIGN.md status table (rendered via
/// [StatusBadge] — no ad-hoc dots anywhere on this screen).
class TaskListScreen extends StatelessWidget {
  const TaskListScreen({
    super.key,
    required this.tasks,
    required this.isPaired,
    required this.streamError,
    required this.onRetry,
  });

  final TaskList tasks;
  final bool isPaired;
  final String? streamError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted = dark
        ? BuddyColors.inkMutedOnDark
        : BuddyColors.inkMutedOnLight;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;

    final List<TaskItem> items = tasks.items;

    return ConsoleColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Tasks', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: BuddySpacing.s2),
          Text(
            'Every command queued from the Chat tab, with its live status.',
            style: small,
          ),
          const SizedBox(height: BuddySpacing.s4),

          // Error state: the event stream backing this list failed.
          if (streamError != null)
            Container(
              padding: const EdgeInsets.all(BuddySpacing.s4),
              decoration: BoxDecoration(
                border: Border.all(color: BuddyColors.error),
                borderRadius: const BorderRadius.all(
                  Radius.circular(BuddyRadii.container),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Row(
                    children: <Widget>[
                      Icon(
                        Icons.error_outline,
                        size: 18,
                        color: BuddyColors.error,
                      ),
                      SizedBox(width: BuddySpacing.s2),
                      Text(
                        'Task updates paused',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: BuddyColors.error,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: BuddySpacing.s2),
                  Text(streamError!, style: small),
                  const SizedBox(height: BuddySpacing.s3),
                  OutlinedButton(
                    onPressed: onRetry,
                    child: const Text('Reconnect'),
                  ),
                ],
              ),
            ),
          if (streamError != null) const SizedBox(height: BuddySpacing.s4),

          // Empty states.
          if (!isPaired)
            _EmptyBox(
              hairline: hairline,
              muted: muted,
              icon: Icons.laptop_outlined,
              title: 'No laptop paired yet',
              hint: 'Pair from the Pair tab — tasks you send will appear here.',
            )
          else if (items.isEmpty && streamError == null)
            _EmptyBox(
              hairline: hairline,
              muted: muted,
              icon: Icons.assignment_outlined,
              title: 'No tasks yet',
              hint:
                  'Send a command from the Chat tab. It will show here as QUEUED, then RUNNING, then DONE or FAILED.',
            )
          else
            for (final TaskItem task in items)
              Padding(
                padding: const EdgeInsets.only(bottom: BuddySpacing.s3),
                child: _TaskRow(
                  task: task,
                  hairline: hairline,
                  muted: muted,
                ),
              ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.hairline,
    required this.muted,
  });

  final TaskItem task;
  final Color hairline;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final String when = _formatTime(task.updatedAt);
    return Container(
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
    return Container(
      padding: const EdgeInsets.all(BuddySpacing.s5),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(
          Radius.circular(BuddyRadii.container),
        ),
      ),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 32, color: muted),
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
    );
  }
}
