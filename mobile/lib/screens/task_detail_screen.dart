import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/buddy_event.dart';
import '../models/task_item.dart';
import '../models/task_log.dart';
import '../theme/buddy_theme.dart';
import '../widgets/status_badge.dart';

/// Track C3: per-task log view. Pushed when a task row (or a notification
/// history row) is tapped — NOT a new tab.
///
/// Shows the full event list for one task, oldest first: tool calls render
/// with redacted args (length+sha via [redactedArgsSummary], never raw),
/// results/errors render in full with tap-to-copy. Console-column primitive,
/// DESIGN.md tokens only, no new hues.
///
/// Track C4: the event list is a virtualized [ListView.builder] (not an
/// eager Column) driven by a [ScrollController] — the same controller
/// pattern as the chat log. Events are oldest-first so the newest edge is
/// the bottom: arrivals follow only when already at the bottom, otherwise
/// the token-styled "jump to newest" pill appears (instant jumpTo, no
/// animation per the one-animation rule).
class TaskDetailScreen extends StatefulWidget {
  const TaskDetailScreen({
    super.key,
    required this.task,
    required this.events,
  });

  final TaskItem task;
  final List<BuddyEvent> events;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  late final ScrollController _controller;
  bool _showJump = false;

  static const double _bottomEdge = 64;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(TaskDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events.length != widget.events.length) {
      final bool wasAtBottom = _isAtBottom;
      if (wasAtBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_controller.hasClients) return;
          final double max = _controller.position.maxScrollExtent;
          if (_controller.offset < max) {
            _controller.jumpTo(max);
          }
          if (_showJump && mounted) setState(() => _showJump = false);
        });
      } else {
        if (mounted && !_showJump) setState(() => _showJump = true);
      }
    }
  }

  bool get _isAtBottom {
    if (!_controller.hasClients) return true;
    final double max = _controller.position.maxScrollExtent;
    return max - _controller.offset <= _bottomEdge;
  }

  void _onScroll() {
    if (_isAtBottom && _showJump) {
      setState(() => _showJump = false);
    }
  }

  void _jumpToNewest() {
    if (!_controller.hasClients) return;
    _controller.jumpTo(_controller.position.maxScrollExtent);
    if (mounted) setState(() => _showJump = false);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

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

    // Header widgets scroll with the log as the first ListView items —
    // same visual order as before (task card + events header), then the
    // virtualized event rows, then the Close button as the final item.
    final List<Widget> header = <Widget>[
      Semantics(
        label: 'Task ${widget.task.id}, status ${widget.task.status.label}',
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                StatusBadge(status: widget.task.status),
                const SizedBox(width: BuddySpacing.s2),
                Expanded(
                  child: Text(
                    widget.task.id,
                    style: BuddyTheme.mono(muted, size: 11.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              widget.task.title,
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
    ];

    final bool empty = widget.events.isEmpty;
    // Items: header + (empty box with its Close OR event rows + Close).
    final int itemCount =
        header.length + (empty ? 1 : widget.events.length + 1);

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.taskDetailTitle)),
      body: Stack(
        children: <Widget>[
          ListView.builder(
            controller: _controller,
            padding: const EdgeInsets.all(BuddySpacing.s4),
            itemCount: itemCount,
            itemBuilder: (BuildContext context, int index) {
              if (index < header.length) return header[index];
              final int afterHeader = index - header.length;
              if (empty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
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
                );
              }
              if (afterHeader < widget.events.length) {
                final BuddyEvent event = widget.events[afterHeader];
                return Padding(
                  padding: const EdgeInsets.only(bottom: BuddySpacing.s3),
                  child: _DetailEventRow(
                    event: event,
                    hairline: hairline,
                    muted: muted,
                    small: small,
                  ),
                );
              }
              // Trailing Close button.
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
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
              );
            },
          ),
          if (_showJump)
            Positioned(
              left: 0,
              right: 0,
              bottom: BuddySpacing.s4,
              child: Center(
                child: Semantics(
                  label: 'New events arrived, jump to newest',
                  button: true,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(
                          Radius.circular(BuddyRadii.interactive),
                        ),
                      ),
                    ),
                    onPressed: _jumpToNewest,
                    icon: const ExcludeSemantics(
                      child: Icon(Icons.arrow_downward, size: 16),
                    ),
                    label: const Text('Jump to newest'),
                  ),
                ),
              ),
            ),
        ],
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
