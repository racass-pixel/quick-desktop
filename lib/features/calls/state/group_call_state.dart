// GroupCallNotifier — Telegram-style voice chat for a group/channel.
//
// Differences from CallNotifier (1:1):
//   - No ring/accept/decline. The conversation has an active GroupCall while
//     at least one member is connected; everyone else sees a banner + Join.
//   - Two leaves: `none` (not in any group call) / `active` (in one). A group
//     call can exist on the server while we're not in it — that lives in
//     `activeByConv` for banner data.
//
// WS envelopes consumed via on* handlers:
//   group_call_started   → activeByConv[convId] = call         (banner appears)
//   group_call_joined    → bump participantCount                (banner refresh)
//   group_call_left      → drop participantCount                (banner refresh)
//   group_call_ended     → delete activeByConv[convId]; if we're in it, leave.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../api/calls_api.dart';

enum GroupCallLifecycle { none, active }

class GroupCallNotifier extends ChangeNotifier {
  GroupCallNotifier(this._api);
  final CallsApi _api;

  // ---- public state ----
  GroupCallLifecycle lifecycle = GroupCallLifecycle.none;
  String? callId;
  String? conversationId;
  CallJoin? join;
  DateTime? startedAt;
  bool isAudio = true;
  bool isVideo = false;
  bool isScreenSharing = false;
  bool isMinimized = false;

  /// Banner cache. Keyed by conversation id; populated by refreshActive and
  /// mutated incrementally via WS envelopes.
  final Map<String, GroupCallDto> activeByConv = {};

  /// Live remote participants keyed by sid.
  final Map<String, RemoteParticipant> remotes = {};

  /// LiveKit identities currently speaking. The local participant's identity
  /// is included by activeSpeakersChanged when our mic is hot, so consumers
  /// can use a single lookup key.
  final Set<String> activeSpeakers = {};

  Room? _room;
  LocalParticipant? _local;
  EventsListener<RoomEvent>? _listener;

  Room? get room => _room;
  LocalParticipant? get local => _local;

  // ---- internal ----

  Future<void> _disposeRoom() async {
    final r = _room;
    _room = null;
    _local = null;
    final l = _listener;
    _listener = null;
    if (l != null) {
      try { await l.dispose(); } catch (_) {/* ignore */}
    }
    if (r != null) {
      try { await r.disconnect(); } catch (_) {/* ignore */}
      try { await r.dispose(); } catch (_) {/* ignore */}
    }
  }

  void _refreshRemotes() {
    final room = _room;
    remotes.clear();
    if (room == null) return;
    for (final rp in room.remoteParticipants.values) {
      remotes[rp.sid] = rp;
    }
  }

  Future<void> _connectRoom(CallJoin j) async {
    await _disposeRoom();
    final room = Room(
      roomOptions: const RoomOptions(
        adaptiveStream: true,
        dynacast: true,
      ),
    );
    _room = room;
    final listener = room.createListener();
    _listener = listener;

    listener
      ..on<ParticipantConnectedEvent>((e) {
        remotes[e.participant.sid] = e.participant;
        notifyListeners();
      })
      ..on<ParticipantDisconnectedEvent>((e) {
        remotes.remove(e.participant.sid);
        notifyListeners();
      })
      ..on<TrackSubscribedEvent>((_) => notifyListeners())
      ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
      ..on<TrackMutedEvent>((_) => notifyListeners())
      ..on<TrackUnmutedEvent>((_) => notifyListeners())
      ..on<LocalTrackPublishedEvent>((_) => notifyListeners())
      ..on<LocalTrackUnpublishedEvent>((_) => notifyListeners())
      ..on<ActiveSpeakersChangedEvent>((e) {
        activeSpeakers
          ..clear()
          ..addAll(e.speakers.map((p) => p.identity).where((s) => s.isNotEmpty));
        notifyListeners();
      })
      ..on<RoomDisconnectedEvent>((_) {
        if (lifecycle != GroupCallLifecycle.none) {
          // ignore: discarded_futures
          leaveGroupCall();
        }
      });

    final url = j.livekitUrl.isNotEmpty ? j.livekitUrl : 'wss://livekit.quick-network.vu';
    await room.connect(url, j.token);
    final lp = room.localParticipant;
    _local = lp;
    // Voice-chat default — mic on, camera off. Matches the TG model.
    if (lp != null) await lp.setMicrophoneEnabled(true);
    isAudio = true;
    isVideo = false;
    isScreenSharing = false;
    _refreshRemotes();
    notifyListeners();
  }

  // ---- public API ----

