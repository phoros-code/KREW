import 'package:flutter/material.dart';

import '../services/buddy_api.dart';
import '../services/proximity_service.dart';
import '../theme/buddy_theme.dart';

/// Proximity-threshold calibration (Sprint 2.3c), rendered inline below the
/// screen preview on the Screen tab.
///
/// A walk-test helper for the BLE RSSI threshold: the phone shows its live
/// reading next to the current server threshold, the user picks a new value
/// with the slider/stepper, and "Set threshold" persists it via
/// POST /proximity/threshold (near only — FAR answers 403 and the UI says
/// "move closer" in plain words). The distance log is local-only scratch
/// space for the walk test; it is never sent anywhere.
///
/// Live values arrive through [proximity] (an [AnimatedBuilder] listener),
/// so this section updates even without a parent rebuild — the app shell
/// already calls setState on proximity changes, which rebuilds too.
class CalibrateScreen extends StatefulWidget {
  const CalibrateScreen({
    super.key,
    required this.api,
    required this.proximity,
    required this.onThresholdApplied,
  });

  final BuddyApi? api;
  final ProximityService proximity;
  final Future<void> Function() onThresholdApplied;

  @override
  State<CalibrateScreen> createState() => _CalibrateScreenState();
}

class _CalibrateScreenState extends State<CalibrateScreen> {
  static const int minThreshold = -100;
  static const int maxThreshold = -30;

  late int _draft;
  final TextEditingController _logController = TextEditingController();
  bool _saving = false;
  String? _error;

  /// Last server threshold the draft was synced from — plain RSSI traffic
  /// must NOT clobber a slider the user is dragging.
  late int _lastThreshold;

  @override
  void initState() {
    super.initState();
    _draft = widget.proximity.rssiNearThreshold
        .clamp(minThreshold, maxThreshold)
        .toInt();
    _lastThreshold = widget.proximity.rssiNearThreshold;
    widget.proximity.addListener(_resyncDraft);
  }

