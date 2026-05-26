// AES-GCM blob encryption for tdata column values. Key is derived from the
// session token + a constant pepper via HKDF-SHA256, then used as the AES-256
// key. Different sessions can't decrypt each other's blobs.
//
// If/when the E2E crypto agent lands `lib/crypto/`, swap `deriveKey` to use
// the shared primitives — the on-disk format is `nonce(12) || ciphertext`,
// stored verbatim as a BLOB.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// Constant 32-byte pepper. Not a secret — its purpose is to make derived keys
// domain-separated from any other use of the session token. Burned into the
// binary; changing it invalidates every existing tdata.db (acceptable, the
// store will rebuild from the server on next launch).
final List<int> _pepper = utf8.encode(
  'quick.tdata.v1.pepper.do-not-change-without-bumping-schema',
);

class StoreCrypto {
  StoreCrypto._(this._key);

  final SecretKey _key;
  static final _algo = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  // Derive the 32-byte symmetric key from a session token. Cheap once per
  // boot. The token is also the per-session salt, so changing accounts
  // automatically yields a fresh key.
  static Future<StoreCrypto> fromSessionToken(String sessionToken) async {
    final keyMaterial = utf8.encode(sessionToken);
    final secret = SecretKey(keyMaterial);
    final out = await _hkdf.deriveKey(
      secretKey: secret,
      nonce: _pepper,
      info: utf8.encode('quick.tdata.aes-gcm'),
    );
    return StoreCrypto._(out);
  }

  // Encrypt a UTF-8 string. Returns nonce(12) || ciphertext || mac(16).
  Future<Uint8List> encryptString(String plaintext) async {
    return encryptBytes(utf8.encode(plaintext));
  }

  Future<String> decryptString(Uint8List blob) async {
    final bytes = await decryptBytes(blob);
    return utf8.decode(bytes);
  }

  Future<Uint8List> encryptBytes(List<int> plaintext) async {
    final box = await _algo.encrypt(plaintext, secretKey: _key);
    final out = BytesBuilder();
    out.add(box.nonce);
    out.add(box.cipherText);
    out.add(box.mac.bytes);
    return out.toBytes();
  }

  Future<Uint8List> decryptBytes(Uint8List blob) async {
    if (blob.length < 12 + 16) {
      throw StateError('encrypted blob too short: ${blob.length}');
    }
    final nonce = blob.sublist(0, 12);
    final mac = blob.sublist(blob.length - 16);
    final ct = blob.sublist(12, blob.length - 16);
    final box = SecretBox(ct, nonce: nonce, mac: Mac(mac));
    final out = await _algo.decrypt(box, secretKey: _key);
    return Uint8List.fromList(out);
  }

  // JSON helpers — most callers store a Map<String, dynamic> per row.
  Future<Uint8List> encryptJson(Map<String, dynamic> obj) =>
      encryptString(jsonEncode(obj));

  Future<Map<String, dynamic>> decryptJson(Uint8List blob) async {
    final s = await decryptString(blob);
    final decoded = jsonDecode(s);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return <String, dynamic>{};
  }
}
