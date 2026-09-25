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
  List<int> _carry = <int>[];
  Uint8List? _frame;
  bool _failed = false;

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
    _sub?.cancel();
    // Only close what we created — an injected test/mock client belongs to
    // its owner.
    _ownedClient?.close();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final http.Request request =
          http.Request('GET', Uri.parse(widget.streamUrl));
      request.headers.addAll(widget.headers);
      final http.StreamedResponse response =
          await _transport.send(request).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Drain the small error body so the connection can be reused, then
        // show the designed error state (Retry routes via onRetry, which
        // re-probes the grant — never a blind reconnect spin).
        await response.stream.bytesToString();
        if (!mounted) return;
        setState(() => _failed = true);
        return;
      }
      _sub = response.stream.listen(
        _onChunk,
        onError: (_) {
          if (mounted) setState(() => _failed = true);
        },
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
  void _onChunk(List<int> chunk) {
    _carry.addAll(chunk);
    if (_carry.length > _maxBuffer) {
      _carry = _carry.sublist(_carry.length - _maxBuffer);
    }
    while (true) {
      final int start = _frameStart(_carry, 0);
      if (start < 0) {
        // No frame start: keep at most the last byte (a split SOI's 0xFF may
        // dangle at the buffer end).
        if (_carry.length > 1) _carry = _carry.sublist(_carry.length - 1);
        return;
      }
      final int end = _frameEnd(_carry, start + 2);
      if (end < 0) {
        // Incomplete frame: drop junk before SOI, wait for more bytes.
        if (start > 0) _carry = _carry.sublist(start);
        return;
      }
      final List<int> candidate = _carry.sublist(start, end + 2);
      _carry = _carry.sublist(end + 2);
      if (_preprocessor.process(candidate) != null) {
        if (!mounted) return;
        setState(() => _frame = Uint8List.fromList(candidate));
      }
    }
  }

  /// Index of the next JPEG start-of-image marker at/after [from], or -1.
  static int _frameStart(List<int> bytes, int from) {
    for (int i = from; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) return i;
    }
    return -1;
  }

  /// Index of the end-of-image marker closing the frame, or -1.
  static int _frameEnd(List<int> bytes, int from) {
    for (int i = from; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color muted =
        dark ? BuddyColors.inkMutedOnDark : BuddyColors.inkMutedOnLight;
    final TextStyle? small = Theme.of(context).textTheme.bodySmall;
    // Host only — the URL query carries the live grant and is never shown.
    final String host = Uri.tryParse(widget.streamUrl)?.host ?? '';
    final Uint8List? frame = _frame;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_failed)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.error_outline,
                size: 32,
                color: BuddyColors.error,
              ),
              const SizedBox(height: BuddySpacing.s3),
              Text(
                'Stream dropped — retry',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: BuddySpacing.s2),
              Text(
                'The live frames stopped — the grant may have expired. Retry re-checks with the laptop; nothing reconnects blindly.',
                style: small,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: BuddySpacing.s4),
              OutlinedButton(
                onPressed: widget.onRetry,
                child: const Text('Retry'),
              ),
            ],
          )
        else if (frame == null)
          Column(
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
          )
        else
          ClipRRect(
            borderRadius: const BorderRadius.all(
              Radius.circular(BuddyRadii.container),
            ),
            child: Image.memory(
              frame,
              width: double.infinity,
              fit: BoxFit.contain,
              gaplessPlayback: true,
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
        OutlinedButton(
          onPressed: widget.onStop,
          child: const Text('Stop preview'),
        ),
      ],
    );
  }
}
