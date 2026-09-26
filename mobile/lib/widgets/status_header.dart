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
    this.farReason,
  });

  final ProximityMode proximity;
  final BuddyConnection connection;
  final int runningCount;

  /// Known FAR cause from the BLE watch (Track A5.9: "Bluetooth off",
  /// "Permission denied — …"). Explanatory only — carried on the FAR pill's
  /// semantic label so screen readers announce it. No visual change: the
  /// 56px box, pills, and tokens are untouched.
  final String? farReason;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;

    final bool near = proximity == ProximityMode.near;
    // Track C1: pill text/icons use accessible OnLight/OnDark variants
    // (≥4.5:1); 6px dots keep the base hues where they already pass 3:1.
    final Color proxText = near
        ? (dark ? BuddyColors.successOnDark : BuddyColors.successOnLight)
        : (dark ? BuddyColors.warningOnDark : BuddyColors.warningOnLight);
    final Color proxDot = near
        ? BuddyColors.success
        : (dark ? BuddyColors.warning : BuddyColors.warningOnLight);
    final String proxSemantic = near
        ? 'Proximity near — full control available'
        : (farReason == null
              ? 'Proximity far — notifications only, commands blocked'
              : 'Proximity far — $farReason');

    final Color connText;
    final Color connDot;
    final String connLabel;
    final String connSemantic;
    final IconData connIcon;
    switch (connection) {
      case BuddyConnection.online:
        connText = dark
            ? BuddyColors.successOnDark
            : BuddyColors.successOnLight;
        connDot = BuddyColors.success;
        connLabel = 'ONLINE';
        connSemantic = 'Connection online — laptop reachable';
        connIcon = Icons.wifi;
      case BuddyConnection.offline:
        connText = dark ? BuddyColors.errorOnDark : BuddyColors.errorOnLight;
        connDot = BuddyColors.error;
        connLabel = 'OFFLINE';
        connSemantic = 'Connection offline — no route to laptop';
        connIcon = Icons.wifi_off;
      case BuddyConnection.unknown:
        connText = dark
            ? BuddyColors.warningOnDark
            : BuddyColors.warningOnLight;
        connDot = dark ? BuddyColors.warning : BuddyColors.warningOnLight;
        connLabel = 'CONNECTING';
        connSemantic = 'Connection connecting — opening the live stream';
        connIcon = Icons.wifi_find;
    }

    // Fixed 56px content box with NO inner SafeArea (Track A5.2): Scaffold
    // sizes the appBar slot from preferredSize and adds the system top
    // padding itself, so an inner SafeArea double-counted the notch and
    // clipped the pills. Pills align to the 56px box on every device.
    return Container(
      height: 56,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: BuddySpacing.s4),
      child: Row(
        children: <Widget>[
          _Pill(
            color: proxText,
            dot: proxDot,
            icon: near ? Icons.lock_open : Icons.lock_outline,
            label: near ? 'NEAR' : 'FAR',
            semantic: proxSemantic,
          ),
          const SizedBox(width: BuddySpacing.s2),
          _Pill(
            color: connText,
            dot: connDot,
            icon: connIcon,
            label: connLabel,
            semantic: connSemantic,
          ),
          const Spacer(),
          Semantics(
            label: runningCount > 0
                ? '$runningCount tasks running'
                : 'No tasks running',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  runningCount > 0
                      ? Icons.sync
                      : Icons.check_circle_outline,
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
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.color,
    required this.dot,
    required this.icon,
    required this.label,
    this.semantic,
  });

  final Color color;
  final Color dot;
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
          color: color.withValues(alpha: 0.12),
          borderRadius: const BorderRadius.all(
            Radius.circular(BuddyRadii.interactive),
          ),
          border: Border.all(color: color.withValues(alpha: 0.45)),
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
