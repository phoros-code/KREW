import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
// Intentional src import: the package barrel only exports MJPEGStreamScreen
// (unusable here: no headers/auth/TLS-pinning, no error callback,
// DESIGN-violating built-in UI), so the frame validator is only reachable
// via src. Pinned ^1.0.0 with this path verified in the pub cache
// (mjpeg_stream-1.0.1/lib/src/mjpeg_stream_processor.dart).
// ignore: implementation_imports
import 'package:mjpeg_stream/src/mjpeg_stream_processor.dart';

import '../services/buddy_api.dart';
import '../theme/buddy_theme.dart';
import 'a11y.dart';

/// Authenticated MJPEG player for the consent-gated GET /screen stream.
///
/// API ADAPTATION — mjpeg_stream 1.0.1 (verified from the pub cache, not the
/// task sketch): the package exports `MJPEGStreamScreen`, not `Mjpeg`, and it
/// cannot drive this endpoint as-is —
/// * it sends a bare GET with an internal plain Client: no way to attach the
///   Bearer token or the X-Consent-Id grant;
/// * the client is not injectable, so the SHA-256-pinned TLS trust
///   (BuddyApi.newPinnedClient, required by the self-signed dev cert) cannot
///   be applied — every handshake would fail like the old pairing bug;
/// * it exposes no error callback, so a mid-stream consent expiry could never
///   route back through checkScreen;
/// * its built-in error UI (CupertinoButton, hardcoded red-on-black,
///   shadowed container, default "MOKZ Studio" watermark) violates DESIGN.md.
///
/// So this widget owns the authenticated + pinned stream itself and reuses
/// the package's [MjpegPreprocessor] for JPEG frame validation — the
/// dependency stays wired and meaningful.
///
/// Mounting starts the stream from initState. That is NOT an auto-start
/// violation: this widget is only mounted in the preview `ready` phase, which
/// is reachable solely via two explicit taps (Request preview, Check again)
/// plus out-of-band laptop approval. ScreenPreview itself still makes zero
/// network calls in build/initState.
class MjpegPlayer extends StatefulWidget {
  const MjpegPlayer({
    super.key,
    required this.streamUrl,
    required this.headers,
    required this.onRetry,
    required this.onStop,
    this.client,
    this.certFingerprint,
    this.stallTimeout = const Duration(seconds: 5),
    this.semanticLabel = 'Laptop screen preview, live',
  });

  /// Full stream URL including `?consent_id=` (BuddyApi.screenStreamUrl).
  /// Never rendered: the query carries the live grant, so only the host is
  /// shown (mono caption, no secret).
  final String streamUrl;

  /// Bearer token + X-Consent-Id grant (BuddyApi.authHeaders + header).
  final Map<String, String> headers;

  /// Parent re-probes the grant (checkScreen) and routes: still approved →
  /// fresh stream, pending → awaitingApproval, denied/expired → human error.
  final VoidCallback onRetry;

  /// Parent revokes the grant first, then resets to needsConsent.
  final VoidCallback onStop;

  /// Injectable transport for tests. Production leaves this null and gets a
  /// pinned client built from [certFingerprint].
  final http.Client? client;

  /// SHA-256 pin the stream handshake trusts (same pin as the pairing).
  /// Null/empty trusts nothing — fail closed, like BuddyApi.
  final String? certFingerprint;

  /// Bytes-idle budget (Track A5.3): no chunk for this long after the
  /// stream opened means the preview ended server-side — same ended state
  /// as a clean close. Injectable so tests run on milliseconds.
  final Duration stallTimeout;

  /// Track C2: live-region label for the streaming frame
  /// ("Laptop screen preview, live" / "Laptop webcam preview, live").
  final String semanticLabel;

  @override
  State<MjpegPlayer> createState() => _MjpegPlayerState();
}

class _MjpegPlayerState extends State<MjpegPlayer> {
  /// Task contract (the package default is 5s).
  static const Duration _timeout = Duration(seconds: 10);

  /// Bound the reassembly buffer: server frames are ≤1280px JPEGs (~1MB), so
  /// 8MB without a complete frame means the stream stopped framing — drop
  /// the oldest bytes instead of growing forever.
  static const int _maxBuffer = 8 * 1024 * 1024;

  final MjpegPreprocessor _preprocessor = MjpegPreprocessor();

