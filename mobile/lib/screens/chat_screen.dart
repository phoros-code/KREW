import 'package:flutter/material.dart';

import '../models/buddy_event.dart';
import '../services/buddy_api.dart';
import '../services/proximity_service.dart';
import '../theme/buddy_theme.dart';
import '../widgets/command_bar.dart';
import '../widgets/console_column.dart';
import '../widgets/status_badge.dart';
import '../models/task_item.dart';

/// Chat screen: POST /command, render the SSE /events stream.
///
/// Layout follows the console-column primitive: scrollable log region +
/// fixed bottom command bar. FAR mode disables the bar with an explanatory
/// empty state (notifications only, per API.md proximity table).
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.api,
    required this.events,
    required this.proximity,
    required this.onSend,
    required this.streamError,
    required this.streamConnected,
    required this.onRetryStream,
  });

  final BuddyApi? api;
  final List<BuddyEvent> events;
  final ProximityService proximity;
  final Future<void> Function(String text) onSend;
  final String? streamError;
  final bool streamConnected;
  final VoidCallback onRetryStream;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  String? _sendError;
  bool _sending = false;

  TaskStatus? _statusFor(BuddyEvent e) {
    switch (e.type) {
      case 'task_started':
        return TaskStatus.running;
      case 'task_completed':
        return TaskStatus.done;
      case 'task_failed':
        return TaskStatus.failed;
      default:
        return null;
    }
  }

  Future<void> _send(String text) async {
    setState(() {
      _sendError = null;
      _sending = true;
    });
    try {
      await widget.onSend(text);
    } on BuddyApiException catch (e) {
      setState(() => _sendError = _humanizeSend(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _humanizeSend(BuddyApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return 'The laptop rejected the token. Re-pair from the Pair tab.';
      case 'token_expired':
        return 'The pairing token reached its age limit. Re-pair from the Pair tab.';
      case 'forbidden':
        return 'Blocked: commands need near proximity. You are on notifications-only until you move closer.';
      case 'locked_out':
        return 'The laptop locked out after too many attempts. Wait, then retry.';
      case 'unreachable':
        return e.message;
      default:
        return e.message;
    }
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

    final bool paired = widget.api != null;
    final bool far = !widget.proximity.isNear;
    final bool offline = widget.proximity.isOffline;
    final bool barEnabled = paired && widget.proximity.commandsAllowed;

    final String? barReason = !paired
        ? 'Pair with the laptop first.'
        : offline
        ? 'Laptop unreachable — commands are paused until the connection returns.'
        : far
        ? 'FAR mode: notifications only. Move closer to the laptop to send commands.'
        : widget.streamConnected
        ? null
        : 'Connecting to the laptop…';

    return ConsoleColumn(
      bottomBar: CommandBar(
        enabled: barEnabled,
        sending: _sending,
        disabledReason: barReason,
        onSend: _send,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Agent log', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: BuddySpacing.s2),
          Text(
            far
                ? 'FAR mode — following task notifications. Commands unlock when you are near.'
                : 'Live task activity from the laptop. Newest first.',
            style: small,
          ),
          const SizedBox(height: BuddySpacing.s4),

          // Stream error state (designed, not raw JSON).
          if (widget.streamError != null)
            Container(
              padding: const EdgeInsets.all(BuddySpacing.s4),
              decoration: BoxDecoration(
                border: Border.all(color: BuddyColors.error),
                borderRadius: const BorderRadius.all(
                  Radius.circular(BuddyRadii.container),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.error_outline,
                    size: 18,
                    color: BuddyColors.error,
                  ),
                  const SizedBox(width: BuddySpacing.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Live updates paused',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: BuddyColors.error,
                          ),
                        ),
                        const SizedBox(height: BuddySpacing.s1),
                        Text(widget.streamError!, style: small),
                        const SizedBox(height: BuddySpacing.s3),
                        OutlinedButton(
                          onPressed: widget.onRetryStream,
                          child: const Text('Reconnect'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (widget.streamError != null)
            const SizedBox(height: BuddySpacing.s4),

          // Send error state.
          if (_sendError != null)
            Container(
              padding: const EdgeInsets.all(BuddySpacing.s3),
              decoration: BoxDecoration(
                border: Border.all(color: BuddyColors.error),
                borderRadius: const BorderRadius.all(
                  Radius.circular(BuddyRadii.interactive),
                ),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.error_outline,
                    size: 16,
                    color: BuddyColors.error,
                  ),
                  const SizedBox(width: BuddySpacing.s2),
                  Expanded(child: Text(_sendError!, style: small)),
                ],
              ),
            ),
          if (_sendError != null) const SizedBox(height: BuddySpacing.s4),

          // Empty states.
          if (!paired)
            _EmptyState(
              icon: Icons.laptop_outlined,
              title: 'No laptop paired yet',
              hint:
                  'Pair from the Pair tab — then send your first command here.',
              muted: muted,
              hairline: hairline,
            )
          else if (widget.events.isEmpty && widget.streamError == null)
            _EmptyState(
              icon: Icons.chat_bubble_outline,
              title: widget.streamConnected
                  ? 'No commands yet'
                  : 'Connecting to the laptop…',
              hint: widget.streamConnected
                  ? 'Send a command below — results stream back here as the agent works.'
                  : 'Opening the live event stream. This usually takes a second.',
              muted: muted,
              hairline: hairline,
            )
          else
            for (final BuddyEvent event in widget.events)
              Padding(
                padding: const EdgeInsets.only(bottom: BuddySpacing.s3),
                child: _LogRow(
                  event: event,
                  status: _statusFor(event),
                  hairline: hairline,
                  muted: muted,
                ),
              ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.event,
    required this.status,
    required this.hairline,
    required this.muted,
  });

  final BuddyEvent event;
  final TaskStatus? status;
  final Color hairline;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    // Whitespace + one hairline row — not a card stack (UI_UX_GUIDE).
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
              if (status != null) StatusBadge(status: status!),
              if (status != null) const SizedBox(width: BuddySpacing.s2),
              Expanded(
                child: Text(
                  _eventTitle(event),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: BuddySpacing.s2),
          Text(
            event.describe(),
            style: BuddyTheme.mono(muted, size: 12),
          ),
        ],
      ),
    );
  }

  String _eventTitle(BuddyEvent e) {
    switch (e.type) {
      case 'task_started':
        return 'Task started';
      case 'tool_call':
        return 'Tool: ${e.tool ?? 'unknown'}';
      case 'task_completed':
        return 'Task done';
      case 'task_failed':
        return 'Task failed';
      default:
        return e.type;
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.hint,
    required this.muted,
    required this.hairline,
  });

  final IconData icon;
  final String title;
  final String hint;
  final Color muted;
  final Color hairline;

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
