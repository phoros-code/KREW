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
  }

  Future<void> clear() async {
    await _storage.delete(key: hostKey);
    await _storage.delete(key: tokenKey);
  }
}
