import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpException, HandshakeException, SocketException, TlsException, X509Certificate;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/buddy_event.dart';

/// Typed error for every server failure. The server envelope is always
///   {"error": {"code": "...", "message": "..."}}
/// per API.md — the app shows [message] in designed error states, never the
/// raw JSON. See SECURITY.md: no sensitive payloads in logs.
class BuddyApiException implements Exception {
  const BuddyApiException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  /// Parse an HTTP error body of the API.md shape. Never throws.
  static BuddyApiException fromRaw(int statusCode, String body) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final dynamic err = decoded['error'];
        if (err is Map<String, dynamic>) {
          final String code = err['code'] is String
              ? err['code'] as String
              : _codeFor(statusCode);
          final String message = err['message'] is String
              ? err['message'] as String
              : _defaultMessage(statusCode);
          return BuddyApiException(
            code: code,
            message: message,
            statusCode: statusCode,
          );
        }
      }
    } on FormatException {
      // Fall through to the default below.
    }
    return BuddyApiException(
      code: _codeFor(statusCode),
      message: _defaultMessage(statusCode),
      statusCode: statusCode,
    );
  }

  static String _codeFor(int status) {
    switch (status) {
      case 400:
        return 'bad_request';
      case 401:
        return 'unauthorized';
      case 403:
        return 'forbidden';
      case 429:
        return 'locked_out';
      case 501:
        return 'not_implemented';
      default:
        return 'request_failed';
    }
  }

  static String _defaultMessage(int status) {
    switch (status) {
      case 400:
        return 'The request was missing something the server needs.';
      case 401:
        return 'Invalid or expired token.';
      case 403:
        return 'Requires near proximity.';
      case 429:
        return 'Too many failed attempts — try again later.';
      case 501:
        return 'Screen preview ships in Phase 3.';
      default:
        return 'Request failed (HTTP $status).';
    }
  }

  @override
  String toString() => 'BuddyApiException($code): $message';
}

class CommandResult {
  const CommandResult({required this.taskId, required this.status});

  final String taskId;
  final String status;
}

/// Authenticated proximity config from GET /proximity (API.md).
class ProximityConfig {
  const ProximityConfig({required this.mode, required this.rssiNearThreshold});

  final String mode;
  final int rssiNearThreshold;

  bool get usesBluetooth => mode == 'lan_plus_bluetooth';
}

enum ScreenStatus {
  /// GET /screen returned 200 — an MJPEG stream is available.
  available,

  /// GET /screen returned 501 — server Phase 3 work has not landed yet.
  notImplemented,

  /// 403 — near-only endpoint, device is far.
  forbidden,

  /// 403 consent_required — request created, laptop has not approved yet.
  consentRequired,

  /// 403 consent_denied — laptop denied this request; start a new one.
  consentDenied,

  /// 401 — token invalid/expired.
  unauthorized,

  /// No route to the laptop (socket/timeout/TLS).
  unreachable,
}

/// Thin HTTP client for the control server. All traffic is TLS to
/// https://<host>:8443 (see CONFIG.md bind_port, SECURITY.md TLS everywhere).
/// Default port is 8443; the pairing screen accepts a bare IP/hostname and an
/// optional ":port" override.
///
/// TLS trust is by SHA-256 pin, never by system CA: the server uses a
/// self-signed dev cert, so the default client would reject every handshake
/// (and the resulting HandshakeException used to escape uncaught — the
/// spinner-stops-with-no-error pairing bug). The pin is the `Cert SHA256`
/// line from `scripts/pair_device.py`, saved with the pairing and compared
/// against the live cert on every handshake. Anything else is rejected.
class BuddyApi {
  BuddyApi({
    required String host,
    required String token,
    http.Client? client,
    String? certFingerprint,
    Duration timeout = const Duration(seconds: 10),
  }) : _client = client ?? BuddyApi.newPinnedClient(certFingerprint),
       _timeout = timeout,
       certFingerprint = certFingerprint {
    final parsed = BuddyApi.splitHostPort(host);
    _hostname = parsed.host;
    _port = parsed.port;
    _token = token;
  }

  final http.Client _client;
  final Duration _timeout;

  /// Normalized SHA-256 pin this instance trusts (null when a mock client
  /// was injected for unit tests — mocks never touch TLS).
  final String? certFingerprint;
  late final String _hostname;
  late final int _port;
  late final String _token;

