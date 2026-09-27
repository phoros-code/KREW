import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/buddy_event.dart';
import '../services/buddy_api.dart';
import '../services/proximity_service.dart';
import '../services/voice_recorder.dart';
import '../theme/buddy_theme.dart';
import '../widgets/command_bar.dart';
import '../widgets/status_badge.dart';
import '../models/task_item.dart';

/// Chat screen: POST /command, render the SSE /events stream.
///
/// Layout follows the console-column primitive: scrollable log region +
/// fixed bottom command bar. FAR mode disables the bar with an explanatory
/// empty state (notifications only, per API.md proximity table).
///
/// Track C4: the log is a virtualized [ListView.builder] (not an eager
/// 200-row Column) driven by [_logController]. New arrivals keep the pixel
/// position unless the view sits at the newest edge (offset ≈ 0), in which
/// case it follows by staying at 0. Scrolled-away arrivals raise the
/// token-styled "jump to newest" pill (a11y-labelled, instant jumpTo — no
/// animation, per the one-animation rule).
///
/// Track C4 rebuild scoping: proximity-dependent chrome (subtitle +
/// command bar) listens via [ListenableBuilder] on [ProximityService]; the
/// log rows never subscribe, so a BLE pulse rebuilds ONLY the header pills
/// (app shell), the subtitle, the bar, and the calibrate section — never
/// the log list.
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
    this.onRefresh,
    this.suspendSignal = 0,
    this.voiceRecorder,
    this.voiceTranscriber,
    this.voicePermissionGate,
  });

  final BuddyApi? api;
  final List<BuddyEvent> events;
  final ProximityService proximity;
  final Future<void> Function(String text) onSend;
  final String? streamError;
  final bool streamConnected;
  final VoidCallback onRetryStream;

  /// Track C3 pull-to-refresh: re-runs the shell reconnect + proximity
  /// config fetch. Null keeps the log static (tests).
  final Future<void> Function()? onRefresh;

  /// Lifecycle suspend counter from the app shell (Track B4): forwarded to
  /// the command bar, which discards an active voice recording on every
  /// bump (backgrounding) — same signal the preview revokes on.
  final int suspendSignal;

  /// Track B4 voice seams, forwarded to the command bar (fakes in tests).
  final VoiceRecorder? voiceRecorder;
  final VoiceTranscriber? voiceTranscriber;
  final MicPermissionGate? voicePermissionGate;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  String? _sendError;
  bool _sending = false;

  /// Track C2: error-card focus target — requested when the send error
  /// appears so screen readers land on it.
  final FocusNode _sendErrorFocus = FocusNode();

  /// Track C4 virtualized log controller + follow state.
  late final ScrollController _logController;
  bool _showJump = false;

  /// Newest-edge threshold (px from offset 0). Newest rows live at the top
  /// (newest-first), so "at newest" means pinned to the top.
  static const double _newestEdge = 64;

  @override
  void initState() {
    super.initState();
    _logController = ScrollController();
    _logController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events.length != widget.events.length) {
      final bool wasAtNewest = _isAtNewest;
      if (wasAtNewest) {
        // Follow: new rows arrived while pinned to the newest edge — stay
        // pinned (instant, no animation per the one-animation rule).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_logController.hasClients) return;
          if (_logController.offset != 0) {
            _logController.jumpTo(0);
          }
          if (_showJump && mounted) setState(() => _showJump = false);
        });
      } else {
        // Scrolled away: keep pixel position, raise the jump pill.
        if (mounted && !_showJump) setState(() => _showJump = true);
      }
    }
  }

  bool get _isAtNewest {
    if (!_logController.hasClients) return true;
    return _logController.offset <= _newestEdge;
  }

  void _onScroll() {
    final bool atNewest = _isAtNewest;
    if (atNewest && _showJump) {
      setState(() => _showJump = false);
    }
  }

  void _jumpToNewest() {
    if (!_logController.hasClients) return;
    _logController.jumpTo(0);
    if (mounted) setState(() => _showJump = false);
  }

  @override
  void dispose() {
    _logController.removeListener(_onScroll);
    _logController.dispose();
    _sendErrorFocus.dispose();
    super.dispose();
  }

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
      if (!mounted) return;
      setState(() => _sendError = _humanizeSend(e));
      // Track C2: move focus to the error card when it appears.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sendErrorFocus.requestFocus();
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _humanizeSend(BuddyApiException e) {
    switch (e.code) {
      case 'unauthorized':
        return AppStrings.chatSendUnauthorized;
      case 'token_expired':
        return AppStrings.chatSendTokenExpired;
      case 'forbidden':
        return AppStrings.chatSendForbidden;
      case 'locked_out':
        return AppStrings.chatSendLockedOut;
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
    final Color errorText = dark
        ? BuddyColors.errorOnDark
        : BuddyColors.errorOnLight;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;

    final bool paired = widget.api != null;

    // Header widgets (title + proximity subtitle + error states) scroll with
    // the log as the first ListView items — same visual order as before,
    // virtualized log rows after. The subtitle item subscribes to proximity
    // via ListenableBuilder so BLE pulses rebuild ONLY it (plus the bottom
    // bar), never the log rows.
    final List<Widget> header = <Widget>[
      Text(
        AppStrings.chatTitle,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: BuddySpacing.s2),
      ListenableBuilder(
        listenable: widget.proximity,
        builder: (BuildContext context, Widget? _) {
          final bool far = !widget.proximity.isNear;
          return Text(
            far
                ? AppStrings.chatSubtitleFar
                : AppStrings.chatSubtitleLive,
            style: small,
          );
        },
      ),
      const SizedBox(height: BuddySpacing.s4),
      if (widget.streamError != null) ...<Widget>[
        Semantics(
          label: 'Live updates paused: ${widget.streamError}',
          container: true,
          child: Container(
            padding: const EdgeInsets.all(BuddySpacing.s4),
            decoration: BoxDecoration(
              border: Border.all(color: errorText),
              borderRadius: const BorderRadius.all(
                Radius.circular(BuddyRadii.container),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(
                    Icons.error_outline,
                    size: 18,
                    color: errorText,
                  ),
                ),
                const SizedBox(width: BuddySpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        AppStrings.chatStreamErrorTitle,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: errorText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: BuddySpacing.s1),
                      Text(widget.streamError!, style: small),
                      const SizedBox(height: BuddySpacing.s3),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: 48,
                          minWidth: 48,
                        ),
                        child: OutlinedButton(
                          onPressed: widget.onRetryStream,
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
              ],
            ),
          ),
        ),
        const SizedBox(height: BuddySpacing.s4),
      ],
      if (_sendError != null) ...<Widget>[
        Focus(
          focusNode: _sendErrorFocus,
          child: Semantics(
            label: 'Send failed: $_sendError',
            container: true,
            child: Container(
              padding: const EdgeInsets.all(BuddySpacing.s3),
              decoration: BoxDecoration(
                border: Border.all(color: errorText),
                borderRadius: const BorderRadius.all(
                  Radius.circular(BuddyRadii.container),
                ),
              ),
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(
                      Icons.error_outline,
                      size: 16,
                      color: errorText,
                    ),
                  ),
                  const SizedBox(width: BuddySpacing.s2),
                  Expanded(child: Text(_sendError!, style: small)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: BuddySpacing.s4),
      ],
    ];

    final bool showEmptyUnpaired = !paired;
    final bool showEmptyLog =
        paired && widget.events.isEmpty && widget.streamError == null;

    // Total items: header + (empty box OR log rows).
    final int logCount = showEmptyUnpaired || showEmptyLog
        ? 1
        : widget.events.length;
    final int itemCount = header.length + logCount;

    Widget logList = ListView.builder(
      controller: _logController,
      physics: widget.onRefresh == null
          ? null
          : const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(BuddySpacing.s4),
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (index < header.length) return header[index];
        final int logIndex = index - header.length;
        if (showEmptyUnpaired) {
          return _EmptyState(
            icon: Icons.laptop_outlined,
            title: AppStrings.chatEmptyUnpairedTitle,
            hint: AppStrings.chatEmptyUnpairedHint,
            muted: muted,
            hairline: hairline,
          );
        }
        if (showEmptyLog) {
          return _EmptyState(
            icon: Icons.chat_bubble_outline,
            title: widget.streamConnected
                ? AppStrings.chatEmptyNoCommandsTitle
                : AppStrings.chatEmptyConnectingTitle,
            hint: widget.streamConnected
                ? AppStrings.chatEmptyNoCommandsHint
                : AppStrings.chatEmptyConnectingHint,
            muted: muted,
            hairline: hairline,
          );
        }
        final BuddyEvent event = widget.events[logIndex];
        return Padding(
          padding: const EdgeInsets.only(bottom: BuddySpacing.s3),
          child: _LogRow(
            event: event,
            status: _statusFor(event),
            hairline: hairline,
            muted: muted,
          ),
        );
      },
    );

    final Future<void> Function()? refresh = widget.onRefresh;
    final Widget scroll = refresh == null
        ? logList
        : RefreshIndicator(onRefresh: refresh, child: logList);

    return Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              scroll,
              if (_showJump)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: BuddySpacing.s4,
                  child: Center(
                    child: Semantics(
                      label: 'New messages arrived, jump to newest',
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
        ),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: hairline)),
          ),
          padding: const EdgeInsets.all(BuddySpacing.s4),
          child: SafeArea(
            top: false,
            child: ListenableBuilder(
              listenable: widget.proximity,
              builder: (BuildContext context, Widget? _) {
                final bool offline = widget.proximity.isOffline;
                final bool far = !widget.proximity.isNear;
                final bool barEnabled =
                    paired && widget.proximity.commandsAllowed;
                final String? barReason = !paired
                    ? AppStrings.chatBarUnpaired
                    : offline
                    ? AppStrings.chatBarOffline
                    : far
                    ? AppStrings.chatBarFar
                    : widget.streamConnected
                    ? null
                    : AppStrings.chatBarConnecting;
                return CommandBar(
                  enabled: barEnabled,
                  sending: _sending,
                  disabledReason: barReason,
                  onSend: _send,
                  api: widget.api,
                  recorder: widget.voiceRecorder,
                  transcriber: widget.voiceTranscriber,
                  permissionGate: widget.voicePermissionGate,
                  suspendSignal: widget.suspendSignal,
                );
              },
            ),
          ),
        ),
      ],
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
          Text(event.describe(), style: BuddyTheme.mono(muted, size: 12)),
        ],
      ),
    );
  }

  String _eventTitle(BuddyEvent e) {
    switch (e.type) {
      case 'task_started':
        return AppStrings.chatEventStarted;
      case 'tool_call':
        return 'Tool: ${e.tool ?? 'unknown'}';
      case 'task_completed':
        return AppStrings.chatEventDone;
      case 'task_failed':
        return AppStrings.chatEventFailed;
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
