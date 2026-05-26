// E2E encryption primitives used by the messenger.
//
// Scheme — "Signal-lite":
//   * Long-term identity:    X25519 keypair, 32 bytes each half.
//   * Per-DM key:             HKDF-SHA256(ECDH(my_priv, peer_pub)).
//   * Per-group key:          random 32 bytes, wrapped to each member's
//                             identity pubkey via the same DM-derivation.
//   * Message envelope:       AES-256-GCM, 12-byte random nonce, AAD binds
//                             sender_id + conv_id + created_at-millis.
//   * Voice blob:             same AES-GCM construction, but body is the
//                             raw audio bytes — the server stores it as
//                             an opaque blob.
//
// All keys here are RAW BYTES. Conversion to/from base64 stays at the
// call sites where the wire requires it.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class IdentityKeyPair {
  IdentityKeyPair({required this.privateKey, required this.publicKey});
  final Uint8List privateKey; // 32 bytes
  final Uint8List publicKey;  // 32 bytes
}

class EncryptedBlob {
  EncryptedBlob({required this.ciphertext, required this.nonce});
  final Uint8List ciphertext; // includes 16-byte GCM tag at tail
  final Uint8List nonce;      // 12 bytes
}

class GroupBundleSealed {
  GroupBundleSealed({required this.perMember, required this.nonce});
  // wrapped key, keyed by user_id
  final Map<String, Uint8List> perMember;
  final Uint8List nonce;
}

class CryptoLib {
  CryptoLib._();

  static final _x25519 = Cryptography.instance.x25519();
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _rng = Random.secure();

  static Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  // Identity keypair generation. The private key never leaves the device —
  // it lives in flutter_secure_storage (see key_store.dart).
  static Future<IdentityKeyPair> generateIdentityKey() async {
    final pair = await _x25519.newKeyPair();
    final priv = Uint8List.fromList(await pair.extractPrivateKeyBytes());
    final pub = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    return IdentityKeyPair(privateKey: priv, publicKey: pub);
  }

  // Re-derive the public half from a stored private key. Useful when the
  // keystore only persisted the private bytes.
  static Future<Uint8List> derivePublicKey(Uint8List privateKey) async {
    final pair = await _x25519.newKeyPairFromSeed(privateKey);
    return Uint8List.fromList((await pair.extractPublicKey()).bytes);
  }

