// Settings/profile-scoped wrapper around the quick.v1.Users service.
//
// Reuses the project-wide `ConnectClient` from `lib/api/connect.dart` (the
// foundation owns transport + auth). The shape duplicates the surface in
// `lib/api/services.dart#UsersApi` on purpose — settings and profile widgets
// are landing in parallel, and reconciliation will fold the two together once
// foundation is stable.
//
// Wire field names follow the proto3 JSON mapping (camelCase) the Go server
// emits. UpdateProfile uses optional fields: only the keys we send are
// updated, so callers pass `null` for the ones they want to leave alone.

import '../../../api/connect.dart';
import '../../../api/dto.dart';

class SettingsUsersApi {
  SettingsUsersApi(this._c);

  final ConnectClient _c;

  // GET-equivalent: returns the authenticated user.
  Future<User> me() async {
    final res = await _c.call('quick.v1.Users', 'Me', const {});
    return User.fromJson(
      (res['user'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  // Partial update. Pass only fields that should change — `null` means leave
  // alone. Server returns the freshly persisted User; callers should mirror it
  // into local cache (foundation owns that mirror).
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

  Future<void> block(String userId) async {
    await _c.call('quick.v1.Users', 'Block', {'userId': userId});
  }

  Future<void> unblock(String userId) async {
    await _c.call('quick.v1.Users', 'Unblock', {'userId': userId});
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
}
