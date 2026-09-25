import 'package:flutter/material.dart';

import '../services/buddy_api.dart';
import '../services/proximity_service.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';
import '../widgets/screen_preview.dart';
import 'calibrate_screen.dart';

/// Screen-preview tab: a consent-gated placeholder pointed at GET /screen.
/// The preview never auto-starts; [ScreenPreview] owns the consent flow and
/// the 501 / 403 / offline states.
///
/// The proximity calibration section ([CalibrateScreen]) renders inline
/// below the preview in the same scroll when [proximityService] and
/// [onCalibrated] are supplied — tab count stays at four, so no
/// IndexedStack index assumptions change. Both are optional so older call
/// sites keep compiling.
class PreviewScreen extends StatelessWidget {
  const PreviewScreen({
    super.key,
    required this.api,
    required this.proximity,
    this.proximityService,
    this.onCalibrated,
  });

  final BuddyApi? api;
  final ProximityMode proximity;
  final ProximityService? proximityService;
  final Future<void> Function()? onCalibrated;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;
    final ProximityService? service = proximityService;
    final Future<void> Function()? applied = onCalibrated;
    return ConsoleColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Laptop screen',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: BuddySpacing.s2),
          Text(
            'Near-only, consent-gated live view. Nothing starts until you ask it to.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: BuddySpacing.s4),
          ScreenPreview(api: api, proximity: proximity),
          if (service != null && applied != null) ...<Widget>[
            const SizedBox(height: BuddySpacing.s4),
            Divider(color: hairline, height: 1),
            const SizedBox(height: BuddySpacing.s4),
            CalibrateScreen(
              api: api,
              proximity: service,
              onThresholdApplied: applied,
            ),
          ],
        ],
      ),
    );
  }
}
