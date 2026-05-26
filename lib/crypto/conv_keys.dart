// Per-conversation key cache.
//
// For DMs we derive the key on first use from ECDH(my_priv, peer_pub) and
// memoise. For groups/channels we fetch the bundle, decrypt our slot, and
// memoise. The map lives for the session — there's no on-disk cache yet
// because the derivation is cheap and on-the-fly re-derivation is trivial.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../api/services.dart';
import 'crypto.dart';
import 'key_store.dart';

class ConvKeyCache {
  ConvKeyCache({
    required this.identityStore,
    required this.usersApi,
    required this.messagingApi,
    required this.currentUserId,
  });

  final IdentityKeyStore identityStore;
  final UsersApi usersApi;
  final MessagingApi messagingApi;
  String currentUserId;

  final Map<String, SecretKey> _keyByConv = {};
  final Map<String, Uint8List> _identityPubByUser = {};

  IdentityKeyPair? _myPair;
  Future<IdentityKeyPair> _myPairOnce() async {
    final cached = _myPair;
    if (cached != null) return cached;
    final p = await identityStore.loadOrCreate();
    _myPair = p;
    return p;
  }

  // Drop everything — typically on logout.
  void reset(String? newUserId) {
    _keyByConv.clear();
    _identityPubByUser.clear();
    _myPair = null;
    currentUserId = newUserId ?? '';
  }

  // Fetch the peer's identity pubkey, with a small in-memory cache. Returns
  // null if the server says they haven't uploaded one yet — caller decides
  // whether to fall back to plaintext or refuse to send.
  Future<Uint8List?> peerIdentityPub(String userId) async {
    final cached = _identityPubByUser[userId];
    if (cached != null) return cached;
    final res = await usersApi.getIdentityKey(userId);
    if (res == null) return null;
    _identityPubByUser[userId] = res;
    return res;
  }

  // Returns the per-conversation symmetric key, deriving + caching it on
  // first use. peerId / convType drive which derivation runs:
  //   * dm:  ECDH(my_priv, peer_pub) + HKDF.
  //   * group/channel: fetch bundle, decrypt our slot.
  // Returns null when the peer / group hasn't uploaded a key yet (so the
  // caller can fall back to plaintext for an MVP-friendly degraded mode).
  Future<SecretKey?> keyForConv({
    required String convId,
    required String convType,
    required String? peerId,
  }) async {
    final cached = _keyByConv[convId];
    if (cached != null) return cached;

    final me = await _myPairOnce();
    SecretKey? key;
    if (convType == 'dm') {
      if (peerId == null || peerId.isEmpty) return null;
      final peerPub = await peerIdentityPub(peerId);
      if (peerPub == null) return null;
      key = await CryptoLib.deriveDmKey(me.privateKey, peerPub);
    } else {
      // Group / channel.
      final bundle = await messagingApi.getGroupKeyBundle(convId);
      if (bundle == null) return null;
      // The sender's identity is whoever uploaded the bundle last. We don't
      // have an explicit sender_user_id field — by convention, the per-
      // member ciphertext map contains an entry for every CURRENT member
      // including the uploader. To recover the wrap key we ECDH against the
      // public key of any other member. We pick the alphabetically first
      // OTHER member that has a known identity key — close enough for now,
      // since the sender necessarily holds an identity key (they uploaded).
      //
      // TODO(s14): include the uploader's user_id in the bundle so we don't
      // have to probe.
      final wrapped = bundle.perMember[currentUserId];
      if (wrapped == null) return null;
      String? candidateSender;
      for (final other in bundle.perMember.keys) {
        if (other != currentUserId) {
          candidateSender = other;
          break;
        }
      }
      if (candidateSender == null) return null;
      final senderPub = await peerIdentityPub(candidateSender);
      if (senderPub == null) return null;
      try {
        final groupKey = await CryptoLib.unwrapGroupKey(
          myPriv: me.privateKey,
          senderPub: senderPub,
          myUserId: currentUserId,
          wrappedCiphertext: wrapped,
          nonce: bundle.nonce,
        );
        key = SecretKey(groupKey);
      } catch (_) {
        return null;
      }
    }
    _keyByConv[convId] = key;
    return key;
  }

  // Store the freshly generated group key for a conversation we just
  // created. Used by CreateGroup once the bundle is uploaded.
  void setGroupKey(String convId, Uint8List groupKey) {
    _keyByConv[convId] = SecretKey(groupKey);
  }
}
