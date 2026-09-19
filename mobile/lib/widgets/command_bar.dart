import 'package:flutter/material.dart';

import '../theme/buddy_theme.dart';

/// Fixed bottom command bar for the console-column primitive.
///
/// When [enabled] is false (FAR proximity or offline) the input is disabled
/// and [disabledReason] explains why — an explicit empty state, not a dead
/// grey box.
class CommandBar extends StatefulWidget {
  const CommandBar({
    super.key,
    required this.enabled,
    required this.onSend,
    this.disabledReason,
    this.sending = false,
  });

  final bool enabled;
  final Future<void> Function(String text) onSend;
  final String? disabledReason;
  final bool sending;

  @override
  State<CommandBar> createState() => _CommandBarState();
}

class _CommandBarState extends State<CommandBar> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled || _busy || widget.sending) return;
    setState(() => _busy = true);
    try {
      await widget.onSend(text);
      _controller.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted = dark
        ? BuddyColors.inkMutedOnDark
        : BuddyColors.inkMutedOnLight;
    final bool busy = _busy || widget.sending;
    final bool active = widget.enabled && !busy;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!widget.enabled && widget.disabledReason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: BuddySpacing.s2),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: BuddyColors.warning,
                ),
                const SizedBox(width: BuddySpacing.s2),
                Expanded(
                  child: Text(
                    widget.disabledReason!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: active,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: widget.enabled
                      ? 'Ask the laptop to do something…'
                      : 'Command bar unavailable',
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: BuddySpacing.s2),
            SizedBox(
              height: BuddySpacing.s7,
              child: ElevatedButton(
                onPressed: active ? _submit : null,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.send, size: 16),
                          SizedBox(width: BuddySpacing.s2),
                          Text('Send'),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
