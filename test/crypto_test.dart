// Unit tests for the E2E crypto primitives.
//
// Run with: flutter test test/crypto_test.dart

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_desktop/crypto/crypto.dart';

void main() {
  group('CryptoLib.identity', () {
    test('generateIdentityKey produces 32-byte pair', () async {
      final p = await CryptoLib.generateIdentityKey();
      expect(p.privateKey, hasLength(32));
      expect(p.publicKey, hasLength(32));
    });

    test('derivePublicKey is consistent with generation', () async {
      final p = await CryptoLib.generateIdentityKey();
      final pub = await CryptoLib.derivePublicKey(p.privateKey);
      expect(pub, equals(p.publicKey));
    });
  });

  group('CryptoLib.deriveDmKey', () {
    test('both peers derive the same key', () async {
      final alice = await CryptoLib.generateIdentityKey();
      final bob = await CryptoLib.generateIdentityKey();
      final aliceK = await CryptoLib.deriveDmKey(alice.privateKey, bob.publicKey);
      final bobK = await CryptoLib.deriveDmKey(bob.privateKey, alice.publicKey);
      expect(await aliceK.extractBytes(), equals(await bobK.extractBytes()));
    });
  });

  group('CryptoLib.encryptText / decryptText', () {
    test('round-trip recovers plaintext', () async {
      final alice = await CryptoLib.generateIdentityKey();
      final bob = await CryptoLib.generateIdentityKey();
      final k = await CryptoLib.deriveDmKey(alice.privateKey, bob.publicKey);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final box = await CryptoLib.encryptText(
        k,
        'hello, world',
        senderId: 'alice',
        conversationId: 'conv1',
        createdAtMs: ts,
      );
      expect(box.nonce, hasLength(12));
      final recovered = await CryptoLib.decryptText(
        k,
        box.ciphertext,
        box.nonce,
        senderId: 'alice',
        conversationId: 'conv1',
        createdAtMs: ts,
      );
      expect(recovered, 'hello, world');
    });

    test('AAD mismatch (different conv) rejects', () async {
      final alice = await CryptoLib.generateIdentityKey();
      final bob = await CryptoLib.generateIdentityKey();
      final k = await CryptoLib.deriveDmKey(alice.privateKey, bob.publicKey);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final box = await CryptoLib.encryptText(
        k,
        'secret',
        senderId: 'alice',
        conversationId: 'conv1',
        createdAtMs: ts,
      );
      expect(
        () => CryptoLib.decryptText(
          k,
          box.ciphertext,
          box.nonce,
          senderId: 'alice',
          conversationId: 'conv2', // spliced
          createdAtMs: ts,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('CryptoLib.group bundle wrap / unwrap', () {
    test('every member can recover the group key', () async {
      final sender = await CryptoLib.generateIdentityKey();
      final alice = await CryptoLib.generateIdentityKey();
      final bob = await CryptoLib.generateIdentityKey();
      final groupKey = CryptoLib.generateGroupKey();
      final sealed = await CryptoLib.wrapGroupKey(
        myPriv: sender.privateKey,
        groupKey: groupKey,
        memberPubKeys: {
          'alice': alice.publicKey,
          'bob': bob.publicKey,
        },
      );
      expect(sealed.nonce, hasLength(12));
      expect(sealed.perMember.keys, containsAll(['alice', 'bob']));

      final aliceRec = await CryptoLib.unwrapGroupKey(
        myPriv: alice.privateKey,
        senderPub: sender.publicKey,
        myUserId: 'alice',
        wrappedCiphertext: sealed.perMember['alice']!,
        nonce: sealed.nonce,
      );
      expect(aliceRec, equals(groupKey));

      final bobRec = await CryptoLib.unwrapGroupKey(
        myPriv: bob.privateKey,
        senderPub: sender.publicKey,
        myUserId: 'bob',
        wrappedCiphertext: sealed.perMember['bob']!,
        nonce: sealed.nonce,
      );
      expect(bobRec, equals(groupKey));
    });

    test('non-member cannot recover the group key', () async {
      final sender = await CryptoLib.generateIdentityKey();
      final alice = await CryptoLib.generateIdentityKey();
      final mallory = await CryptoLib.generateIdentityKey();
      final groupKey = CryptoLib.generateGroupKey();
      final sealed = await CryptoLib.wrapGroupKey(
        myPriv: sender.privateKey,
        groupKey: groupKey,
        memberPubKeys: {'alice': alice.publicKey},
      );
      // Mallory tries Alice's slot with the WRONG private key.
      expect(
        () => CryptoLib.unwrapGroupKey(
          myPriv: mallory.privateKey,
          senderPub: sender.publicKey,
          myUserId: 'alice',
          wrappedCiphertext: sealed.perMember['alice']!,
          nonce: sealed.nonce,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });

  group('CryptoLib.encryptBytes / decryptBytes', () {
    test('binary blob round-trip', () async {
      final alice = await CryptoLib.generateIdentityKey();
      final bob = await CryptoLib.generateIdentityKey();
      final k = await CryptoLib.deriveDmKey(alice.privateKey, bob.publicKey);
      final ts = 1_700_000_000_000;
      final plaintext = Uint8List.fromList(utf8.encode('binary voice data here'));
      final box = await CryptoLib.encryptBytes(
        k,
        plaintext,
        senderId: 'alice',
        conversationId: 'conv1',
        createdAtMs: ts,
      );
      final recovered = await CryptoLib.decryptBytes(
        k,
        box.ciphertext,
        box.nonce,
        senderId: 'alice',
        conversationId: 'conv1',
        createdAtMs: ts,
      );
      expect(recovered, equals(plaintext));
    });
  });
}
