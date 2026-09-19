import 'package:flutter/material.dart';

import '../services/buddy_api.dart';
import '../services/proximity_service.dart';
import '../theme/buddy_theme.dart';

/// Consent-gated screen preview pointed at GET /screen.
///
/// SECURITY.md + API.md rules enforced here:
/// - The stream NEVER auto-starts on screen open. A network call happens
///   only after the user taps the consent button.
/// - The server returns 501 until the Phase 3 MJPEG work lands — that error
///   state is designed, not a crash.
/// - FAR proximity blocks the preview (near-only endpoint → 403).
class ScreenPreview extends StatefulWidget {
  const ScreenPreview({
    super.key,
    required this.api,
    required this.proximity,
  });

  final BuddyApi? api;
  final ProximityMode proximity;

  @override
  State<ScreenPreview> createState() => _ScreenPreviewState();
}

enum _PreviewPhase { needsConsent, checking, notImplemented, error, ready }

class _ScreenPreviewState extends State<ScreenPreview> {
  _PreviewPhase _phase = _PreviewPhase.needsConsent;
  String _errorMessage = '';

  Future<void> _requestWithConsent() async {
    if (widget.api == null) return;
    setState(() {
      _phase = _PreviewPhase.checking;
      _errorMessage = '';
    });
    final ScreenStatus status = await widget.api!.checkScreen();
    if (!mounted) return;
    setState(() {
      switch (status) {
        case ScreenStatus.available:
          _phase = _PreviewPhase.ready;
        case ScreenStatus.notImplemented:
          _phase = _PreviewPhase.notImplemented;
        case ScreenStatus.forbidden:
          _phase = _PreviewPhase.error;
          _errorMessage =
              'Screen preview needs near proximity. Move closer to the laptop and try again.';
        case ScreenStatus.unauthorized:
          _phase = _PreviewPhase.error;
          _errorMessage =
              'The pairing token was rejected. Re-pair from the Pair tab.';
        case ScreenStatus.unreachable:
          _phase = _PreviewPhase.error;
          _errorMessage =
              'No route to the laptop — check the IP and Wi-Fi, then retry.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted = dark
        ? BuddyColors.inkMutedOnDark
        : BuddyColors.inkMutedOnLight;
    final Color hairline = dark
        ? BuddyColors.hairlineOnDark
        : BuddyColors.hairlineOnLight;
    final TextStyle? body = Theme.of(context).textTheme.bodyMedium;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;

    if (widget.api == null) {
      // Empty state: nothing to preview until pairing exists.
      return _Frame(
        hairline: hairline,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.monitor_outlined, size: 32, color: muted),
            const SizedBox(height: BuddySpacing.s3),
            Text(
              'No laptop paired yet',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              'Pair from the Pair tab first — then you can request a screen preview here.',
              style: small,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (widget.proximity == ProximityMode.far &&
        _phase != _PreviewPhase.error) {
      // FAR blocks a near-only endpoint — say so plainly.
      return _Frame(
        hairline: hairline,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.lock_outline,
              size: 32,
              color: BuddyColors.warning,
            ),
            const SizedBox(height: BuddySpacing.s3),
            Text(
              'Preview unavailable while FAR',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: BuddySpacing.s2),
            Text(
              'Screen preview is a near-only endpoint. Move closer to the laptop — you can still follow task notifications from the Chat and Tasks tabs.',
              style: small,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    switch (_phase) {
      case _PreviewPhase.needsConsent:
        return _Frame(
          hairline: hairline,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.monitor_outlined, size: 20, color: muted),
                  const SizedBox(width: BuddySpacing.s2),
                  Text(
                    'Screen preview',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: BuddySpacing.s2),
              Text(
                'This shows everything on the laptop screen — including other windows and anything being typed. Frames are streamed live and never saved.',
                style: small,
              ),
              const SizedBox(height: BuddySpacing.s4),
              ElevatedButton(
                onPressed: _requestWithConsent,
                child: const Text('I understand — start preview'),
              ),
            ],
          ),
        );
      case _PreviewPhase.checking:
        return _Frame(
          hairline: hairline,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: BuddyColors.primary,
                ),
              ),
              const SizedBox(height: BuddySpacing.s3),
              Text('Requesting preview…', style: body),
            ],
          ),
        );
      case _PreviewPhase.notImplemented:
        // Designed 501 state: the server stub ships before the MJPEG work.
        return _Frame(
          hairline: hairline,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.monitor_outlined, size: 32, color: muted),
              const SizedBox(height: BuddySpacing.s3),
              Text(
                'Screen preview is not on this server yet',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: BuddySpacing.s2),
              Text(
                'The laptop answered 501 (not implemented). The MJPEG stream lands with the server-side Phase 3 work — your pairing still works for commands and task updates.',
                style: small,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: BuddySpacing.s4),
              OutlinedButton(
                onPressed: _requestWithConsent,
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      case _PreviewPhase.error:
        return _Frame(
          hairline: hairline,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.error_outline,
                size: 32,
                color: BuddyColors.error,
              ),
              const SizedBox(height: BuddySpacing.s3),
              Text(
                'Preview failed',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: BuddySpacing.s2),
              Text(
                _errorMessage,
                style: small,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: BuddySpacing.s4),
              OutlinedButton(
                onPressed: _requestWithConsent,
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      case _PreviewPhase.ready:
        // The endpoint answered 200. The MJPEG renderer is intentionally
        // minimal here — full adaptive rendering follows the server work.
        return _Frame(
          hairline: hairline,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.monitor,
                    size: 20,
                    color: BuddyColors.primary,
                  ),
                  const SizedBox(width: BuddySpacing.s2),
                  Text(
                    'Stream endpoint reachable',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: BuddySpacing.s2),
              Text(
                'The laptop accepted the preview request. Live MJPEG frames will render in this frame once the adaptive-rate player lands.',
                style: small,
              ),
              const SizedBox(height: BuddySpacing.s4),
              OutlinedButton(
                onPressed: () => setState(
                  () => _phase = _PreviewPhase.needsConsent,
                ),
                child: const Text('Stop preview'),
              ),
            ],
          ),
        );
    }
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.hairline, required this.child});

  final Color hairline;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // One container level only — whitespace does the rest (UI_UX_GUIDE).
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(BuddySpacing.s4),
      decoration: BoxDecoration(
        border: Border.all(color: hairline),
        borderRadius: const BorderRadius.all(
          Radius.circular(BuddyRadii.container),
        ),
      ),
      child: child,
    );
  }
}