  @override
  void didUpdateWidget(CalibrateScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.proximity != widget.proximity) {
      oldWidget.proximity.removeListener(_resyncDraft);
      widget.proximity.addListener(_resyncDraft);
      _resyncDraft();
    }
  }

  /// Draft resync (Track A5.12): when the SERVER threshold moves under us
  /// (fetch after pairing, apply echo), the draft follows — unless a save
  /// is in flight, in which case the in-flight value wins.
  void _resyncDraft() {
    final int threshold = widget.proximity.rssiNearThreshold;
    if (threshold == _lastThreshold || _saving || !mounted) return;
    _lastThreshold = threshold;
    setState(() {
      _draft = threshold.clamp(minThreshold, maxThreshold).toInt();
    });
  }

  @override
  void dispose() {
    widget.proximity.removeListener(_resyncDraft);
    _logController.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final BuddyApi? api = widget.api;
    if (api == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final ProximityConfig cfg = await api.setProximityThreshold(_draft);
      _lastThreshold = cfg.rssiNearThreshold;
      widget.proximity.setThreshold(cfg.rssiNearThreshold);
      await widget.onThresholdApplied();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Threshold set to ${cfg.rssiNearThreshold} dBm.'),
        ),
      );
    } on BuddyApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = _humanError(e));
    } catch (_) {
      // Non-API failure (dropped scaffold, platform error): still surface
      // something human instead of hanging on the spinner.
      if (!mounted) return;
      setState(() => _error = 'Could not save the threshold — try again.');
    } finally {
      // Latch (Track A5.12): the button ALWAYS comes back, even when the
      // post-apply refresh throws.
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Human messages only — raw JSON never reaches the UI (API.md). The
  /// unreachable envelope from BuddyApi is already human (route vs cert),
  /// so it passes through untouched.
  String _humanError(BuddyApiException e) {
    switch (e.code) {
      case 'forbidden':
        return 'Move closer to the laptop and try again — saving the threshold needs near proximity.';
      case 'unauthorized':
      case 'token_expired':
        return 'The pairing token was rejected. Re-pair from the Pair tab.';
      case 'bad_request':
        return 'That value is out of range — pick between −100 and −30 dBm.';
      default:
        return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.proximity,
      builder: (BuildContext context, Widget? _) {
        final bool dark = Theme.of(context).brightness == Brightness.dark;
        final Color muted = dark
            ? BuddyColors.inkMutedOnDark
            : BuddyColors.inkMutedOnLight;
        final Color ink = dark
            ? BuddyColors.inkOnDark
            : BuddyColors.inkOnLight;
        final Color hairline = dark
            ? BuddyColors.hairlineOnDark
            : BuddyColors.hairlineOnLight;
        final TextStyle? small = Theme.of(context).textTheme.bodySmall;
        final bool paired = widget.api != null;
        final int? rssi = widget.proximity.lastRssi;
        final bool near = widget.proximity.isNear;
        final String? bleCause = widget.proximity.bleCause;
        // Track C1: pill text uses accessible variants (≥4.5:1).
        final Color pillText = near
            ? (dark ? BuddyColors.successOnDark : BuddyColors.successOnLight)
            : (dark ? BuddyColors.warningOnDark : BuddyColors.warningOnLight);
        final Color warningText = dark
            ? BuddyColors.warningOnDark
            : BuddyColors.warningOnLight;
        final Color errorText = dark
            ? BuddyColors.errorOnDark
            : BuddyColors.errorOnLight;

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(BuddySpacing.s4),
          decoration: BoxDecoration(
            border: Border.all(color: hairline),
            borderRadius: const BorderRadius.all(
              Radius.circular(BuddyRadii.container),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Calibrate proximity',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: BuddySpacing.s2),
              Text(
                'Walk the phone from 0.5 m (should read NEAR) to 10 m (should read FAR) and back, pausing ~20 s at each stop — readings go stale after 15 s. Set the threshold to the dBm where it flips, rounded 3–5 dB weaker (more negative), so the edge still counts as FAR.',
                style: small,
              ),
              if (!paired) ...<Widget>[
                const SizedBox(height: BuddySpacing.s3),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.link_off_outlined,
                      size: 16,
                      color: muted,
                    ),
                    const SizedBox(width: BuddySpacing.s2),
                    Expanded(
                      child: Text(
                        'Pair with the laptop first — the threshold lives on the server.',
                        style: small,
                      ),
                    ),
                  ],
                ),
              ],
              // Known FAR cause (Track A5.9): Bluetooth off / permission
              // denied renders here in plain words — never silent FAR.
              if (bleCause != null) ...<Widget>[
                const SizedBox(height: BuddySpacing.s3),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.bluetooth_disabled_outlined,
                      size: 16,
                      color: warningText,
                    ),
                    const SizedBox(width: BuddySpacing.s2),
                    Expanded(
                      child: Text(bleCause, style: small),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: BuddySpacing.s3),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('Live signal', style: small),
                        const SizedBox(height: BuddySpacing.s1),
                        Text(
                          rssi == null ? '—' : '$rssi dBm',
                          style: BuddyTheme.mono(ink, size: 16),
                        ),
                        const SizedBox(height: BuddySpacing.s1),
                        Text(
                          'Threshold ${widget.proximity.rssiNearThreshold} dBm',
                          style: small,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: BuddySpacing.s2,
                      vertical: BuddySpacing.s1,
                    ),
                    decoration: BoxDecoration(
                      color: pillText.withValues(alpha: 0.12),
                      borderRadius: const BorderRadius.all(
                        Radius.circular(BuddyRadii.interactive),
                      ),
                      border: Border.all(
                        color: pillText.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      near ? 'NEAR' : 'FAR',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: pillText,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: BuddySpacing.s3),
              Text(
                'New threshold: $_draft dBm',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Slider(
                value: _draft.toDouble(),
                min: minThreshold.toDouble(),
                max: maxThreshold.toDouble(),
                divisions: maxThreshold - minThreshold,
                label: '$_draft dBm',
                onChanged: !paired || _saving
                    ? null
                    : (double v) => setState(() => _draft = v.round()),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.remove),
                    tooltip: 'Weaker by 1 dB',
                    onPressed: !paired || _saving || _draft <= minThreshold
                        ? null
                        : () => setState(() => _draft--),
                  ),
                  Text('$_draft dBm', style: BuddyTheme.mono(ink)),
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Stronger by 1 dB',
                    onPressed: !paired || _saving || _draft >= maxThreshold
                        ? null
                        : () => setState(() => _draft++),
                  ),
                ],
              ),
              const SizedBox(height: BuddySpacing.s2),
              TextField(
                controller: _logController,
                enabled: paired && !_saving,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Distance log (stays on this phone)',
                  hintText: '0.5m NEAR −52, 4m FAR −74…',
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: BuddySpacing.s2),
                Text(
                  _error!,
                  style: small?.copyWith(color: errorText),
                ),
              ],
              const SizedBox(height: BuddySpacing.s3),
              ElevatedButton(
                onPressed: !paired || _saving ? null : _apply,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Set threshold'),
              ),
            ],
          ),
        );
      },
    );
  }
}
