import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Pairing credentials. Stored in platform secure storage
/// (Android Keystore / iOS Keychain) — never plain preferences.
/// See SECURITY.md → Authentication.
class PairingInfo {
  const PairingInfo({required this.host, required this.token});

  final String host;
  final String token;
}

class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String hostKey = 'buddy_host';
  static const String tokenKey = 'buddy_token';

  /// Pinned SHA-256 of the laptop's TLS cert (the `Cert SHA256` line from
  /// `scripts/pair_device.py`). The app trusts exactly this cert and nothing
  /// else — absent/blank means the TLS client trusts nothing (fail closed).
  static const String certFpKey = 'buddy_cert_fp';

  /// Optional laptop Bluetooth id for the Phase 4.1 RSSI watch
  /// (Android: MAC, iOS: UUID). Absent/blank = BLE watch stays off and
  /// proximity falls back to server-403 behavior (fail closed, FAR).
  static const String btDeviceKey = 'buddy_bt_device';

  /// Track C3: in-app task notifications toggle (SnackBar popups). Default
  /// ON — absent means enabled. Kept outside [clear]: unpairing forgets the
  /// laptop, not the user's preference.
  static const String notifEnabledKey = 'buddy_notif_enabled';

  /// Track C3: onboarding overlay seen flag. Shown once after the first
  /// pairing (never before — no laptop yet). Kept outside [clear] so a
  /// re-pair does not replay the tour.
  static const String onboardingSeenKey = 'buddy_onboarding_seen';

  /// Track C3: ISO-8601 timestamp of when the current pairing was saved,
  /// for the Settings → Pairing status row. Written by [savePairing],
  /// cleared by [clear] with the rest of the pairing.
  static const String pairedOnKey = 'buddy_paired_on';

  final FlutterSecureStorage _storage;

  Future<PairingInfo?> readPairing() async {
    final String? host = await _storage.read(key: hostKey);
    final String? token = await _storage.read(key: tokenKey);
    if (host == null || host.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return PairingInfo(host: host, token: token);
  }

  Future<void> savePairing({
    required String host,
    required String token,
  }) async {
    await _storage.write(key: hostKey, value: host.trim());
    await _storage.write(key: tokenKey, value: token.trim());
    await _storage.write(
      key: pairedOnKey,
      value: DateTime.now().toIso8601String(),
    );
  }

  Future<String?> readCertFingerprint() async {
    final String? fp = await _storage.read(key: certFpKey);
    if (fp == null || fp.trim().isEmpty) return null;
    return fp.trim();
  }

  Future<void> saveCertFingerprint(String? fingerprint) async {
    final String trimmed = (fingerprint ?? '').trim();
    if (trimmed.isEmpty) {
      await _storage.delete(key: certFpKey);
    } else {
      await _storage.write(key: certFpKey, value: trimmed);
    }
  }

  Future<String?> readBtDeviceId() async {
    final String? id = await _storage.read(key: btDeviceKey);
    if (id == null || id.trim().isEmpty) return null;
    return id.trim();
  }

  Future<void> saveBtDeviceId(String? id) async {
    final String trimmed = (id ?? '').trim();
    if (trimmed.isEmpty) {
      await _storage.delete(key: btDeviceKey);
    } else {
      await _storage.write(key: btDeviceKey, value: trimmed);
    }
  }

  Future<void> clear() async {
    await _storage.delete(key: hostKey);
    await _storage.delete(key: tokenKey);
    await _storage.delete(key: certFpKey);
    await _storage.delete(key: btDeviceKey);
    await _storage.delete(key: pairedOnKey);
    // notifEnabledKey + onboardingSeenKey intentionally survive: unpairing
    // forgets the laptop, not the user's preferences or the seen tour.
  }

  /// Track C3: notification toggle. Absent (never set) means enabled.
  Future<bool> readNotificationsEnabled() async {
    final String? raw = await _storage.read(key: notifEnabledKey);
    if (raw == null) return true;
    return raw != '0';
  }

  Future<void> saveNotificationsEnabled(bool enabled) async {
    await _storage.write(key: notifEnabledKey, value: enabled ? '1' : '0');
  }

  /// Track C3: onboarding seen flag (false when never written).
  Future<bool> readOnboardingSeen() async {
    final String? raw = await _storage.read(key: onboardingSeenKey);
    return raw == '1';
  }

  Future<void> saveOnboardingSeen() async {
    await _storage.write(key: onboardingSeenKey, value: '1');
  }

  /// Track C3: ISO-8601 pairing timestamp, null when never paired (or a
  /// pairing saved before this key existed).
  Future<String?> readPairedOn() async {
    final String? raw = await _storage.read(key: pairedOnKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }
}
