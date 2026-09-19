import 'package:flutter/material.dart';

import '../services/proximity_service.dart';
import '../theme/buddy_theme.dart';

/// 56px status header — part of the "console column" primitive (DESIGN.md).
/// Always visible: proximity NEAR/FAR text label + status-table color,
/// connection state, and the current task summary. No glow, no gradients —
/// flat fills and text labels only (safety-relevant info must be
/// unambiguous, per UI_UX_GUIDE.md).
class StatusHeader extends StatelessWidget implements PreferredSizeWidget {
  const StatusHeader({
    super.key,
    required this.proximity,
    required this.connection,
    required this.runningCount,
  });

  final ProximityMode proximity;
  final BuddyConnection connection;
  final int runningCount;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;

    final bool near = proximity == ProximityMode.near;
    final Color proxColor = near ? BuddyColors.success : BuddyColors.warning;

    final Color connColor;
    final String connLabel;
    final IconData connIcon;
    switch (connection) {
      case BuddyConnection.online:
        connColor = BuddyColors.success;
        connLabel = 'ONLINE';
        connIcon = Icons.wifi;
      case BuddyConnection.offline:
        connColor = BuddyColors.error;
        connLabel = 'OFFLINE';
        connIcon = Icons.wifi_off;
      case BuddyConnection.unknown:
        connColor = BuddyColors.warning;
        connLabel = 'CONNECTING';
        connIcon = Icons.wifi_find;
    }

    return Container(
      height: 56,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: BuddySpacing.s4),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: <Widget>[
            _Pill(
              color: proxColor,
              icon: near ? Icons.lock_open : Icons.lock_outline,
              label: near ? 'NEAR' : 'FAR',
              semantic: near
                  ? 'Proximity near — full control available'
                  : 'Proximity far — notifications only, commands blocked',
            ),
            const SizedBox(width: BuddySpacing.s2),
            _Pill(color: connColor, icon: connIcon, label: connLabel),
            const Spacer(),
            Icon(
              runningCount > 0 ? Icons.sync : Icons.check_circle_outline,
              size: 16,
              color: runningCount > 0
                  ? BuddyColors.primary
                  : (dark
                        ? BuddyColors.inkMutedOnDark
                        : BuddyColors.inkMutedOnLight),
            ),
            const SizedBox(width: BuddySpacing.s2),
            Text(
              runningCount > 0 ? '$runningCount RUNNING' : 'IDLE',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: runningCount > 0
                    ? BuddyColors.primary
                    : (dark
                          ? BuddyColors.inkMutedOnDark
                          : BuddyColors.inkMutedOnLight),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.color,
    required this.icon,
    required this.label,
    this.semantic,
  });

  final Color color;
  final IconData icon;
  final String label;
  final String? semantic;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semantic ?? label,
      child: Container(
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
            Icon(icon, size: 13, color: color),
            const SizedBox(width: BuddySpacing.s1),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
