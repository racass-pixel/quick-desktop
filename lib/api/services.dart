// Thin per-service Dart wrappers over the ConnectClient.
//
// Each method names exactly the RPC on the backend and parses the response into
// a DTO from dto.dart. New endpoints get a one-line addition here.

import 'connect.dart';
import 'dto.dart';

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

  Future<Message> sendMessage(String conversationId, String body) async {
    final res = await _c.call('quick.v1.Messaging', 'SendMessage', {
      'conversationId': conversationId,
      'body': body,
    });
    return Message.fromJson(
      (res['message'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  Future<void> markRead(String conversationId, String lastMessageId) async {
    await _c.call('quick.v1.Messaging', 'MarkRead', {
      'conversationId': conversationId,
      'lastMessageId': lastMessageId,
    });
  }
}
