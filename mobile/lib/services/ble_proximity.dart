import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// One sighting batch: (device id, RSSI dBm) pairs from a single scan burst.
typedef Sightings = List<({String id, int rssi})>;

/// Human cause strings surfaced when FAR has a known reason (Track A5.9) —
/// rendered by the calibrate screen and the header FAR reason. Never
/// silently FAR when the cause is known.
abstract final class BleWatchCause {
  /// The phone's Bluetooth adapter is off or unavailable.
  static const String bluetoothOff =
      'Bluetooth off — turn on Bluetooth to use proximity.';
  /// The OS denied the scan permission.
  static const String permissionDenied =
      'Permission denied — enable Bluetooth permission in Settings.';
}

/// Production permission gate: BLUETOOTH_SCAN (+CONNECT) on Android,
/// bluetooth on iOS. Best-effort — an unsupported platform returns true so
/// legacy flows proceed and fail closed to null downstream instead of
/// crashing the watch start.
Future<bool> requestBlePermissions() async {
  try {
    final Map<Permission, PermissionStatus> statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final PermissionStatus? scan = statuses[Permission.bluetoothScan];
    if (scan == null) return true;
    return scan.isGranted || scan.isLimited;
  } catch (_) {
    return true;
  }
}

/// BLE RSSI reader for the laptop (Phase 4.1).
///
/// Watches advertisement RSSI for ONE known laptop Bluetooth id and reports
/// it on [rssi]. Everything fails closed to null (= FAR): unknown/blank id,
/// adapter off, scan errors, malformed ids, or no sighting within
/// [staleAfter] all yield null. The value is decorative — it feeds the
/// phone's near/far indicator only (server decision 1: self-attested).
///
/// [cause] carries the human reason when FAR has a known cause
/// ([BleWatchCause.bluetoothOff] / [BleWatchCause.permissionDenied]) and
/// null otherwise — the app shows it instead of failing silently. A fresh
/// sighting clears the cause.
///
/// The scan/start/stop/permissions/adapter seams are injectable so unit
/// tests drive fakes without Bluetooth hardware; production uses
/// [liveBleProximityReader].
class BleProximityReader {
  BleProximityReader({
    required Stream<Sightings> sightings,
    required Future<void> Function(List<String> remoteIds) startScan,
    required Future<void> Function() stopScan,
    this.staleAfter = const Duration(seconds: 15),
    Future<bool> Function()? ensurePermissions,
    Stream<BluetoothAdapterState>? adapterStates,
    this.rescanBase = const Duration(seconds: 5),
    this.rescanMax = const Duration(seconds: 60),
  }) : _sightings = sightings,
       _startScan = startScan,
       _stopScan = stopScan,
       _ensurePermissions = ensurePermissions,
       _adapterStates = adapterStates;

  final Stream<Sightings> _sightings;
  final Future<void> Function(List<String> remoteIds) _startScan;
  final Future<void> Function() _stopScan;
  final Future<bool> Function()? _ensurePermissions;
  final Stream<BluetoothAdapterState>? _adapterStates;

  /// Silence window after the last sighting before reporting stale (null).
  final Duration staleAfter;

  /// Rescan backoff bounds (Track A5.9): after a stale tick the watch
  /// re-arms after [rescanBase], doubling per consecutive miss up to
  /// [rescanMax]. A fresh sighting resets the count. Injectable so tests
  /// run on milliseconds.
  final Duration rescanBase;
  final Duration rescanMax;

  /// Pure backoff step (Track A5.9): 5s, 10s, 20s, 40s … capped at 60s.
  /// [misses] counts consecutive stale ticks without a sighting (≥1).
  static Duration rescanDelay(
    int misses, {
    Duration base = const Duration(seconds: 5),
    Duration max = const Duration(seconds: 60),
  }) {
    Duration delay = base;
    for (int i = 1; i < misses; i++) {
      final int next = delay.inMilliseconds * 2;
      delay = Duration(milliseconds: next);
      if (delay >= max) return max;
    }
    return delay >= max ? max : delay;
  }

  final StreamController<int?> _controller =
      StreamController<int?>.broadcast();
  final StreamController<String?> _causeController =
      StreamController<String?>.broadcast();

