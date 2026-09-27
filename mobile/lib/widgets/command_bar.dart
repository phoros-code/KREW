import 'dart:async';
import 'dart:io' show Directory, File;

import 'package:flutter/material.dart';
import 'package:record/record.dart' show Amplitude;

import '../l10n/strings.dart';
import '../services/buddy_api.dart';
import '../services/voice_recorder.dart';
import '../theme/buddy_theme.dart';
import 'a11y.dart';
import 'voice_level_meter.dart';

/// Fixed bottom command bar for the console-column primitive.
///
/// When [enabled] is false (FAR proximity or offline) the input is disabled
/// and [disabledReason] explains why — an explicit empty state, not a dead
/// grey box.
///
/// Track B4 phone voice: a 48dp mic button (Semantics "Record voice
/// command") records up to 30s with a live timer + real amplitude meter
/// (the DESIGN.md `listening` state), then transcribes via
/// POST /voice/transcribe. A confident result fills the field for review —
/// it is NEVER auto-sent. The mic renders only when a transcriber exists
/// ([api] or [transcriber]); [recorder]/[permissionGate] are test seams.
class CommandBar extends StatefulWidget {
  const CommandBar({
    super.key,
    required this.enabled,
    required this.onSend,
    this.disabledReason,
    this.sending = false,
    this.api,
    this.recorder,
    this.transcriber,
    this.permissionGate,
    this.suspendSignal = 0,
  });

  final bool enabled;
  final Future<void> Function(String text) onSend;
  final String? disabledReason;
  final bool sending;

  /// Pinned API backing the default transcriber. Null in tests that inject
  /// [transcriber] directly (or when unpaired — the mic stays hidden then).
  final BuddyApi? api;

  /// Injected recorder for widget tests (production lazily owns a
  /// [RecordVoiceRecorder]).
  final VoiceRecorder? recorder;

  /// Injected transcription for widget tests (defaults to [api].transcribe).
  final VoiceTranscriber? transcriber;

  /// Injected mic-permission gate for widget tests (defaults to the OS
  /// microphone request).
  final MicPermissionGate? permissionGate;

  /// Lifecycle suspend counter from the app shell — every bump means "stop
  /// now" (backgrounding): an active recording is discarded, mirroring the
  /// preview revoke-on-suspend contract.
  final int suspendSignal;

  @override
  State<CommandBar> createState() => _CommandBarState();
}

/// Voice capture phases. `error` covers permission denial, empty/low
/// transcription (retry state), 501, and transport failures — [AppStrings]
/// copy per case via [_humanizeVoice].
enum _VoicePhase { idle, recording, transcribing, error }

