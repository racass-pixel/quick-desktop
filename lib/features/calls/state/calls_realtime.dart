// Bridges the foundation-owned realtime envelope stream into the call
// notifiers. One subscription per pair of (CallNotifier, GroupCallNotifier);
// the returned StreamSubscription should be cancelled by the controller on
// sign-out.
//
// Envelope shapes are the snake_case JSON forms emitted by quick-backend's
// internal/calls/handler.go — see incomingCallEnvelope, callAcceptedEnvelope,
// callDeclinedEnvelope, callEndedEnvelope, groupCallStarted/Joined/Left/Ended.

import 'dart:async';

import '../api/calls_api.dart';
import 'call_state.dart';
import 'group_call_state.dart';

/// Foundation's realtime stream is typed as `Stream<Map<String, dynamic>>`
/// (see lib/api/realtime.dart's `typedef WsEnvelope = Map<String, dynamic>`).
/// We re-export the same shape here so callers don't need a direct dep on
/// realtime.dart, and so this file compiles standalone if foundation hasn't
/// landed yet.
typedef CallsWsEnvelope = Map<String, dynamic>;

/// Subscribe to the realtime stream and dispatch call envelopes to both
/// notifiers. Returns a StreamSubscription the caller can cancel on sign-out
/// / hot reload.
StreamSubscription<CallsWsEnvelope> wireCallsRealtime(
  Stream<CallsWsEnvelope> ws,
  CallNotifier call,
  GroupCallNotifier group,
) {
  return ws.listen((env) {
    final kind = env['kind'];
    if (kind is! String) return;
    switch (kind) {
      case 'incoming_call':
        _onIncomingCall(env, call);
        break;
      case 'call_accepted':
        final id = _str(env, 'call_id', 'callId');
        if (id.isNotEmpty) call.onCallAccepted(id);
        break;
      case 'call_declined':
        final id = _str(env, 'call_id', 'callId');
        call.onCallDeclined(id);
        break;
      case 'call_ended':
        final id = _str(env, 'call_id', 'callId');
        call.onCallEnded(id);
        break;
      case 'group_call_started':
        _onGroupCallStarted(env, group);
        break;
      case 'group_call_joined':
        group.onGroupCallJoined(
          convId: _str(env, 'conversation_id', 'conversationId'),
          targetCallId: _str(env, 'call_id', 'callId'),
          participantCount: _intOrNull(env, 'participant_count', 'participantCount'),
        );
        break;
      case 'group_call_left':
        group.onGroupCallLeft(
          convId: _str(env, 'conversation_id', 'conversationId'),
          targetCallId: _str(env, 'call_id', 'callId'),
          participantCount: _intOrNull(env, 'participant_count', 'participantCount'),
        );
        break;
      case 'group_call_ended':
        group.onGroupCallEnded(
          convId: _str(env, 'conversation_id', 'conversationId'),
          targetCallId: _str(env, 'call_id', 'callId'),
        );
        break;
      default:
        // Not ours — ignore. Other features (presence, messaging) listen too.
        break;
    }
  });
}

void _onIncomingCall(CallsWsEnvelope env, CallNotifier call) {
  final id = _str(env, 'call_id', 'callId');
  if (id.isEmpty) return;
  final video = env['video'] == true;
  final callerRaw = env['caller_user'] ?? env['callerUser'];
  CallPeer peer;
  if (callerRaw is Map) {
    peer = CallPeer.fromJson(callerRaw.cast<String, dynamic>());
  } else {
    peer = CallPeer(
      id: _str(env, 'caller_id', 'callerId'),
      displayName: 'Caller',
    );
  }
  if (peer.id.isEmpty) return;
  call.onIncomingCall(callId: id, video: video, caller: peer);
}

void _onGroupCallStarted(CallsWsEnvelope env, GroupCallNotifier group) {
  final raw = env['call'];
  if (raw is Map) {
    group.onGroupCallStarted(
      GroupCallDto.fromJson(raw.cast<String, dynamic>()),
    );
    return;
  }
  // Some backends fan a flat envelope rather than nesting the GroupCall —
  // synthesize a minimal DTO so the banner still appears.
  final convId = _str(env, 'conversation_id', 'conversationId');
  final id = _str(env, 'call_id', 'callId');
  if (convId.isEmpty || id.isEmpty) return;
  group.onGroupCallStarted(GroupCallDto(
    id: id,
    conversationId: convId,
    startedBy: _str(env, 'started_by', 'startedBy'),
    roomName: _str(env, 'room_name', 'roomName'),
    participantCount: 1,
  ));
}

String _str(Map<String, dynamic> env, String a, String b) {
  final va = env[a];
  if (va is String && va.isNotEmpty) return va;
  final vb = env[b];
  if (vb is String && vb.isNotEmpty) return vb;
  return '';
}

int? _intOrNull(Map<String, dynamic> env, String a, String b) {
  final va = env[a];
  if (va is int) return va;
  if (va is num) return va.toInt();
  final vb = env[b];
  if (vb is int) return vb;
  if (vb is num) return vb.toInt();
  return null;
}
