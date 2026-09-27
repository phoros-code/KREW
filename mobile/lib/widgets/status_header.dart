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
    //
    // Track C2: text scaling clamps at 1.3 so the 56px row never overflows,
    // and pills use Flexible + FittedBox.scaleDown + ellipsis so 320dp +
    // scale 1.3 still fits. Outer Semantics exclude inner Icon/Text
    // (double-announce fix: the pill label alone announces).
    final TextScaler capped = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3);
    return Container(
      height: 56,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: BuddySpacing.s4),
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: capped),
        child: Row(
          children: <Widget>[
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                // Track C4 motion: the ONE purposeful animation — the
                // NEAR/FAR pill cross-fades on transition (200ms). Keyed by
                // mode (+cause, so a cause change also fades) so the
                // switcher sees a new child only on real transitions.
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _Pill(
                    key: ValueKey<String>(
                      'prox-${near ? 'near' : 'far'}-${farReason ?? ''}',
                    ),
                    color: proxText,
                    dot: proxDot,
                    icon: near ? Icons.lock_open : Icons.lock_outline,
                    label: near ? 'NEAR' : 'FAR',
                    semantic: proxSemantic,
                  ),
                ),
              ),
            ),
            const SizedBox(width: BuddySpacing.s2),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: _Pill(
                  color: connText,
                  dot: connDot,
                  icon: connIcon,
                  label: connLabel,
                  semantic: connSemantic,
                ),
              ),
            ),
            const SizedBox(width: BuddySpacing.s2),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Semantics(
                    label: runningCount > 0
                        ? '$runningCount tasks running'
                        : 'No tasks running',
                    excludeSemantics: true,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        ExcludeSemantics(
                          child: Icon(
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
                        ),
                        const SizedBox(width: BuddySpacing.s2),
                        Text(
                          runningCount > 0
                              ? '$runningCount RUNNING'
                              : 'IDLE',
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
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
    super.key,
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
    // Track C2: the outer label announces the pill meaning; inner icon +
    // text are excluded so screen readers hear it exactly once
    // (double-announce fix). Icons are decorative here.
    return Semantics(
      label: semantic ?? label,
      excludeSemantics: true,
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
            ExcludeSemantics(child: Icon(icon, size: 13, color: color)),
            const SizedBox(width: BuddySpacing.s1),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: color,
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
