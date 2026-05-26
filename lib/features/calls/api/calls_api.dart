// Connect-RPC wrappers for the quick.v1.Calls service.
//
// Mirrors the 9 RPCs the backend exposes (1:1 + group). Each method returns a
// small DTO matching the proto3-JSON shapes the server emits — camelCase keys,
// snake_case fallbacks only where the backend's hand-written WS envelopes use
// them (see calls_realtime.dart).
//
// Talks to the foundation-owned ConnectClient (see lib/api/connect.dart).
// Keeping this thin so the feature compiles standalone before the foundation
// agent finishes wiring everything up — only the import path matters.

import '../../../api/connect.dart';

class CallJoin {
  CallJoin({
    required this.roomName,
    required this.token,
    required this.livekitUrl,
  });

  final String roomName;
  final String token;
  final String livekitUrl;

  factory CallJoin.fromJson(Map<String, dynamic> j) => CallJoin(
        roomName: (j['roomName'] as String?) ?? (j['room_name'] as String?) ?? '',
        token: (j['token'] as String?) ?? '',
        livekitUrl:
            (j['livekitUrl'] as String?) ?? (j['livekit_url'] as String?) ?? '',
      );
}

class GroupCallDto {
  GroupCallDto({
    required this.id,
    required this.conversationId,
    required this.startedBy,
    required this.roomName,
    required this.participantCount,
    this.startedAt,
  });

  final String id;
  final String conversationId;
  final String startedBy;
  final String roomName;
  final int participantCount;
  final DateTime? startedAt;

  factory GroupCallDto.fromJson(Map<String, dynamic> j) {
    final startedRaw =
        j['startedAt'] ?? j['started_at']; // proto3-JSON emits RFC3339 strings.
    DateTime? started;
    if (startedRaw is String && startedRaw.isNotEmpty) {
      started = DateTime.tryParse(startedRaw)?.toLocal();
    }
    final pc = j['participantCount'] ?? j['participant_count'] ?? 0;
    return GroupCallDto(
      id: (j['id'] as String?) ?? '',
      conversationId: (j['conversationId'] as String?) ??
          (j['conversation_id'] as String?) ??
          '',
      startedBy:
          (j['startedBy'] as String?) ?? (j['started_by'] as String?) ?? '',
      roomName:
          (j['roomName'] as String?) ?? (j['room_name'] as String?) ?? '',
      participantCount: pc is int ? pc : int.tryParse(pc.toString()) ?? 0,
      startedAt: started,
    );
  }
}

class StartCallResult {
  StartCallResult({required this.callId, required this.join});
  final String callId;
  final CallJoin join;
}

class StartGroupCallResult {
  StartGroupCallResult({required this.call, required this.join});
  final GroupCallDto call;
  final CallJoin join;
}

class CallsApi {
  CallsApi(this._c);
  final ConnectClient _c;

  static const _svc = 'quick.v1.Calls';

  // ---- 1:1 ----

  Future<StartCallResult> startCall({
    required String peerUserId,
    bool video = false,
  }) async {
    final res = await _c.call(_svc, 'StartCall', {
      'userId': peerUserId,
      'video': video,
    });
    final j = (res['join'] as Map?)?.cast<String, dynamic>() ?? const {};
    return StartCallResult(
      callId: (res['callId'] as String?) ?? (res['call_id'] as String?) ?? '',
      join: CallJoin.fromJson(j),
    );
  }

  Future<CallJoin> acceptCall(String callId) async {
    final res = await _c.call(_svc, 'AcceptCall', {'callId': callId});
    final j = (res['join'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CallJoin.fromJson(j);
  }

  Future<void> declineCall(String callId) async {
    await _c.call(_svc, 'DeclineCall', {'callId': callId});
  }

  Future<void> endCall(String callId) async {
    await _c.call(_svc, 'EndCall', {'callId': callId});
  }

  // ---- Group ----

  Future<StartGroupCallResult> startGroupCall(String conversationId) async {
    final res = await _c.call(_svc, 'StartGroupCall', {
      'conversationId': conversationId,
    });
    final j = (res['join'] as Map?)?.cast<String, dynamic>() ?? const {};
    final c = (res['call'] as Map?)?.cast<String, dynamic>() ?? const {};
    return StartGroupCallResult(
      call: GroupCallDto.fromJson(c),
      join: CallJoin.fromJson(j),
    );
  }

  Future<CallJoin> joinGroupCall(String callId) async {
    final res = await _c.call(_svc, 'JoinGroupCall', {'callId': callId});
    final j = (res['join'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CallJoin.fromJson(j);
  }

  Future<void> leaveGroupCall(String callId) async {
    await _c.call(_svc, 'LeaveGroupCall', {'callId': callId});
  }

  // Owner/admin only — force-ends for everyone. Regular participants leave.
  Future<void> endGroupCall(String callId) async {
    await _c.call(_svc, 'EndGroupCall', {'callId': callId});
  }

  Future<List<GroupCallDto>> listActiveGroupCalls(
    List<String> conversationIds,
  ) async {
    if (conversationIds.isEmpty) return const [];
    final res = await _c.call(_svc, 'ListActiveGroupCalls', {
      'conversationIds': conversationIds,
    });
    final list = (res['calls'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((m) => GroupCallDto.fromJson(m.cast<String, dynamic>()))
        .toList();
  }
}
