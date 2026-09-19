import 'package:flutter/material.dart';

import '../models/task_item.dart';
import '../theme/buddy_theme.dart';

/// Status badge — the ONLY task status indicator in the app.
///
/// Colors are exactly the DESIGN.md status meaning table:
///   queued  warning #D9932A · running primary #1E5F4A
///   done    success #3A8B5C · failed  error   #C4453D
/// Every badge carries a text label (UI_UX_GUIDE: a dot that needs an
/// explanation gets a label instead of a bare dot).
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final TaskStatus status;

  Color _color() {
    switch (status) {
      case TaskStatus.queued:
        return BuddyColors.warning;
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
    final Color color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: BuddySpacing.s2,
        vertical: BuddySpacing.s1,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: const BorderRadius.all(
          Radius.circular(BuddyRadii.interactive),
        ),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
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
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