  Future<void> startGroupCall(String convId) async {
    if (lifecycle != GroupCallLifecycle.none) return;
    final res = await _api.startGroupCall(convId);
    activeByConv[convId] = res.call;
    callId = res.call.id;
    conversationId = convId;
    join = res.join;
    startedAt = DateTime.now();
    lifecycle = GroupCallLifecycle.active;
    notifyListeners();
    try {
      await _connectRoom(res.join);
    } catch (e) {
      await _disposeRoom();
      try { await _api.endGroupCall(res.call.id); } catch (_) {/* ignore */}
      _hardReset();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> joinGroupCall(String callId, String convId) async {
    if (lifecycle != GroupCallLifecycle.none) return;
    final j = await _api.joinGroupCall(callId);
    this.callId = callId;
    conversationId = convId;
    join = j;
    startedAt = DateTime.now();
    lifecycle = GroupCallLifecycle.active;
    notifyListeners();
    try {
      await _connectRoom(j);
    } catch (e) {
      await _disposeRoom();
      _hardReset();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> leaveGroupCall() async {
    if (lifecycle != GroupCallLifecycle.active) return;
    final id = callId;
    await _disposeRoom();
    _hardReset();
    notifyListeners();
    if (id != null && id.isNotEmpty) {
      try { await _api.leaveGroupCall(id); } catch (_) {/* best effort */}
    }
  }

  /// Owner/admin only — force-end. Falls back to leave locally.
  Future<void> endGroupCall() async {
    if (lifecycle != GroupCallLifecycle.active) return;
    final id = callId;
    await _disposeRoom();
    _hardReset();
    notifyListeners();
    if (id != null && id.isNotEmpty) {
      try { await _api.endGroupCall(id); } catch (_) {/* best effort */}
    }
  }

  Future<void> refreshActive(List<String> convIds) async {
    if (convIds.isEmpty) return;
    try {
      final calls = await _api.listActiveGroupCalls(convIds);
      // Drop stale entries for the queried convs, then merge fresh.
      for (final id in convIds) {
        activeByConv.remove(id);
      }
      for (final c in calls) {
        if (c.conversationId.isNotEmpty) activeByConv[c.conversationId] = c;
      }
      notifyListeners();
    } catch (_) {
      // Banner will retry on next conv open.
    }
  }

  // ---- toggles ----

  Future<void> toggleMic() async {
    final lp = _local;
    if (lp == null) return;
    final next = !isAudio;
    await lp.setMicrophoneEnabled(next);
    isAudio = next;
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final lp = _local;
    if (lp == null) return;
    final next = !isVideo;
    await lp.setCameraEnabled(next);
    isVideo = next;
    notifyListeners();
  }

  Future<void> startScreenShare() async {
    final lp = _local;
    if (lp == null || isScreenSharing) return;
    try {
      // See CallNotifier.startScreenShare for the anti-echo gotcha on Windows.
      // TODO(calls-anti-echo): plumb a desktop-source picker and a virtual-cable hint.
      await lp.setScreenShareEnabled(
        true,
        captureScreenAudio: true,
        screenShareCaptureOptions: const ScreenShareCaptureOptions(
          captureScreenAudio: true,
          maxFrameRate: 30,
          params: VideoParametersPresets.screenShareH1080FPS15,
        ),
      );
      isScreenSharing = true;
    } catch (_) {
      isScreenSharing = false;
    }
    notifyListeners();
  }

  Future<void> stopScreenShare() async {
    final lp = _local;
    if (lp == null) return;
    try { await lp.setScreenShareEnabled(false); } catch (_) {/* ignore */}
    isScreenSharing = false;
    notifyListeners();
  }

  void minimize() {
    if (lifecycle == GroupCallLifecycle.none) return;
    isMinimized = true;
    notifyListeners();
  }

  void expand() {
    if (!isMinimized) return;
    isMinimized = false;
    notifyListeners();
  }

  // ---- WS handlers ----

  void onGroupCallStarted(GroupCallDto call) {
    if (call.conversationId.isEmpty || call.id.isEmpty) return;
    activeByConv[call.conversationId] = call;
    notifyListeners();
  }

  void onGroupCallJoined({
    required String convId,
    String? targetCallId,
    int? participantCount,
  }) {
    if (convId.isEmpty) return;
    final existing = activeByConv[convId];
    if (existing == null) return;
    if (targetCallId != null && targetCallId.isNotEmpty && existing.id != targetCallId) {
      return;
    }
    final nextCount = participantCount ?? (existing.participantCount + 1);
    activeByConv[convId] = GroupCallDto(
      id: existing.id,
      conversationId: existing.conversationId,
      startedBy: existing.startedBy,
      roomName: existing.roomName,
      participantCount: nextCount,
      startedAt: existing.startedAt,
    );
    notifyListeners();
  }

  void onGroupCallLeft({
    required String convId,
    String? targetCallId,
    int? participantCount,
  }) {
    if (convId.isEmpty) return;
    final existing = activeByConv[convId];
    if (existing == null) return;
    if (targetCallId != null && targetCallId.isNotEmpty && existing.id != targetCallId) {
      return;
    }
    final nextCount = participantCount ?? ((existing.participantCount - 1).clamp(0, 1 << 30));
    activeByConv[convId] = GroupCallDto(
      id: existing.id,
      conversationId: existing.conversationId,
      startedBy: existing.startedBy,
      roomName: existing.roomName,
      participantCount: nextCount,
      startedAt: existing.startedAt,
    );
    notifyListeners();
  }

  void onGroupCallEnded({required String convId, String? targetCallId}) {
    if (convId.isEmpty) return;
    final existing = activeByConv[convId];
    if (existing != null &&
        (targetCallId == null || targetCallId.isEmpty || existing.id == targetCallId)) {
      activeByConv.remove(convId);
    }
    // If we're in this call, tear our session down too.
    if (lifecycle == GroupCallLifecycle.active &&
        conversationId == convId &&
        (targetCallId == null || targetCallId.isEmpty || callId == targetCallId)) {
      // ignore: discarded_futures
      _disposeRoom().then((_) {
        _hardReset();
        notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  void _hardReset() {
    lifecycle = GroupCallLifecycle.none;
    callId = null;
    conversationId = null;
    join = null;
    startedAt = null;
    isAudio = true;
    isVideo = false;
    isScreenSharing = false;
    isMinimized = false;
    remotes.clear();
    activeSpeakers.clear();
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _disposeRoom();
    super.dispose();
  }
}
