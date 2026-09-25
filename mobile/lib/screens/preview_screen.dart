import 'package:flutter/material.dart';

import '../services/buddy_api.dart';
import '../services/proximity_service.dart';
import '../theme/buddy_theme.dart';
import '../widgets/console_column.dart';
import '../widgets/screen_preview.dart';
import 'calibrate_screen.dart';

/// Preview tab: a consent-gated live view of the laptop screen or webcam.
///
/// The preview never auto-starts; [ScreenPreview] owns the consent flow and
/// the 501 / 403 / offline states. The Screen/Webcam segmented control above
/// it switches the consent scope — the two grants are separate server-side,
/// so toggling resets the preview to needsConsent and drops the old grant
/// id (never sent across scopes).
///
/// The proximity calibration section ([CalibrateScreen]) renders inline
/// below the preview in the same scroll when [proximityService] and
/// [onCalibrated] are supplied — tab count stays at four, so no
/// IndexedStack index assumptions change. Both are optional so older call
/// sites keep compiling.
class PreviewScreen extends StatefulWidget {
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
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  PreviewSource _source = PreviewSource.screen;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;
    final ProximityService? service = widget.proximityService;
    final Future<void> Function()? applied = widget.onCalibrated;
    final bool webcam = _source == PreviewSource.webcam;
    return ConsoleColumn(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            webcam ? 'Laptop webcam' : 'Laptop screen',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: BuddySpacing.s2),
          Text(
            'Near-only, consent-gated live view. Nothing starts until you ask it to.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: BuddySpacing.s3),
          // Source toggle: scale-token spacing, 8px interactive radius, flat
          // fill — no gradients, no decorative effects (DESIGN.md).
          SegmentedButton<PreviewSource>(
            segments: const <ButtonSegment<PreviewSource>>[
              ButtonSegment<PreviewSource>(
                value: PreviewSource.screen,
                label: Text('Screen'),
                icon: Icon(Icons.monitor_outlined),
              ),
              ButtonSegment<PreviewSource>(
                value: PreviewSource.webcam,
                label: Text('Webcam'),
                icon: Icon(Icons.videocam_outlined),
              ),
            ],
            selected: <PreviewSource>{_source},
            onSelectionChanged: (Set<PreviewSource> next) =>
                setState(() => _source = next.single),
            style: SegmentedButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(
                  Radius.circular(BuddyRadii.interactive),
                ),
              ),
            ),
            showSelectedIcon: false,
          ),
          const SizedBox(height: BuddySpacing.s4),
          ScreenPreview(
            api: widget.api,
            proximity: widget.proximity,
            source: _source,
          ),
          if (service != null && applied != null) ...<Widget>[
            const SizedBox(height: BuddySpacing.s4),
            Divider(color: hairline, height: 1),
            const SizedBox(height: BuddySpacing.s4),
            CalibrateScreen(
              api: widget.api,
              proximity: service,
              onThresholdApplied: applied,
            ),
          ],
        ],
      ),
    );
  }
}