class _CommandBarState extends State<CommandBar> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;

  _VoicePhase _voice = _VoicePhase.idle;
  VoiceRecorder? _voiceRecorder;
  bool _ownsRecorder = false;
  String? _voicePath;
  String? _voiceError;
  Timer? _recTimer;
  int _recSeconds = 0;
  double _voiceLevel = 0;
  StreamSubscription<Amplitude>? _ampSub;

  /// Generation guard: every async voice hop checks it, so a cancel or a
  /// suspend discards stale stop/transcribe results instead of filling the
  /// field from a dead take.
  int _voiceGen = 0;

  /// Max capture length (server STT cap is 5MB; 30s of 16kHz mono wav is
  /// ~1MB — comfortably inside).
  static const int voiceMaxSeconds = 30;

  /// The mic renders only when enabled AND a transcriber exists. Existing
  /// call sites without [api]/[transcriber] (all current tests) see the
  /// exact pre-B4 bar — no layout or behavior change.
  bool get _micReady =>
      widget.enabled && (widget.api != null || widget.transcriber != null);

  VoiceRecorder _recorder() {
    final VoiceRecorder? existing = _voiceRecorder;
    if (existing != null) return existing;
    final VoiceRecorder fresh =
        widget.recorder ?? RecordVoiceRecorder();
    _ownsRecorder = widget.recorder == null;
    return _voiceRecorder = fresh;
  }

  @override
  void didUpdateWidget(CommandBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.suspendSignal > oldWidget.suspendSignal) {
      // App backgrounded: an active recording stops now (discarded).
      // A transcribing take is left to finish — filling a text field needs
      // no foreground mic.
      if (_voice == _VoicePhase.recording) {
        unawaited(_cancelVoice());
      }
    }
  }

  @override
  void dispose() {
    _voiceGen++;
    _recTimer?.cancel();
    _recTimer = null;
    unawaited(_ampSub?.cancel());
    _ampSub = null;
    final VoiceRecorder? recorder = _voiceRecorder;
    if (recorder != null) {
      if (_voice == _VoicePhase.recording) {
        unawaited(recorder.cancel());
      }
      if (_ownsRecorder) {
        unawaited(recorder.dispose());
      }
    }
    _voiceRecorder = null;
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String text = _controller.text.trim();
    if (text.isEmpty || !widget.enabled || _busy || widget.sending) return;
    setState(() => _busy = true);
    try {
      await widget.onSend(text);
      // Unmounted while sending (tab switch disposes the bar): the
      // controller is gone — return before touching it.
      if (!mounted) return;
      _controller.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _fmtClock(int totalSeconds) {
    final int m = totalSeconds ~/ 60;
    final int s = totalSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _humanizeVoice(BuddyApiException e) {
    switch (e.code) {
      case 'not_implemented':
        return AppStrings.voiceNotImplemented;
      case 'body_too_large':
        return AppStrings.voiceTooLarge;
      default:
        return e.message;
    }
  }

  /// Best-effort temp-file cleanup. Fire-and-forget on purpose: the delete
  /// never gates UI state, and awaiting dart:io futures inside FakeAsync
  /// widget tests stalls them (real async would need runAsync). Errors
  /// (already-gone temp) are swallowed — a leftover wav is harmless.
  void _deleteVoiceFile(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      File(path).delete().ignore();
    } catch (_) {
      // A synchronously-throwing delete is equally harmless.
    }
  }

  /// Mic tap: permission → record (max 30s, live timer + amplitude meter).
  Future<void> _startVoice() async {
    if (_voice != _VoicePhase.idle || !_micReady) return;
    final int gen = ++_voiceGen;
    final MicPermissionGate gate =
        widget.permissionGate ?? requestMicPermission;
    bool granted = false;
    try {
      granted = await gate();
    } catch (_) {
      granted = false;
    }
    if (!mounted || gen != _voiceGen) return;
    if (!granted) {
      setState(() {
        _voice = _VoicePhase.error;
        _voiceError = AppStrings.voicePermissionDenied;
      });
      announceLiveRegion(AppStrings.voicePermissionDenied);
      return;
    }
    final String path =
        '${Directory.systemTemp.path}/buddy_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    try {
      await _recorder().start(path);
    } catch (_) {
      if (!mounted || gen != _voiceGen) return;
      setState(() {
        _voice = _VoicePhase.error;
        _voiceError = AppStrings.voiceStartFailed;
      });
      announceLiveRegion(AppStrings.voiceStartFailed);
      return;
    }
    if (!mounted || gen != _voiceGen) return;
    setState(() {
      _voice = _VoicePhase.recording;
      _voicePath = path;
      _voiceError = null;
      _recSeconds = 0;
      _voiceLevel = 0;
    });
    announceVoiceRecording();
    unawaited(_ampSub?.cancel());
    _ampSub = _recorder()
        .amplitudeTicks(const Duration(milliseconds: 100))
        .listen(
          (Amplitude amp) {
            if (!mounted || gen != _voiceGen) return;
            setState(
              () => _voiceLevel = VoiceLevelMeter.normalize(amp.current),
            );
          },
          onError: (_) {},
        );
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted || gen != _voiceGen) {
        t.cancel();
        return;
      }
      if (_recSeconds + 1 >= voiceMaxSeconds) {
        t.cancel();
        unawaited(_stopAndTranscribe());
      } else {
        setState(() => _recSeconds++);
      }
    });
  }

  /// Stop tap (or 30s auto-stop): stop capture → transcribe → fill for
  /// review on confidence ≥ 0.5, retry state on empty/low, human copy on
  /// typed errors. NEVER auto-sends.
  Future<void> _stopAndTranscribe() async {
    if (_voice != _VoicePhase.recording) return;
    final int gen = ++_voiceGen;
    _recTimer?.cancel();
    _recTimer = null;
    // Best-effort (never awaited): broadcast-subscription cancel futures
    // do not resume inside FakeAsync widget tests, and gating the
    // transcribing UI on stream cleanup would stall the panel either way.
    unawaited(_ampSub?.cancel());
    _ampSub = null;
    setState(() {
      _voice = _VoicePhase.transcribing;
      _voiceLevel = 0;
    });
    String? stopped;
    try {
      stopped = await _recorder().stop();
    } catch (_) {
      stopped = null;
    }
    final String audioPath = (stopped != null && stopped.isNotEmpty)
        ? stopped
        : (_voicePath ?? '');
    if (!mounted || gen != _voiceGen) return;
    final BuddyApi? api = widget.api;
    final VoiceTranscriber transcribe =
        widget.transcriber ??
        (String p) {
          if (api == null) {
            throw const BuddyApiException(
              code: 'unpaired',
              message: 'Pair with the laptop first.',
            );
          }
          return api.transcribe(p);
        };
    Transcription result;
    try {
      result = await transcribe(audioPath);
    } on BuddyApiException catch (e) {
      if (!mounted || gen != _voiceGen) return;
      final String message = _humanizeVoice(e);
      setState(() {
        _voice = _VoicePhase.error;
        _voiceError = message;
      });
      announceLiveRegion(message);
      return;
    } catch (_) {
      if (!mounted || gen != _voiceGen) return;
      setState(() {
        _voice = _VoicePhase.error;
        _voiceError = BuddyApi.routeError.message;
      });
      announceLiveRegion(BuddyApi.routeError.message);
      return;
    }
    if (!mounted || gen != _voiceGen) return;
    _deleteVoiceFile(audioPath);
    if (result.text.isEmpty || result.confidence < 0.5) {
      setState(() {
        _voice = _VoicePhase.error;
        _voiceError = AppStrings.voiceEmptyRetry;
      });
      announceLiveRegion(AppStrings.voiceEmptyRetry);
      return;
    }
    setState(() {
      _voice = _VoicePhase.idle;
      _voiceError = null;
      _voicePath = null;
      _recSeconds = 0;
      _voiceLevel = 0;
    });
    _controller.text = result.text;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    announceVoiceReady();
  }

  /// Cancel: discard the take (or the error), never fill, never send.
  Future<void> _cancelVoice() async {
    ++_voiceGen;
    _recTimer?.cancel();
    _recTimer = null;
    // Best-effort (see _stopAndTranscribe): never gate the reset on it.
    unawaited(_ampSub?.cancel());
    _ampSub = null;
    final String? path = _voicePath;
    try {
      await _recorder().cancel();
    } catch (_) {
      // Discarding must never throw into the widget tree.
    }
    _deleteVoiceFile(path);
    if (!mounted) return;
    setState(() {
      _voice = _VoicePhase.idle;
      _voiceError = null;
      _voicePath = null;
      _recSeconds = 0;
      _voiceLevel = 0;
    });
  }

  /// Retry from an error panel: back to idle, then straight into capture.
  Future<void> _retryVoice() async {
    if (!mounted) return;
    setState(() {
      _voice = _VoicePhase.idle;
      _voiceError = null;
    });
    await _startVoice();
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted = dark
        ? BuddyColors.inkMutedOnDark
        : BuddyColors.inkMutedOnLight;
    final Color warningText = dark
        ? BuddyColors.warningOnDark
        : BuddyColors.warningOnLight;
    final Color errorText = dark
        ? BuddyColors.errorOnDark
        : BuddyColors.errorOnLight;
    final bool busy = _busy || widget.sending;
    final bool active = widget.enabled && !busy;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!widget.enabled && widget.disabledReason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: BuddySpacing.s2),
            child: Semantics(
              label:
                  'Command bar unavailable: ${widget.disabledReason}',
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: warningText,
                    ),
                  ),
                  const SizedBox(width: BuddySpacing.s2),
                  Expanded(
                    child: Text(
                      widget.disabledReason!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_voice == _VoicePhase.recording) _recordingPanel(muted),
        if (_voice == _VoicePhase.transcribing) _transcribingPanel(),
        if (_voice == _VoicePhase.error && _voiceError != null)
          _voiceErrorPanel(errorText),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: active,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: widget.enabled
                      ? 'Ask the laptop to do something…'
                      : 'Command bar unavailable',
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (_micReady) ...<Widget>[
              const SizedBox(width: BuddySpacing.s2),
              // Explicit Semantics (not just the tooltip): icon-only
              // buttons need a stable screen-reader label. excludeSemantics
              // keeps the tooltip subtree from doubling the announcement.
              Semantics(
                label: AppStrings.voiceMicLabel,
                button: true,
                excludeSemantics: true,
                child: IconButton(
                  icon: const Icon(Icons.mic, size: 20),
                  tooltip: AppStrings.voiceMicLabel,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  onPressed: _voice == _VoicePhase.idle ? _startVoice : null,
                ),
              ),
            ],
            const SizedBox(width: BuddySpacing.s2),
            // Track C2: ConstrainedBox(minHeight:48) instead of a fixed
            // 48px box — grows with text scaling, never shrinks below the
            // 48dp tap target.
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: ElevatedButton(
                onPressed: active ? _submit : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                child: busy
                    ? Semantics(
                        label: 'Sending command, please wait',
                        child: const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          ExcludeSemantics(
                            child: Icon(Icons.send, size: 16),
                          ),
                          SizedBox(width: BuddySpacing.s2),
                          Text('Send'),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// DESIGN.md `listening` state: accent dot + live timer + the real
  /// amplitude meter (width tracks the recorder, no decorative glow).
  Widget _recordingPanel(Color muted) {
    final String clock =
        '${_fmtClock(_recSeconds)} / ${_fmtClock(voiceMaxSeconds)}';
    return Semantics(
      label:
          '${AppStrings.voiceRecordingLabel}, $_recSeconds seconds of $voiceMaxSeconds',
      container: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ExcludeSemantics(
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: BuddyColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: BuddySpacing.s2),
              Expanded(
                child: Text(clock, style: BuddyTheme.mono(muted)),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton(
                  onPressed: _stopAndTranscribe,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: const Text(AppStrings.voiceStop),
                ),
              ),
              const SizedBox(width: BuddySpacing.s2),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: TextButton(
                  onPressed: _cancelVoice,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: const Text(AppStrings.actionCancel),
                ),
              ),
            ],
          ),
          const SizedBox(height: BuddySpacing.s2),
          VoiceLevelMeter(level: _voiceLevel),
          const SizedBox(height: BuddySpacing.s3),
        ],
      ),
    );
  }

  Widget _transcribingPanel() {
    return Semantics(
      label: AppStrings.voiceTranscribing,
      container: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: BuddySpacing.s2),
              Expanded(
                child: Text(
                  AppStrings.voiceTranscribing,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: TextButton(
                  onPressed: _cancelVoice,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: const Text(AppStrings.actionCancel),
                ),
              ),
            ],
          ),
          const SizedBox(height: BuddySpacing.s3),
        ],
      ),
    );
  }

  Widget _voiceErrorPanel(Color errorText) {
    final String message = _voiceError!;
    return Semantics(
      label: 'Voice input failed: $message',
      container: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ExcludeSemantics(
                child: Icon(
                  Icons.error_outline,
                  size: 16,
                  color: errorText,
                ),
              ),
              const SizedBox(width: BuddySpacing.s2),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: BuddySpacing.s2),
          Row(
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: OutlinedButton(
                  onPressed: _retryVoice,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: const Text(AppStrings.actionRetry),
                ),
              ),
              const SizedBox(width: BuddySpacing.s2),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: TextButton(
                  onPressed: _cancelVoice,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: const Text(AppStrings.actionCancel),
                ),
              ),
            ],
          ),
          const SizedBox(height: BuddySpacing.s3),
        ],
      ),
    );
  }
}
