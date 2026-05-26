// Voice-message E2E helpers.
//
// MVP scope: encrypt the audio bytes BEFORE upload, decrypt them after
// download but before handing to the audio player. The 64-byte waveform
// peaks and the duration_ms stay plaintext — they're envelope metadata,
// not message content, and the backend needs them to render the bubble
// preview without downloading the blob.
//
// Wire shape inside the existing /v1/media/voice endpoint:
//   * the file body is the raw AES-GCM ciphertext (no per-blob nonce
//     prefix — the nonce rides as a multipart form field so the existing
//     handler keeps streaming the file bytes straight to MinIO).
//   * the form gains `encrypted=1` and `encrypted_nonce=<base64>`. Old
//     clients omit these and the server stores the bytes as-is.
//
// Recipient flow:
//   * GET /v1/media/voice/<id> returns the ciphertext (server doesn't
//     interpret).
//   * client looks up the per-message nonce on the message row, derives
//     the conv key the same way text messages do, decrypts, hands to
//     just_audio via a Uint8List source (the just_audio package supports
//     BytesAudioSource on Windows from v0.9.x).
//
// This file owns the AES-GCM encrypt / decrypt helpers; the wiring into
// VoiceApi and the voice player lives in feature land.

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto.dart';

class EncryptedVoice {
  EncryptedVoice({required this.ciphertext, required this.nonce});
  final Uint8List ciphertext;
  final Uint8List nonce;
}

class VoiceCrypto {
  VoiceCrypto._();

  // Encrypt a raw audio blob for the given conversation. AAD format mirrors
  // the text path so a server can't splice voice ciphertext across chats.
  static Future<EncryptedVoice> encrypt({
    required SecretKey convKey,
    required Uint8List audioBytes,
    required String senderId,
    required String conversationId,
    required int createdAtMs,
  }) async {
    final box = await CryptoLib.encryptBytes(
      convKey,
      audioBytes,
      senderId: senderId,
      conversationId: conversationId,
      createdAtMs: createdAtMs,
    );
    return EncryptedVoice(ciphertext: box.ciphertext, nonce: box.nonce);
  }

  // Decrypt a downloaded voice blob.
  static Future<Uint8List> decrypt({
    required SecretKey convKey,
    required Uint8List ciphertext,
    required Uint8List nonce,
    required String senderId,
    required String conversationId,
    required int createdAtMs,
  }) {
    return CryptoLib.decryptBytes(
      convKey,
      ciphertext,
      nonce,
      senderId: senderId,
      conversationId: conversationId,
      createdAtMs: createdAtMs,
    );
  }
}