  http.Client? _ownedClient;
  StreamSubscription<List<int>>? _sub;
  Timer? _stallTimer;
  // Track C4 frame bytes: contiguous byte-view buffer with a consumed
  // prefix offset — appends copy once via setRange (owning the socket bytes
  // is unavoidable), scans run in place with zero copies, and a complete
  // frame copies exactly once into its own Uint8List for Image.memory.
  // Trimming past the 8MB budget only advances the offset (no copy);
  // compaction memmoves only when the dead prefix grows large (amortized).
  Uint8List _buf = Uint8List(1024);
  int _length = 0;
  int _consumed = 0;
  Uint8List? _frame;
  bool _failed = false;
  bool _ended = false;

  http.Client get _transport => widget.client ?? _ownedClient!;

  @override
  void initState() {
    super.initState();
    // Mount == explicit consent (see class doc): the ready phase that owns
    // this widget is only reachable via taps + laptop approval.
    if (widget.client == null) {
      _ownedClient = BuddyApi.newPinnedClient(widget.certFingerprint);
    }
    _start();
  }

  @override
  void dispose() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _sub?.cancel();
    _sub = null;
    // Only close what we created — an injected test/mock client belongs to
    // its owner.
    _ownedClient?.close();
    super.dispose();
  }

  /// (Re)arm the bytes-idle watchdog: every chunk resets it; firing means
  /// the server stopped framing — same ended state as a clean close.
  void _armStallWatchdog() {
    _stallTimer?.cancel();
    _stallTimer = Timer(widget.stallTimeout, () {
      if (!mounted || _failed || _ended) return;
      _sub?.cancel();
      _sub = null;
      setState(() => _ended = true);
      // Track C2: live-region announcement (polite).
      announceLiveRegion(previewEndedMessage);
    });
  }

  void _onStreamDone() {
    _stallTimer?.cancel();
    if (mounted && !_failed && !_ended) {
      setState(() => _ended = true);
      announceLiveRegion(previewEndedMessage);
    }
  }

  Future<void> _start() async {
    try {
      final http.Request request =
          http.Request('GET', Uri.parse(widget.streamUrl));
      request.headers.addAll(widget.headers);
      final http.StreamedResponse response =
          await _transport.send(request).timeout(_timeout);
      // Unmounted while connecting: drop the just-opened response instead
      // of listening into a dead widget (unmount-during-connect leak).
      if (!mounted) {
        await response.stream.listen((_) {}).cancel();
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Drain the small error body so the connection can be reused, then
        // show the designed error state (Retry routes via onRetry, which
        // re-probes the grant — never a blind reconnect spin).
        await response.stream.bytesToString();
        if (!mounted) return;
        setState(() => _failed = true);
        return;
      }
      _armStallWatchdog();
      _sub = response.stream.listen(
        _onChunk,
        onError: (_) {
          _stallTimer?.cancel();
          if (mounted) setState(() => _failed = true);
        },
        onDone: _onStreamDone,
        cancelOnError: true,
      );
    } on Object {
      // Transport failure (timeout, TLS pin reject, socket reset): designed
      // error state. The human message lives in the parent, which knows the
      // grant state via checkScreen.
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Reassemble JPEG frames (SOI 0xFFD8 … EOI 0xFFD9) from the byte stream —
  /// the same framing the mjpeg_stream package scans for — then validate each
  /// candidate with the package's [MjpegPreprocessor] before painting.
  ///
  /// Track C4: zero-copy scan + single-copy frame. Appends own the chunk
  /// once (setRange); completed frames allocate exactly one Uint8List.
  void _onChunk(List<int> chunk) {
    if (_failed || _ended) return;
    _armStallWatchdog();
    _append(chunk);
    // Bound the reassembly buffer: server frames are ≤1280px JPEGs (~1MB),
    // so 8MB without a complete frame means the stream stopped framing —
    // drop the oldest bytes (offset advance, no copy) instead of growing.
    if (_length - _consumed > _maxBuffer) {
      _consumed = _length - _maxBuffer;
      _maybeCompact();
    }
    while (true) {
      final int start = _frameStart(_buf, _consumed, _length);
      if (start < 0) {
        // No frame start: keep at most the last byte (a split SOI's 0xFF may
        // dangle at the buffer end). Offset advance, no copy.
        if (_length - _consumed > 1) {
          _consumed = _length - 1;
          _maybeCompact();
        }
        return;
      }
      final int end = _frameEnd(_buf, start + 2, _length);
      if (end < 0) {
        // Incomplete frame: drop junk before SOI, wait for more bytes.
        if (start > _consumed) {
          _consumed = start;
          _maybeCompact();
        }
        return;
      }
      // Single copy: frame bytes detach from the reusable buffer.
      final int frameLen = end + 2 - start;
      final Uint8List frameBytes = Uint8List(frameLen);
      frameBytes.setRange(0, frameLen, _buf, start);
      _consumed = end + 2;
      _maybeCompact();
      if (_preprocessor.process(frameBytes) != null) {
        if (!mounted) return;
        setState(() => _frame = frameBytes);
      }
    }
  }

  /// Append [chunk] to the reusable buffer, growing exponentially.
  /// One copy (owning the socket bytes); capacity growth amortizes.
  void _append(List<int> chunk) {
    if (chunk.isEmpty) return;
    final int needed = _length + chunk.length;
    if (needed > _buf.length) {
      int capacity = _buf.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final Uint8List grown = Uint8List(capacity);
      if (_length > 0) {
        grown.setRange(0, _length, _buf);
      }
      _buf = grown;
    }
    _buf.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
  }

  /// Compact the dead prefix when it grows large so the buffer does not walk
  /// forward forever. Amortized: at most one memmove per compaction.
  void _maybeCompact() {
    if (_consumed == 0) return;
    if (_consumed < 65536 && _consumed < _buf.length ~/ 2) return;
    final int live = _length - _consumed;
    if (live > 0) {
      _buf.setRange(0, live, _buf, _consumed);
    }
    _length = live;
    _consumed = 0;
  }

  /// Index of the next JPEG start-of-image marker in [bytes[from:end]], or -1.
  static int _frameStart(List<int> bytes, int from, int end) {
    for (int i = from; i + 1 < end; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  /// Index of the end-of-image marker closing the frame, or -1.
  static int _frameEnd(List<int> bytes, int from, int end) {
    for (int i = from; i + 1 < end; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted =
        dark ? BuddyColors.inkMutedOnDark : BuddyColors.inkMutedOnLight;
    final Color errorText =
        dark ? BuddyColors.errorOnDark : BuddyColors.errorOnLight;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    // Host only — the URL query carries the live grant and is never shown.
    final String host = Uri.tryParse(widget.streamUrl)?.host ?? '';
    final Uint8List? frame = _frame;
    final bool showError = _failed || _ended;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showError)
          Semantics(
            label: _ended
                ? 'Preview ended. The laptop closed the preview stream.'
                : 'Stream dropped — retry. The live frames stopped.',
            container: true,
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ExcludeSemantics(
                  child: Icon(
                    Icons.error_outline,
                    size: 32,
                    color: errorText,
                  ),
                ),
                const SizedBox(height: BuddySpacing.s3),
                Text(
                  _ended ? 'Preview ended' : 'Stream dropped — retry',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: BuddySpacing.s2),
                Text(
                  _ended
                      ? 'The laptop closed the preview stream. Retry re-checks the grant with the laptop; nothing reconnects blindly.'
                      : 'The live frames stopped — the grant may have expired. Retry re-checks with the laptop; nothing reconnects blindly.',
                  style: small,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: BuddySpacing.s4),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    onPressed: widget.onRetry,
                    child: const Text('Retry'),
                  ),
                ),
              ],
            ),
          )
        else if (frame == null)
          Semantics(
            label: 'Starting live preview, please wait',
            container: true,
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  width: BuddySpacing.s5,
                  height: BuddySpacing.s5,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: BuddyColors.primary,
                  ),
                ),
                const SizedBox(height: BuddySpacing.s3),
                Text('Starting live preview…', style: small),
              ],
            ),
          )
        else
          Semantics(
            label: widget.semanticLabel,
            image: true,
            liveRegion: true,
            excludeSemantics: true,
            child: ClipRRect(
              borderRadius: const BorderRadius.all(
                Radius.circular(BuddyRadii.container),
              ),
              child: Image.memory(
                frame,
                width: double.infinity,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                excludeFromSemantics: true,
              ),
            ),
          ),
        if (host.isNotEmpty) ...<Widget>[
          const SizedBox(height: BuddySpacing.s2),
          Text(
            host,
            style: BuddyTheme.mono(muted),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: BuddySpacing.s3),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            onPressed: widget.onStop,
            child: const Text('Stop preview'),
          ),
        ),
      ],
    );
  }
}
