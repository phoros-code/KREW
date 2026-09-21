import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// One sighting batch: (device id, RSSI dBm) pairs from a single scan burst.
typedef Sightings = List<({String id, int rssi})>;

/// BLE RSSI reader for the laptop (Phase 4.1).
///
/// Watches advertisement RSSI for ONE known laptop Bluetooth id and reports
/// it on [rssi]. Everything fails closed to null (= FAR): unknown/blank id,
/// adapter off, scan errors, malformed ids, or no sighting within
/// [staleAfter] all yield null. The value is decorative — it feeds the
/// phone's near/far indicator only (server decision 1: self-attested).
///
/// The scan/start/stop seams are injectable so unit tests drive fakes
/// without Bluetooth hardware; production uses [liveBleProximityReader].
class BleProximityReader {
  BleProximityReader({
    required Stream<Sightings> sightings,
    required Future<void> Function(List<String> remoteIds) startScan,
    required Future<void> Function() stopScan,
    this.staleAfter = const Duration(seconds: 15),
  }) : _sightings = sightings,
       _startScan = startScan,
       _stopScan = stopScan;

  final Stream<Sightings> _sightings;
  final Future<void> Function(List<String> remoteIds) _startScan;
  final Future<void> Function() _stopScan;

  /// Silence window after the last sighting before reporting stale (null).
  final Duration staleAfter;

  final StreamController<int?> _controller =
      StreamController<int?>.broadcast();

  /// RSSI dBm for the watched device, or null when unreadable/stale.
  Stream<int?> get rssi => _controller.stream;

  StreamSubscription<Sightings>? _sub;
  Timer? _staleTimer;
  String? _want;
  bool _disposed = false;

  bool get isWatching => _sub != null;

  /// Start watching [remoteId] (Android: MAC, iOS: UUID — whatever the OS
  /// pairing screen shows for the laptop). Blank ids are ignored: there is
  /// nothing to watch, so the caller stays FAR.
  Future<void> start(String remoteId) async {
    final String want = remoteId.trim().toLowerCase();
    if (_disposed || want.isEmpty) return;
    await stop();
    if (_disposed) return;
    _want = want;
    _sub = _sightings.listen(
      (Sightings batch) {
        for (final sight in batch) {
          if (sight.id.toLowerCase() == _want) {
            _pulse(sight.rssi);
            return;
          }
        }
      },
      onError: (_) => _controller.add(null),
    );
    try {
      await _startScan(<String>[want]);
    } catch (_) {
      // Unresolvable id / denied permission / BT off: stay FAR, loudly
      // unreadable (null) rather than throwing into the app shell.
      _controller.add(null);
    }
  }

  void _pulse(int rssi) {
    if (_disposed) return;
    _staleTimer?.cancel();
    _staleTimer = Timer(staleAfter, () {
      if (_disposed || _sub == null) return;
      _controller.add(null); // stale: device gone quiet → FAR
      _rescan(); // best-effort: keep the watch alive past scan windows
    });
    _controller.add(rssi);
  }

  Future<void> _rescan() async {
    final String? want = _want;
    if (want == null) return;
    try {
      await _startScan(<String>[want]);
    } catch (_) {
      // Next stale tick retries; the indicator already shows FAR.
    }
  }

  /// Stop watching. Safe to call when idle.
  Future<void> stop() async {
    _want = null;
    await _sub?.cancel();
    _sub = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    try {
      await _stopScan();
    } catch (_) {
      // Stopping must never throw into the app shell.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _controller.close();
  }
}

/// Production reader wired to flutter_blue_plus.
///
/// The laptop must be advertising/pairable so the phone sees its
/// advertisements; enter the id exactly as the OS Bluetooth settings show
/// it (MAC on Android, UUID on iOS).
BleProximityReader liveBleProximityReader() => BleProximityReader(
  sightings: FlutterBluePlus.scanResults.map(
    (List<ScanResult> results) => <({String id, int rssi})>[
      for (final ScanResult r in results)
        (id: r.device.remoteId.str, rssi: r.rssi),
    ],
  ),
  startScan: (List<String> ids) => FlutterBluePlus.startScan(
    withRemoteIds: ids,
    timeout: const Duration(seconds: 30),
  ),
  stopScan: FlutterBluePlus.stopScan,
);
