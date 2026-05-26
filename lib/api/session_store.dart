// Secure token persistence. Uses flutter_secure_storage which on Windows is
// backed by the Data Protection API (per-user, encrypted at rest).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionStore {
  static const _key = 'quick.token';
  static const _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );

  Future<String?> readToken() => _storage.read(key: _key);

  Future<void> writeToken(String token) =>
      _storage.write(key: _key, value: token);

  Future<void> clear() => _storage.delete(key: _key);
}
