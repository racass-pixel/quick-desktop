// Thin per-service Dart wrappers over the ConnectClient.
//
// Each method names exactly the RPC on the backend and parses the response into
// a DTO from dto.dart. New endpoints get a one-line addition here.

import 'dart:convert';
import 'dart:typed_data';

import 'connect.dart';
import 'dto.dart';

// GroupKeyBundleDto carries the wrapped group key the ConvKeyCache decrypts
// to recover the per-conversation symmetric key.
class GroupKeyBundleDto {
  GroupKeyBundleDto({required this.perMember, required this.nonce});
  // user_id -> wrapped ciphertext (32-byte key + 16-byte tag).
  final Map<String, Uint8List> perMember;
  final Uint8List nonce;
}

class AuthApi {
  AuthApi(this._c);
  final ConnectClient _c;

  // Returns expiresAt for the code's TTL. Errors surface as ConnectError with
  // code 'resource_exhausted' when the per-email/IP rate limit kicks in.
  Future<DateTime?> requestCode(String email) async {
    final res = await _c.call('quick.v1.Auth', 'RequestCode', {'email': email});
    final s = res['expiresAt'] as String?;
    return s == null ? null : DateTime.tryParse(s);
  }

  Future<({String token, User user, bool isNewAccount})> verifyCode(
    String email,
    String code,
  ) async {
    final res = await _c.call('quick.v1.Auth', 'VerifyCode', {
      'email': email,
      'code': code,
    });
    return (
      token: (res['token'] as String?) ?? '',
      user: User.fromJson((res['user'] as Map?)?.cast<String, dynamic>() ?? {}),
      isNewAccount: (res['isNewAccount'] as bool?) ?? false,
    );
  }

  Future<void> logout() async {
    await _c.call('quick.v1.Auth', 'Logout', const {});
  }

  // Creates a brand-new account in one round-trip and returns the freshly-
  // generated passkey alongside the session. Surfaces ConnectError with code
  // 'already_exists' when the email is already registered — the caller is
  // expected to branch into the login flow on that error.
  Future<SignupWithPasskeyResult> signupWithPasskey(String email) async {
    final res = await _c.call('quick.v1.Auth', 'SignupWithPasskey', {
      'email': email,
    });
    return SignupWithPasskeyResult(
      token: (res['sessionToken'] as String?) ??
          (res['session_token'] as String?) ??
          (res['token'] as String?) ??
          '',
      user: User.fromJson(
          (res['user'] as Map?)?.cast<String, dynamic>() ?? const {}),
      passkey: (res['passkey'] as String?) ?? '',
    );
  }

  // Exchanges a known email + passkey pair for a session. Surfaces
  // ConnectError with code 'unauthenticated' for both unknown email and bad
  // passkey — kept indistinguishable to avoid email-enumeration.
  Future<LoginWithPasskeyResult> loginWithPasskey(
      String email, String passkey) async {
    final res = await _c.call('quick.v1.Auth', 'LoginWithPasskey', {
      'email': email,
      'passkey': passkey,
    });
    return LoginWithPasskeyResult(
      token: (res['sessionToken'] as String?) ??
          (res['session_token'] as String?) ??
          (res['token'] as String?) ??
          '',
      user: User.fromJson(
          (res['user'] as Map?)?.cast<String, dynamic>() ?? const {}),
    );
  }
}

class UsersApi {
  UsersApi(this._c);
  final ConnectClient _c;

