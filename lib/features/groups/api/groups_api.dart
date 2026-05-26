// Group/channel mutation wrapper over quick.v1.Messaging.
//
// Mirrors the wire shapes in `quick-protocol/proto/quick/v1/messaging.proto`:
//
//   CreateGroupRequest    { title, member_user_ids[] }
//   CreateChannelRequest  { title, subscriber_user_ids[] }
//   AddMembersRequest     { conversation_id, user_ids[] }
//   RemoveMemberRequest   { conversation_id, user_id }
//
// The desktop UI keeps create + add as separate user steps (TG-style), so the
// CreateGroup / CreateChannel calls here accept an empty member list and
// AddMembers is called afterwards. The backend tolerates both flows.

import '../../../api/connect.dart';
import '../../../api/dto.dart';

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
}