  /// Strip separators/case so `6C:9C:AE…`, `6c9cae…`, and pasted variants
  /// with spaces all compare equal. Pure — unit tested.
  static String normalizeFingerprint(String input) =>
      input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();

  /// A pin is usable only if it normalizes to exactly 32 bytes of hex.
  static bool isValidFingerprint(String input) {
    final String n = normalizeFingerprint(input);
    return n.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(n);
  }

  /// True when the DER bytes of the presented cert hash to the pinned value.
  /// Pure — unit tested with a known SHA-256 vector.
  static bool fingerprintMatchesDer(List<int> der, String pinnedFingerprint) =>
      sha256.convert(der).toString() == normalizeFingerprint(pinnedFingerprint);

  /// TLS client that trusts exactly one cert: the pinned fingerprint.
  /// Empty/missing pin trusts nothing (fail closed) — pairing always supplies
  /// one, so an unpinned client can only exist by programmer error.
  static IOClient newPinnedClient(String? fingerprint) {
    final String pinned = normalizeFingerprint(fingerprint ?? '');
    final HttpClient io = HttpClient();
    io.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      if (pinned.isEmpty) return false;
      return fingerprintMatchesDer(cert.der, pinned);
    };
    return IOClient(io);
  }

  /// No route to the laptop (DNS, refused, reset, timeout, proxy HTML).
  static const BuddyApiException routeError = BuddyApiException(
    code: 'unreachable',
    message: 'No route to the laptop — check the IP and Wi-Fi.',
  );

  /// Handshake reached the laptop but TLS was rejected — almost always a
  /// fingerprint mismatch (re-pair from `pair_device.py` output), not a
  /// network problem. Kept distinct from [routeError] on purpose.
  static const BuddyApiException tlsError = BuddyApiException(
    code: 'unreachable',
    message: 'The laptop rejected the secure connection — re-check the cert fingerprint and try again.',
  );

  String get displayHost => _port == 8443 ? _hostname : '$_hostname:$_port';

  /// Split user input like "192.168.1.10", "192.168.1.10:8443", or a pasted
  /// "https://192.168.1.10:8443/" URL into hostname + port. Pure — unit tested.
  static ({String host, int port}) splitHostPort(String input) {
    String v = input.trim();
    if (v.startsWith('http://')) v = v.substring('http://'.length);
    if (v.startsWith('https://')) v = v.substring('https://'.length);
    final int slash = v.indexOf('/');
    if (slash >= 0) v = v.substring(0, slash);
    v = v.trim();
    if (v.isEmpty) return (host: '', port: 8443);
    // IPv6 literals stay intact; only split a single trailing :port.
    final int lastColon = v.lastIndexOf(':');
    if (lastColon > 0 && v.indexOf(':') == lastColon) {
      final String maybePort = v.substring(lastColon + 1);
      final int? port = int.tryParse(maybePort);
      if (port != null && port > 0 && port < 65536) {
        return (host: v.substring(0, lastColon), port: port);
      }
    }
    return (host: v, port: 8443);
  }

  Uri _uri(String path) => Uri.https('$_hostname:$_port', path);

  Map<String, String> get _authHeaders => <String, String>{
    'Authorization': 'Bearer $_token',
  };

  /// Unauthenticated liveness check — reveals nothing sensitive (API.md).
  Future<void> checkHealth() async {
    try {
      final http.Response resp = await _client
          .get(_uri('/health'))
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        throw BuddyApiException.fromRaw(resp.statusCode, resp.body);
      }
    } on TimeoutException {
      throw routeError;
    } on SocketException {
      throw routeError;
    } on HttpException {
      throw routeError;
    } on HandshakeException {
      throw tlsError;
    } on TlsException {
      throw tlsError;
    } on http.ClientException {
      throw routeError;
    }
  }

  /// Proximity threshold + mode (Phase 4.2, API.md GET /proximity).
  ///
  /// Authenticated but near-or-far: the indicator needs the threshold most
  /// when far. Returns the server's `rssi_near_threshold` so the phone
  /// applies the same limit the server gates on — single source of truth
  /// stays in config/security.yaml.
  Future<ProximityConfig> fetchProximityConfig() async {
    http.Response resp;
    try {
      resp = await _client
          .get(_uri('/proximity'), headers: _authHeaders)
          .timeout(_timeout);
    } on TimeoutException {
      throw routeError;
    } on SocketException {
      throw routeError;
    } on HttpException {
      throw routeError;
    } on HandshakeException {
      throw tlsError;
    } on TlsException {
      throw tlsError;
    } on http.ClientException {
      throw routeError;
    }
    if (resp.statusCode != 200) {
      throw BuddyApiException.fromRaw(resp.statusCode, resp.body);
    }
    try {
      final dynamic decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) {
        final dynamic rawThreshold = decoded['rssi_near_threshold'];
        final dynamic rawMode = decoded['mode'];
        final int? threshold = rawThreshold is int
            ? rawThreshold
            : int.tryParse('$rawThreshold');
        if (threshold != null) {
          return ProximityConfig(
            mode: rawMode is String ? rawMode : 'lan_only',
            rssiNearThreshold: threshold,
          );
        }
      }
    } on FormatException {
      // Fall through to bad_response below.
    }
    throw const BuddyApiException(
      code: 'bad_response',
      message: 'The laptop sent a proximity config the app could not read.',
    );
  }

  /// POST /command (near only). Throws 401/403/429 typed from the error shape.
  Future<CommandResult> postCommand(String text, {String? rssi}) async {
    final Map<String, String> headers = <String, String>{
      ..._authHeaders,
      'Content-Type': 'application/json',
      if (rssi != null) 'X-RSSI': rssi,
    };
    http.Response resp;
    try {
      resp = await _client
          .post(_uri('/command'), headers: headers, body: jsonEncode(<String, String>{'text': text}))
          .timeout(_timeout);
    } on TimeoutException {
      throw routeError;
    } on SocketException {
      throw routeError;
    } on HttpException {
      throw routeError;
    } on HandshakeException {
      throw tlsError;
    } on TlsException {
      throw tlsError;
    } on http.ClientException {
      throw routeError;
    }
    if (resp.statusCode != 200) {
      throw BuddyApiException.fromRaw(resp.statusCode, resp.body);
    }
    try {
      final dynamic decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic> &&
          decoded['task_id'] is String &&
          decoded['status'] is String) {
        return CommandResult(
          taskId: decoded['task_id'] as String,
          status: decoded['status'] as String,
        );
      }
    } on FormatException {
      // Fall through to the error below.
    }
    throw const BuddyApiException(
      code: 'bad_response',
      message: 'The laptop answered in a shape this app does not understand.',
    );
  }

  /// GET /events as an SSE stream (near or far — notifications only).
  /// Implemented with an http streamed request per the project constraints.
  Stream<BuddyEvent> watchEvents() async* {
    final http.Request request = http.Request('GET', _uri('/events'));
    request.headers.addAll(_authHeaders);
    request.headers['Accept'] = 'text/event-stream';

    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_timeout);
    } on TimeoutException {
      throw routeError;
    } on SocketException {
      throw routeError;
    } on HttpException {
      throw routeError;
    } on HandshakeException {
      throw tlsError;
    } on TlsException {
      throw tlsError;
    } on http.ClientException {
      throw routeError;
    }

    if (response.statusCode != 200) {
      final String body = await response.stream.bytesToString();
      throw BuddyApiException.fromRaw(response.statusCode, body);
    }

    String? currentEvent;
    final StringBuffer dataBuf = StringBuffer();
    bool hasData = false;

    await for (final String line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.startsWith('event:')) {
        currentEvent = line.substring('event:'.length).trim();
      } else if (line.startsWith('data:')) {
        dataBuf.writeln(line.substring('data:'.length).trim());
        hasData = true;
      } else if (line.isEmpty) {
        if (currentEvent != null && hasData) {
          try {
            final dynamic payload = jsonDecode(dataBuf.toString());
            yield BuddyEvent.fromSse(currentEvent, payload);
          } on FormatException {
            // Skip malformed frames; keep the stream alive.
          }
        }
        currentEvent = null;
        dataBuf.clear();
        hasData = false;
      }
      // SSE comments (lines starting with ':') are heartbeats — ignored.
    }
  }

  /// Validate pairing without side effects: reachability via /health, then a
  /// token check by opening /events and closing it immediately (no POST, so
  /// no junk tasks are queued).
  Future<void> validatePairing() async {
    await checkHealth();
    // Pinned like the main client: an unpinned probe would reject the
    // self-signed dev cert and fail pairing even when everything is correct.
    final http.Client probe = BuddyApi.newPinnedClient(certFingerprint);
    try {
      final http.Request request = http.Request('GET', _uri('/events'));
      request.headers.addAll(_authHeaders);
      request.headers['Accept'] = 'text/event-stream';
      final http.StreamedResponse resp = await probe
          .send(request)
          .timeout(_timeout);
      if (resp.statusCode == 401 || resp.statusCode == 403 || resp.statusCode == 429) {
        final String body = await resp.stream.bytesToString();
        throw BuddyApiException.fromRaw(resp.statusCode, body);
      }
      if (resp.statusCode != 200) {
        final String body = await resp.stream.bytesToString();
        throw BuddyApiException.fromRaw(resp.statusCode, body);
      }
      // Token accepted — close the probe stream immediately.
      await resp.stream.listen((_) {}).cancel();
    } on BuddyApiException {
      rethrow;
    } on TimeoutException {
      throw routeError;
    } on SocketException {
      throw routeError;
    } on HttpException {
      throw routeError;
    } on HandshakeException {
      throw tlsError;
    } on TlsException {
      throw tlsError;
    } on http.ClientException {
      throw routeError;
    } finally {
      probe.close();
    }
  }

  /// POST /screen/consent — create a preview request (near only).
  ///
  /// Returns the consent id in PENDING state. The laptop approves out of
  /// band (curl approve endpoint, v1.1: OS prompt); the app then polls
  /// [checkScreen] with the id until it flips to available/denied.
  Future<String> requestScreenConsent() async {
    http.Response resp;
    try {
      resp = await _client
          .post(_uri('/screen/consent'), headers: _authHeaders)
          .timeout(_timeout);
    } on TimeoutException {
      throw routeError;
    } on SocketException {
      throw routeError;
    } on HttpException {
      throw routeError;
    } on HandshakeException {
      throw tlsError;
    } on TlsException {
      throw tlsError;
    } on http.ClientException {
      throw routeError;
    }
    if (resp.statusCode != 200) {
      throw BuddyApiException.fromRaw(resp.statusCode, resp.body);
    }
    try {
      final dynamic decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) {
        final dynamic id = decoded['consent_id'];
        if (id is String && id.isNotEmpty) return id;
      }
    } on FormatException {
      // Fall through to bad_response below.
    }
    throw const BuddyApiException(
      code: 'bad_response',
      message: 'The laptop sent a consent reply the app could not read.',
    );
  }

  /// Probe /screen status without starting a stream. Never auto-starts on
  /// screen open: the widget calls this only after explicit consent, and
  /// passes the approved grant as [consentId] (required since the server
  /// consent gate landed — without it every probe is consent_required).
  Future<ScreenStatus> checkScreen({String? consentId}) async {
    try {
      Uri uri = _uri('/screen');
      if (consentId != null && consentId.isNotEmpty) {
        uri = uri.replace(
          queryParameters: <String, String>{'consent_id': consentId},
        );
      }
      final http.Request request = http.Request('GET', uri);
      request.headers.addAll(_authHeaders);
      // Streamed send + cancel: a 200 is an infinite MJPEG body, so a
      // plain get() would download forever. Uses _client (mockable);
      // lifecycle stays with close().
      final http.StreamedResponse resp = await _client
          .send(request)
          .timeout(_timeout);
      // Drain-or-cancel: read error bodies fully, cancel real streams.
      if (resp.statusCode == 200) {
        await resp.stream.listen((_) {}).cancel();
        return ScreenStatus.available;
      }
      final String body = await resp.stream.bytesToString();
      final BuddyApiException err = BuddyApiException.fromRaw(
        resp.statusCode,
        body,
      );
      switch (err.code) {
        case 'not_implemented':
          return ScreenStatus.notImplemented;
        case 'forbidden':
          return ScreenStatus.forbidden;
        case 'consent_required':
          return ScreenStatus.consentRequired;
        case 'consent_denied':
          return ScreenStatus.consentDenied;
        case 'unauthorized':
        case 'token_expired':
          return ScreenStatus.unauthorized;
        default:
          if (resp.statusCode == 401) return ScreenStatus.unauthorized;
          if (resp.statusCode == 403) return ScreenStatus.forbidden;
          return ScreenStatus.unreachable;
      }
    } on TimeoutException {
      return ScreenStatus.unreachable;
    } on SocketException {
      return ScreenStatus.unreachable;
    } on HttpException {
      return ScreenStatus.unreachable;
    } on HandshakeException {
      return ScreenStatus.unreachable;
    } on TlsException {
      return ScreenStatus.unreachable;
    } on http.ClientException {
      return ScreenStatus.unreachable;
    }
  }

  void close() => _client.close();
}
