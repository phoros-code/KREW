import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../theme/buddy_theme.dart';

/// Status badge — the ONLY task status indicator in the app.
///
/// Colors are exactly the DESIGN.md status meaning table + Track C1
/// accessible text variants:
///   queued  warning base #D9932A (dot) / warningOnLight #8A5A12 or
///           warningOnDark #E1A955 (11px label, ≥4.5:1)
///   running primary #1E5F4A (unchanged)
///   done    success base #3A8B5C (dot) / successOnLight #2E6F4A or
///           successOnDark #4E976C (label)
///   failed  error base #C4453D (dot) / errorOnLight #B03E37 or
///           errorOnDark #D06A64 (label)
/// Every badge carries a text label (UI_UX_GUIDE: a dot that needs an
/// explanation gets a label instead of a bare dot).
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final TaskStatus status;

  Color _textColor(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    switch (status) {
      case TaskStatus.queued:
        return dark ? BuddyColors.warningOnDark : BuddyColors.warningOnLight;
      case TaskStatus.running:
        return BuddyColors.primary;
      case TaskStatus.done:
        return dark ? BuddyColors.successOnDark : BuddyColors.successOnLight;
      case TaskStatus.failed:
        return dark ? BuddyColors.errorOnDark : BuddyColors.errorOnLight;
    }
  }

  Color _dotColor(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    switch (status) {
      case TaskStatus.queued:
        // Base warning #D9932A fails 3:1 on light (2.34:1) — use the
        // accessible dark-amber fill there. On dark the base passes (7.19).
        return dark ? BuddyColors.warning : BuddyColors.warningOnLight;
      case TaskStatus.running:
        return BuddyColors.primary;
      case TaskStatus.done:
        return BuddyColors.success;
      case TaskStatus.failed:
        return BuddyColors.error;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color text = _textColor(context);
    final Color dot = _dotColor(context);
    // Track C2: label includes the status text; inner dot + text are
    // excluded so the badge announces exactly once.
    return Semantics(
      label: 'Task status: ${status.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: BuddySpacing.s2,
          vertical: BuddySpacing.s1,
        ),
        decoration: BoxDecoration(
          color: text.withValues(alpha: 0.12),
          borderRadius: const BorderRadius.all(
            Radius.circular(BuddyRadii.interactive),
          ),
          border: Border.all(color: text.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: BuddySpacing.s2),
            Text(
              status.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: text,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