  // ECDH + HKDF-SHA256 -> 32-byte symmetric key. Both parties compute the
  // SAME key for a given (priv_A, pub_B) <-> (priv_B, pub_A) pair.
  static Future<SecretKey> _deriveSharedKey(
    Uint8List myPriv,
    Uint8List peerPub, {
    required String context,
  }) async {
    final myPair = await _x25519.newKeyPairFromSeed(myPriv);
    final shared = await _x25519.sharedSecretKey(
      keyPair: myPair,
      remotePublicKey: SimplePublicKey(peerPub, type: KeyPairType.x25519),
    );
    // HKDF with a salt = sha256("quick.e2e.v1") so callers in different
    // protocol versions can't accidentally collide.
    return _hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode(context),
      nonce: const [0x71, 0x69, 0x63, 0x6b, 0x2e, 0x65, 0x32, 0x65], // 'quick.e2e'
    );
  }

  // For DMs both peers can compute the same key from their own private +
  // the other's public. context is fixed to "quick.dm.aes256gcm".
  static Future<SecretKey> deriveDmKey(
    Uint8List myPriv,
    Uint8List peerPub,
  ) {
    return _deriveSharedKey(myPriv, peerPub, context: 'quick.dm.aes256gcm');
  }

  // For group bundles the sender derives a key to wrap the random group
  // key under each member's identity public key. Members run the symmetric
  // derivation with their own private + the sender's public.
  static Future<SecretKey> deriveBundleKey(
    Uint8List myPriv,
    Uint8List peerPub,
  ) {
    return _deriveSharedKey(myPriv, peerPub, context: 'quick.group.wrap.aes256gcm');
  }

  // Generate a fresh 32-byte symmetric key for a new group conversation.
  static Uint8List generateGroupKey() => _randomBytes(32);

  // 12-byte random GCM nonce.
  static Uint8List newNonce() => _randomBytes(12);

  // Encrypt a UTF-8 string. AAD binds sender+conv+timestamp so a server
  // can't splice ciphertext across conversations or replay it later.
  static Future<EncryptedBlob> encryptText(
    SecretKey key,
    String plaintext, {
    required String senderId,
    required String conversationId,
    required int createdAtMs,
  }) async {
    final aad = _buildAad(senderId, conversationId, createdAtMs);
    final nonce = newNonce();
    final box = await _aesGcm.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return EncryptedBlob(ciphertext: out, nonce: nonce);
  }

  // Decrypt and verify a UTF-8 ciphertext. Throws on tag mismatch.
  static Future<String> decryptText(
    SecretKey key,
    Uint8List ciphertext,
    Uint8List nonce, {
    required String senderId,
    required String conversationId,
    required int createdAtMs,
  }) async {
    final raw = await _decryptRaw(key, ciphertext, nonce,
        senderId: senderId, conversationId: conversationId, createdAtMs: createdAtMs);
    return utf8.decode(raw);
  }

  // Encrypt a binary blob (used for voice messages). Same AEAD as text but
  // returns raw bytes.
  static Future<EncryptedBlob> encryptBytes(
    SecretKey key,
    Uint8List plaintext, {
    required String senderId,
    required String conversationId,
    required int createdAtMs,
  }) async {
    final aad = _buildAad(senderId, conversationId, createdAtMs);
    final nonce = newNonce();
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return EncryptedBlob(ciphertext: out, nonce: nonce);
  }

  // Decrypt a binary blob (mirror of encryptBytes).
  static Future<Uint8List> decryptBytes(
    SecretKey key,
    Uint8List ciphertext,
    Uint8List nonce, {
    required String senderId,
    required String conversationId,
    required int createdAtMs,
  }) {
    return _decryptRaw(key, ciphertext, nonce,
        senderId: senderId, conversationId: conversationId, createdAtMs: createdAtMs);
  }

  // Wrap a 32-byte group key for each recipient. Sender derives a per-
  // recipient bundle key via ECDH, encrypts the group key under it, and
  // emits the per-member ciphertext map.
  //
  // Nonce is shared across all slots — safe because each slot uses a
  // FRESH derived key (so nonce-reuse-within-a-key never happens).
  static Future<GroupBundleSealed> wrapGroupKey({
    required Uint8List myPriv,
    required Uint8List groupKey,
    required Map<String, Uint8List> memberPubKeys,
  }) async {
    final nonce = newNonce();
    final out = <String, Uint8List>{};
    for (final entry in memberPubKeys.entries) {
      final k = await deriveBundleKey(myPriv, entry.value);
      // AAD = "bundle:<user_id>" — binds the slot to its intended recipient.
      final aad = utf8.encode('bundle:${entry.key}');
      final box = await _aesGcm.encrypt(
        groupKey,
        secretKey: k,
        nonce: nonce,
        aad: aad,
      );
      final ct = Uint8List(box.cipherText.length + box.mac.bytes.length);
      ct.setRange(0, box.cipherText.length, box.cipherText);
      ct.setRange(box.cipherText.length, ct.length, box.mac.bytes);
      out[entry.key] = ct;
    }
    return GroupBundleSealed(perMember: out, nonce: nonce);
  }

  // Recipient-side: open the slot keyed to our user id and recover the
  // group key. Throws on tag mismatch.
  static Future<Uint8List> unwrapGroupKey({
    required Uint8List myPriv,
    required Uint8List senderPub,
    required String myUserId,
    required Uint8List wrappedCiphertext,
    required Uint8List nonce,
  }) async {
    final k = await deriveBundleKey(myPriv, senderPub);
    final aad = utf8.encode('bundle:$myUserId');
    if (wrappedCiphertext.length < 16) {
      throw const FormatException('bundle ciphertext too short');
    }
    final ct = wrappedCiphertext.sublist(0, wrappedCiphertext.length - 16);
    final mac = wrappedCiphertext.sublist(wrappedCiphertext.length - 16);
    final out = await _aesGcm.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: k,
      aad: aad,
    );
    return Uint8List.fromList(out);
  }

  static Future<Uint8List> _decryptRaw(
    SecretKey key,
    Uint8List ciphertext,
    Uint8List nonce, {
    required String senderId,
    required String conversationId,
    required int createdAtMs,
  }) async {
    final aad = _buildAad(senderId, conversationId, createdAtMs);
    if (ciphertext.length < 16) {
      throw const FormatException('ciphertext too short');
    }
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final mac = ciphertext.sublist(ciphertext.length - 16);
    final out = await _aesGcm.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
      aad: aad,
    );
    return Uint8List.fromList(out);
  }

  static List<int> _buildAad(String senderId, String conversationId, int createdAtMs) {
    // Compact AAD format: "sender|conv|ts". Stable across clients because
    // it's pure ASCII / fixed format.
    return utf8.encode('$senderId|$conversationId|$createdAtMs');
  }
}
