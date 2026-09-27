import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/buddy_event.dart';
import '../models/task_item.dart';
import '../models/task_log.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';
import '../widgets/status_badge.dart';

/// Track C3: per-task log view. Pushed when a task row (or a notification
/// history row) is tapped — NOT a new tab.
///
/// Shows the full event list for one task, oldest first: tool calls render
/// with redacted args (length+sha via [redactedArgsSummary], never raw),
/// results/errors render in full with tap-to-copy. Console-column primitive,
/// DESIGN.md tokens only, no new hues.
class TaskDetailScreen extends StatelessWidget {
  const TaskDetailScreen({
    super.key,
    required this.task,
    required this.events,
  });

  final TaskItem task;
  final List<BuddyEvent> events;

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

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.taskDetailTitle)),
      body: ConsoleColumn(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              label: 'Task ${task.id}, status ${task.status.label}',
              container: true,
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
                    ],
                  ),
                  const SizedBox(height: BuddySpacing.s2),
                  Text(
                    task.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: BuddySpacing.s4),
            Text(
              AppStrings.taskDetailEventsHeader,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: BuddySpacing.s2),
            if (events.isEmpty)
              Semantics(
                label: AppStrings.taskDetailEmpty,
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
                      ExcludeSemantics(
                        child: Icon(
                          Icons.receipt_long_outlined,
                          size: 32,
                          color: muted,
                        ),
                      ),
                      const SizedBox(height: BuddySpacing.s3),
                      Text(
                        AppStrings.taskDetailEmpty,
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              for (final BuddyEvent event in events)
                Padding(
                  padding: const EdgeInsets.only(bottom: BuddySpacing.s3),
                  child: _DetailEventRow(
                    event: event,
                    hairline: hairline,
                    muted: muted,
                    small: small,
                  ),
                ),
            const SizedBox(height: BuddySpacing.s4),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(AppStrings.actionClose),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailEventRow extends StatelessWidget {
  const _DetailEventRow({
    required this.event,
    required this.hairline,
    required this.muted,
    required this.small,
  });

  final BuddyEvent event;
  final Color hairline;
  final Color muted;
  final TextStyle? small;

  @override
  Widget build(BuildContext context) {
    final String? payload = event.result ?? event.error;
    return Semantics(
      label: '${taskEventTitle(event)}. ${_formatTime(event.receivedAt)}',
      container: true,
      child: Container(
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
                Expanded(
                  child: Text(
                    taskEventTitle(event),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                const SizedBox(width: BuddySpacing.s2),
                Text(
                  _formatTime(event.receivedAt),
                  style: BuddyTheme.mono(muted, size: 11.5),
                ),
              ],
            ),
            if (event.type == 'tool_call') ...<Widget>[
              const SizedBox(height: BuddySpacing.s2),
              Text(
                redactedArgsSummary(event.args),
                style: BuddyTheme.mono(muted, size: 11.5),
              ),
            ],
            if (payload != null && payload.isNotEmpty) ...<Widget>[
              const SizedBox(height: BuddySpacing.s2),
              _CopyableResult(payload: payload, muted: muted),
            ],
          ],
        ),
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

/// Full result/error text with tap-to-copy (clipboard + confirmation).
class _CopyableResult extends StatelessWidget {
  const _CopyableResult({required this.payload, required this.muted});

  final String payload;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: payload));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(AppStrings.taskDetailCopied)),
          );
        }
      },
      child: Semantics(
        label: '${AppStrings.taskDetailCopy}: $payload',
        button: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(payload, style: BuddyTheme.mono(muted, size: 12)),
            const SizedBox(height: BuddySpacing.s1),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(Icons.copy_outlined, size: 14, color: muted),
                ),
                const SizedBox(width: BuddySpacing.s1),
                Text(
                  AppStrings.taskDetailCopy,
                  style: BuddyTheme.mono(muted, size: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
