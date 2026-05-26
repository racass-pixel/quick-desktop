// Group/channel mutation wrapper over quick.v1.Messaging.
//
// Mirrors the wire shapes in `quick-protocol/proto/quick/v1/messaging.proto`:
//
//   CreateGroupRequest        { title, member_user_ids[] }
//   CreateChannelRequest      { title, subscriber_user_ids[] }
//   AddMembersRequest         { conversation_id, user_ids[] }
//   RemoveMemberRequest       { conversation_id, user_id }
//   ListMembersRequest        { conversation_id }
//   LeaveConversationRequest  { conversation_id }
//
// The desktop UI keeps create + add as separate user steps (TG-style), so the
// CreateGroup / CreateChannel calls here accept an empty member list and
// AddMembers is called afterwards. The backend tolerates both flows.

import '../../../api/connect.dart';
import '../../../api/dto.dart';

class Member {
  Member({
    required this.user,
    required this.role,
    this.joinedAt,
  });

  // Server may omit `user` for rows whose user record was deleted — callers
  // should skip those.
  final User? user;
  final String role;
  final DateTime? joinedAt;

  factory Member.fromJson(Map<String, dynamic> j) {
    final u = j['user'];
    DateTime? joined;
    final ja = j['joinedAt'] ?? j['joined_at'];
    if (ja is String && ja.isNotEmpty) {
      joined = DateTime.tryParse(ja)?.toLocal();
    }
    return Member(
      user: u is Map<String, dynamic>
          ? User.fromJson(u)
          : (u is Map ? User.fromJson(u.cast<String, dynamic>()) : null),
      role: (j['role'] as String?) ?? 'member',
      joinedAt: joined,
    );
  }
}

class GroupsApi {
  GroupsApi(this._c);

  final ConnectClient _c;

  Future<Conversation> createGroup(
    String title, {
    List<String> memberUserIds = const [],
  }) async {
    final res = await _c.call('quick.v1.Messaging', 'CreateGroup', {
      'title': title,
      'memberUserIds': memberUserIds,
    });
    return Conversation.fromJson(
      (res['conversation'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  // The wire protocol carries `title` for channels (no separate handle field
  // today). The UI surfaces a `@handle` input for user expectation parity
  // with Telegram — it's persisted into `title` until a dedicated handle
  // column exists server-side. `subscriberUserIds` mirrors the proto name.
  Future<Conversation> createChannel(
    String title, {
    List<String> subscriberUserIds = const [],
  }) async {
    final res = await _c.call('quick.v1.Messaging', 'CreateChannel', {
      'title': title,
      'subscriberUserIds': subscriberUserIds,
    });
    return Conversation.fromJson(
      (res['conversation'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  Future<void> addMembers(String conversationId, List<String> userIds) async {
    if (userIds.isEmpty) return;
    await _c.call('quick.v1.Messaging', 'AddMembers', {
      'conversationId': conversationId,
      'userIds': userIds,
    });
  }

  Future<void> removeMember(String conversationId, String userId) async {
    await _c.call('quick.v1.Messaging', 'RemoveMember', {
      'conversationId': conversationId,
      'userId': userId,
    });
  }

  Future<List<Member>> listMembers(String conversationId) async {
    final res = await _c.call('quick.v1.Messaging', 'ListMembers', {
      'conversationId': conversationId,
    });
    final list = (res['members'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => Member.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<void> leaveConversation(String conversationId) async {
    await _c.call('quick.v1.Messaging', 'LeaveConversation', {
      'conversationId': conversationId,
    });
  }
}
