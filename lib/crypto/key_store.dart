// Persistent key store for the E2E identity keypair.
//
// Storage: flutter_secure_storage. On Windows this is the credential
// manager — the OS-level secret store. The 32-byte private key never
// leaves the device.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'crypto.dart';

class IdentityKeyStore {
  IdentityKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _privKey = 'quick.identity_priv';
  static const _pubKey = 'quick.identity_pub';

  // Returns the cached keypair, generating + persisting one if this is
  // the first call. The matching public key MUST be uploaded to the
  // server via Users.UploadIdentityKey for any peer to be able to
  // address us — that's the caller's job.
  Future<IdentityKeyPair> loadOrCreate() async {
    final priv = await _storage.read(key: _privKey);
    final pub = await _storage.read(key: _pubKey);
    if (priv != null && pub != null) {
      return IdentityKeyPair(
        privateKey: Uint8List.fromList(base64Decode(priv)),
        publicKey: Uint8List.fromList(base64Decode(pub)),
      );
    }
    final pair = await CryptoLib.generateIdentityKey();
    await _storage.write(key: _privKey, value: base64Encode(pair.privateKey));
    await _storage.write(key: _pubKey, value: base64Encode(pair.publicKey));
    return pair;
  }

  // Drop the stored keypair. Called from logout so a different user on
  // the same device gets their own keys.
  Future<void> clear() async {
    await _storage.delete(key: _privKey);
    await _storage.delete(key: _pubKey);
  }
}
