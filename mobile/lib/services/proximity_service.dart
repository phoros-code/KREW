import 'package:flutter/foundation.dart';

/// Phone-side proximity + connection state.
///
/// Fail-closed (SECURITY.md): the default is FAR, an unreadable signal stays
/// FAR, and anything offline blocks commands. The Phase 4 BLE RSSI reader
/// hooks into [updateRssi]; until then the mode is set from server 403s and
/// explicit user action, defaulting to far.
enum ProximityMode { near, far }

enum BuddyConnection { online, offline, unknown }

class ProximityService extends ChangeNotifier {
  ProximityService({int rssiNearThreshold = -60})
    : _rssiNearThreshold = rssiNearThreshold;

  int _rssiNearThreshold;

  /// Last BLE RSSI seen (null = none yet, or unreadable). Decorative-only:
  /// sent as X-RSSI so the server can gate, never trusted server-side.
  int? _lastRssi;
  int? get lastRssi => _lastRssi;

  int get rssiNearThreshold => _rssiNearThreshold;

  /// Phase 4.2: threshold arrives from GET /proximity after pairing —
  /// the single source of truth stays in config/security.yaml.
  void setThreshold(int threshold) {
    if (_rssiNearThreshold != threshold) {
      _rssiNearThreshold = threshold;
      notifyListeners();
    }
  }

  ProximityMode _mode = ProximityMode.far;
  BuddyConnection _connection = BuddyConnection.unknown;

  ProximityMode get mode => _mode;
  BuddyConnection get connection => _connection;

  bool get isNear => _mode == ProximityMode.near;

  /// Commands are allowed only when NEAR *and* the laptop is reachable.
  bool get commandsAllowed =>
      _mode == ProximityMode.near && _connection == BuddyConnection.online;

  bool get isOffline => _connection == BuddyConnection.offline;

  void markNear() {
    if (_mode != ProximityMode.near) {
      _mode = ProximityMode.near;
      notifyListeners();
    }
  }

  void markFar() {
    if (_mode != ProximityMode.far) {
      _mode = ProximityMode.far;
      notifyListeners();
    }
  }

  void setOnline() {
    if (_connection != BuddyConnection.online) {
      _connection = BuddyConnection.online;
      notifyListeners();
    }
  }

  void setOffline() {
    if (_connection != BuddyConnection.offline) {
      _connection = BuddyConnection.offline;
      notifyListeners();
    }
  }

  void setUnknown() {
    if (_connection != BuddyConnection.unknown) {
      _connection = BuddyConnection.unknown;
      notifyListeners();
    }
  }

  /// Phase 4 hook: null/unreadable RSSI always yields FAR (fail closed).
  void updateRssi(int? rssi, {int? threshold}) {
    _lastRssi = rssi;
    final int limit = threshold ?? _rssiNearThreshold;
    if (rssi == null) {
      markFar();
    } else if (rssi >= limit) {
      markNear();
    } else {
      markFar();
    }
  }
}