  /// RSSI dBm for the watched device, or null when unreadable/stale.
  Stream<int?> get rssi => _controller.stream;

  /// Known FAR cause ([BleWatchCause]) or null. The latest value is replayed
  /// to every new listener so late subscribers (calibrate screen) still see
  /// the current cause.
  Stream<String?> get cause async* {
    yield _cause;
    yield* _causeController.stream;
  }

  String? _cause;
  void _setCause(String? next) {
    if (_cause == next || _causeController.isClosed) return;
    _cause = next;
    _causeController.add(next);
  }

  StreamSubscription<Sightings>? _sub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _staleTimer;
  Timer? _rescanTimer;
  int _misses = 0;
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
    // Permission gate first: a denial is a KNOWN cause — say so loudly
    // instead of emitting a silent null.
    final Future<bool> Function()? ensurePermissions = _ensurePermissions;
    if (ensurePermissions != null) {
      bool granted = true;
      try {
        granted = await ensurePermissions();
      } catch (_) {
        granted = true;
      }
      if (_disposed) return;
      if (!granted) {
        _setCause(BleWatchCause.permissionDenied);
        _controller.add(null);
        return;
      }
    }
    _want = want;
    _misses = 0;
    _setCause(null);
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
    if (_adapterStates != null) {
      await _adapterSub?.cancel();
      final Stream<BluetoothAdapterState> adapterStates = _adapterStates;
      _adapterSub = adapterStates.listen((BluetoothAdapterState state) {
        if (_disposed || _sub == null) return;
        if (state == BluetoothAdapterState.on) {
          if (_cause == BleWatchCause.bluetoothOff) _setCause(null);
        } else {
          _setCause(BleWatchCause.bluetoothOff);
          _controller.add(null);
        }
      });
    }
    try {
      await _startScan(<String>[want]);
    } catch (_) {
      // Unresolvable id / denied permission / BT off: stay FAR, loudly
      // unreadable (null) rather than throwing into the app shell.
      _setCause(BleWatchCause.bluetoothOff);
      _controller.add(null);
    }
  }

  void _pulse(int rssi) {
    if (_disposed) return;
    _misses = 0;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _setCause(null);
    _staleTimer?.cancel();
    _staleTimer = Timer(staleAfter, () {
      if (_disposed || _sub == null) return;
      _controller.add(null); // stale: device gone quiet → FAR
      _scheduleRescan(); // backed-off re-arm keeps the watch alive
    });
    _controller.add(rssi);
  }

  /// Backed-off re-arm after a stale tick (Track A5.9): 5s, 10s, 20s …
  /// capped at 60s of quiet instead of hammering the adapter every tick.
  /// Each completed rescan with still no sighting schedules the next step,
  /// so a quiet device backs off instead of spinning; a fresh sighting
  /// ([_pulse]) or [stop] breaks the chain.
  void _scheduleRescan() {
    if (_disposed || _want == null) return;
    _misses++;
    _rescanTimer?.cancel();
    final Duration delay = BleProximityReader.rescanDelay(
      _misses,
      base: rescanBase,
      max: rescanMax,
    );
    _rescanTimer = Timer(delay, () {
      if (_disposed || _want == null) return;
      unawaited(_rescan());
    });
  }

  Future<void> _rescan() async {
    final String? want = _want;
    if (want == null) return;
    try {
      await _startScan(<String>[want]);
    } catch (_) {
      // The indicator already shows FAR — fall through to the backoff.
    }
    // Still quiet: next backoff step (a sighting cancels this via _pulse).
    _scheduleRescan();
  }

  /// Stop watching. Safe to call when idle.
  Future<void> stop() async {
    _want = null;
    _misses = 0;
    await _sub?.cancel();
    _sub = null;
    await _adapterSub?.cancel();
    _adapterSub = null;
    _staleTimer?.cancel();
    _staleTimer = null;
    _rescanTimer?.cancel();
    _rescanTimer = null;
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
    await _causeController.close();
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
  ensurePermissions: requestBlePermissions,
  adapterStates: FlutterBluePlus.adapterState,
);