  Future<User> me() async {
    final res = await _c.call('quick.v1.Users', 'Me', const {});
    return User.fromJson(
      (res['user'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  Future<List<User>> search(String prefix, {int limit = 12}) async {
    final res = await _c.call('quick.v1.Users', 'Search', {
      'handlePrefix': prefix,
      'limit': limit,
    });
    final list = (res['users'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => User.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  // Partial update — pass null to leave a field alone.
  Future<User> updateProfile({
    String? displayName,
    String? handle,
    String? bio,
  }) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['displayName'] = displayName;
    if (handle != null) body['handle'] = handle;
    if (bio != null) body['bio'] = bio;
    final res = await _c.call('quick.v1.Users', 'UpdateProfile', body);
    return User.fromJson(
      (res['user'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  Future<List<Presence>> getPresence(List<String> userIds) async {
    if (userIds.isEmpty) return const [];
    final res = await _c.call('quick.v1.Users', 'GetPresence', {
      'userIds': userIds,
    });
    final list = (res['presence'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => Presence.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  // --- E2E identity keys ---

  Future<void> uploadIdentityKey(Uint8List publicKey) async {
    await _c.call('quick.v1.Users', 'UploadIdentityKey', {
      'publicKey': base64Encode(publicKey),
    });
  }

  // Returns the 32-byte public key, or null when the user hasn't uploaded one.
  Future<Uint8List?> getIdentityKey(String userId) async {
    try {
      final res = await _c.call('quick.v1.Users', 'GetIdentityKey', {
        'userId': userId,
      });
      final raw = (res['identityKey'] as Map?)?['publicKey'];
      if (raw is! String || raw.isEmpty) return null;
      return Uint8List.fromList(base64Decode(raw));
    } catch (_) {
      // NOT_FOUND surfaces as ConnectError — treat as "no key yet".
      return null;
    }
  }

  // Batch fetch — missing users are silently dropped on the server. Returns
  // a userId -> publicKey map.
  Future<Map<String, Uint8List>> getIdentityKeys(List<String> userIds) async {
    if (userIds.isEmpty) return const {};
    final res = await _c.call('quick.v1.Users', 'GetIdentityKeys', {
      'userIds': userIds,
    });
    final out = <String, Uint8List>{};
    final list = (res['identityKeys'] as List?) ?? const [];
    for (final entry in list) {
      if (entry is! Map) continue;
      final j = entry.cast<String, dynamic>();
      final uid = j['userId'] as String?;
      final pk = j['publicKey'] as String?;
      if (uid == null || pk == null || pk.isEmpty) continue;
      out[uid] = Uint8List.fromList(base64Decode(pk));
    }
    return out;
  }
}

class MessagingApi {
  MessagingApi(this._c);
  final ConnectClient _c;

  Future<List<Conversation>> listConversations() async {
    final res = await _c.call('quick.v1.Messaging', 'ListConversations', const {});
    final list = (res['conversations'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => Conversation.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<Conversation> openDM(String peerUserId) async {
    final res = await _c.call('quick.v1.Messaging', 'OpenDM', {
      'userId': peerUserId,
    });
    return Conversation.fromJson(
      (res['conversation'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  // beforeId/afterId are mutually exclusive cursors; both empty = newest page.
  Future<({List<Message> messages, bool hasMore})> listMessages(
    String conversationId, {
    String? beforeId,
    String? afterId,
    int limit = 50,
  }) async {
    final res = await _c.call('quick.v1.Messaging', 'ListMessages', {
      'conversationId': conversationId,
      if (beforeId != null && beforeId.isNotEmpty) 'beforeId': beforeId,
      if (afterId != null && afterId.isNotEmpty) 'afterId': afterId,
      'limit': limit,
    });
    final list = (res['messages'] as List?) ?? const [];
    final msgs = list
        .whereType<Map>()
        .map((m) => Message.fromJson(m.cast<String, dynamic>()))
        .toList();
    return (messages: msgs, hasMore: (res['hasMore'] as bool?) ?? false);
  }

  // sendMessage. When `encryptedCiphertext` is non-null the body field is
  // ignored — server stores only the sealed payload.
  Future<Message> sendMessage(
    String conversationId,
    String body, {
    Uint8List? encryptedCiphertext,
    Uint8List? encryptedNonce,
    String? encryptedSenderKeyId,
    String? replyToMessageId,
    List<String> attachmentFileIds = const <String>[],
  }) async {
    final payload = <String, dynamic>{
      'conversationId': conversationId,
      'body': body,
    };
    if (encryptedCiphertext != null && encryptedNonce != null) {
      payload['body'] = '';
      payload['encrypted'] = {
        'ciphertext': base64Encode(encryptedCiphertext),
        'nonce': base64Encode(encryptedNonce),
        if (encryptedSenderKeyId != null && encryptedSenderKeyId.isNotEmpty)
          'senderKeyId': encryptedSenderKeyId,
      };
    }
    if (replyToMessageId != null && replyToMessageId.isNotEmpty) {
      payload['replyToMessageId'] = replyToMessageId;
    }
    if (attachmentFileIds.isNotEmpty) {
      payload['attachmentFileIds'] = attachmentFileIds;
    }
    final res = await _c.call('quick.v1.Messaging', 'SendMessage', payload);
    return Message.fromJson(
      (res['message'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  // --- Reactions / Forward / Search ---

  Future<void> addReaction(String messageId, String emoji) async {
    await _c.call('quick.v1.Messaging', 'AddReaction', {
      'messageId': messageId,
      'emoji': emoji,
    });
  }

  Future<void> removeReaction(String messageId, String emoji) async {
    await _c.call('quick.v1.Messaging', 'RemoveReaction', {
      'messageId': messageId,
      'emoji': emoji,
    });
  }

  Future<List<Reaction>> listReactions(String messageId) async {
    final res = await _c.call('quick.v1.Messaging', 'ListReactions', {
      'messageId': messageId,
    });
    final list = (res['reactions'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => Reaction.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<Message> forwardMessage(
    String sourceMessageId,
    String targetConversationId,
  ) async {
    final res = await _c.call('quick.v1.Messaging', 'ForwardMessage', {
      'sourceMessageId': sourceMessageId,
      'targetConversationId': targetConversationId,
    });
    return Message.fromJson(
      (res['message'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  Future<List<Message>> searchMessages({
    required String query,
    String? conversationId,
    int limit = 30,
    String? beforeId,
  }) async {
    final body = <String, dynamic>{
      'query': query,
      'limit': limit,
    };
    if (conversationId != null && conversationId.isNotEmpty) {
      body['conversationId'] = conversationId;
    }
    if (beforeId != null && beforeId.isNotEmpty) {
      body['beforeId'] = beforeId;
    }
    final res =
        await _c.call('quick.v1.Messaging', 'SearchMessages', body);
    final list = (res['messages'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => Message.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<void> markRead(String conversationId, String lastMessageId) async {
    await _c.call('quick.v1.Messaging', 'MarkRead', {
      'conversationId': conversationId,
      'lastMessageId': lastMessageId,
    });
  }

  // --- E2E group key bundles ---

  Future<void> putGroupKeyBundle(
    String conversationId,
    Map<String, Uint8List> perMember,
    Uint8List nonce,
  ) async {
    final wrapped = <String, String>{
      for (final e in perMember.entries) e.key: base64Encode(e.value),
    };
    await _c.call('quick.v1.Messaging', 'PutGroupKeyBundle', {
      'conversationId': conversationId,
      'ciphertextPerMember': wrapped,
      'nonce': base64Encode(nonce),
    });
  }

  Future<GroupKeyBundleDto?> getGroupKeyBundle(String conversationId) async {
    try {
      final res = await _c.call('quick.v1.Messaging', 'GetGroupKeyBundle', {
        'conversationId': conversationId,
      });
      final raw = (res['bundle'] as Map?)?.cast<String, dynamic>();
      if (raw == null) return null;
      final perMemberRaw = (raw['ciphertextPerMember'] as Map?)?.cast<String, dynamic>() ?? const {};
      final perMember = <String, Uint8List>{};
      perMemberRaw.forEach((k, v) {
        if (v is String && v.isNotEmpty) {
          perMember[k] = Uint8List.fromList(base64Decode(v));
        }
      });
      final nonceRaw = raw['nonce'] as String?;
      if (nonceRaw == null || nonceRaw.isEmpty) return null;
      return GroupKeyBundleDto(
        perMember: perMember,
        nonce: Uint8List.fromList(base64Decode(nonceRaw)),
      );
    } catch (_) {
      return null;
    }
  }
}
