import 'package:flutter/material.dart';

import '../theme/buddy_theme.dart';

/// DESIGN.md `listening` indicator (Track B4 phone voice).
///
/// A real level meter, not decoration: [level] is the live recorder
/// amplitude (0.0 silence … 1.0 loudest) and the accent fill width tracks it
/// tick by tick. No glow, no animation controller — width changes are
/// state-driven, so the NEAR/FAR cross-fade stays the app's only animation
/// (one-animation rule). Excluded from semantics: the recording label and
/// timer text already carry the state for screen readers.
class VoiceLevelMeter extends StatelessWidget {
  const VoiceLevelMeter({super.key, required this.level});

  /// Normalized live amplitude, 0.0 (silence) to 1.0 (loudest).
  final double level;

  /// dBFS floor for normalization: the `record` plugin reports silence
  /// around -60…-45 and speech around -30…-10, so -50 maps quiet room tone
  /// to ~0 while speech visibly moves the bar. Pure — unit tested.
  static double normalize(double dbfs, {double floor = -50}) {
    if (dbfs >= 0) return 1;
    if (dbfs <= floor) return 0;
    return (dbfs - floor) / -floor;
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color track = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;
    final double clamped = level.clamp(0.0, 1.0);
    return ExcludeSemantics(
      child: Container(
        height: BuddySpacing.s2,
        decoration: BoxDecoration(
          color: track,
          borderRadius: const BorderRadius.all(
            Radius.circular(BuddyRadii.interactive),
          ),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: clamped,
            child: Container(
              decoration: const BoxDecoration(
                color: BuddyColors.accent,
                borderRadius: BorderRadius.all(
                  Radius.circular(BuddyRadii.interactive),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
