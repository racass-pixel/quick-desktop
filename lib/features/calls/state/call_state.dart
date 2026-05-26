// CallNotifier — single-source-of-truth for the active 1:1 call.
//
// Lifecycle states:
//   idle         — no call.
//   ringingOut   — we initiated; waiting for the peer to accept. The Room is
//                  already connecting in the background so audio/video flow
//                  as soon as the peer joins.
//   incoming     — the peer is calling us. IncomingCallDialog is up.
//   active       — both parties connected. Media is flowing.
//
// Wires the LiveKit Room events (participantConnected/Disconnected,
// activeSpeakersChanged, trackSubscribed/Unsubscribed, disconnected) into the
// notifier so the UI (CallScreen / CallPip / ParticipantTile) can subscribe.
//
// Held outside the notifier:
//   _activeRoom  — the live livekit_client Room. Stored as a static so
//                  ChangeNotifier doesn't try to dispose it on rebuild; the
//                  notifier explicitly tears it down on end()/decline().

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import '../api/calls_api.dart';

enum CallLifecycle { idle, ringingOut, incoming, active }

class CallPeer {
  CallPeer({
    required this.id,
    required this.displayName,
    this.handle,
    this.avatarColor,
  });

  final String id;
  final String displayName;
  final String? handle;
  final String? avatarColor;

  factory CallPeer.fromJson(Map<String, dynamic> j) => CallPeer(
        id: (j['id'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ??
            (j['display_name'] as String?) ??
            (j['handle'] as String?) ??
            'Caller',
        handle: (j['handle'] as String?),
        avatarColor: (j['avatarColor'] as String?) ??
            (j['avatar_color'] as String?),
      );
}

class CallNotifier extends ChangeNotifier {
  CallNotifier(this._api);
  final CallsApi _api;

  // ---- public state ----
  CallLifecycle lifecycle = CallLifecycle.idle;
  String? callId;
  CallPeer? peer;
  CallJoin? join;
  bool isVideo = false;
  bool isAudio = true; // mic on by default once connected.
  bool isScreenSharing = false;
  bool isMinimized = false;
  DateTime? startedAt;

  Room? _room;
  LocalParticipant? _local;
  EventsListener<RoomEvent>? _listener;
  Timer? _incomingTimer;

  /// Telegram-style ring TTL — drop incoming after 60s if not answered.
  static const Duration incomingTtl = Duration(seconds: 60);

  Room? get room => _room;
  LocalParticipant? get local => _local;

  /// Live participants keyed by sid → for participant tiles.
  final Map<String, RemoteParticipant> remotes = {};

  /// LiveKit participant identities currently producing audio. Driven by
  /// activeSpeakersChanged; consumed by ParticipantTile for the green ring.
  final Set<String> activeSpeakers = {};

  // ---- internal helpers ----

  void _resetMediaState() {
    isVideo = false;
    isAudio = true;
    isScreenSharing = false;
    isMinimized = false;
    remotes.clear();
    activeSpeakers.clear();
    startedAt = null;
  }

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

  void _cancelIncomingTimer() {
    _incomingTimer?.cancel();
    _incomingTimer = null;
  }

  Future<void> _connectRoom(CallJoin j, {required bool publishVideo}) async {
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
        // In 1:1, the peer leaving = call ends.
        if (lifecycle == CallLifecycle.active ||
            lifecycle == CallLifecycle.ringingOut) {
          // Fire-and-forget; do not block the event loop.
          // ignore: discarded_futures
          end();
        } else {
          notifyListeners();
        }
      })
      ..on<TrackSubscribedEvent>((_) => notifyListeners())
      ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
      ..on<LocalTrackPublishedEvent>((_) => notifyListeners())
      ..on<LocalTrackUnpublishedEvent>((_) => notifyListeners())
      ..on<ActiveSpeakersChangedEvent>((e) {
        activeSpeakers
          ..clear()
          ..addAll(e.speakers.map((p) => p.identity).where((s) => s.isNotEmpty));
        notifyListeners();
      })
      ..on<RoomDisconnectedEvent>((_) {
        // Server-driven close — surface as end.
        if (lifecycle != CallLifecycle.idle) {
          // ignore: discarded_futures
          end();
        }
      });

    final url = j.livekitUrl.isNotEmpty ? j.livekitUrl : 'wss://livekit.quick-network.vu';
    await room.connect(url, j.token);
    final lp = room.localParticipant;
    _local = lp;
    if (lp != null) {
      await lp.setMicrophoneEnabled(true);
      if (publishVideo) {
        await lp.setCameraEnabled(true);
      }
    }
    isAudio = true;
    isVideo = publishVideo;
    isScreenSharing = false;
    // Snapshot any pre-existing remotes (we may join after the peer).
    remotes
      ..clear()
      ..addEntries(room.remoteParticipants.values.map((rp) => MapEntry(rp.sid, rp)));
    notifyListeners();
  }

  // ---- public API consumed by UI + WS hookup ----

  Future<void> startCall(CallPeer p, {bool video = false}) async {
    if (lifecycle != CallLifecycle.idle) return;
    final res = await _api.startCall(peerUserId: p.id, video: video);
    if (res.join.token.isEmpty) {
      throw StateError('startCall: backend returned empty join token');
    }
    callId = res.callId;
    peer = p;
    join = res.join;
    isVideo = video;
    lifecycle = CallLifecycle.ringingOut;
    notifyListeners();
    try {
      await _connectRoom(res.join, publishVideo: video);
    } catch (e) {
      // Could not even open the room — tear down both sides.
      await _disposeRoom();
      try { await _api.endCall(res.callId); } catch (_) {/* best effort */}
      lifecycle = CallLifecycle.idle;
      callId = null;
      peer = null;
      join = null;
      _resetMediaState();
      notifyListeners();
      rethrow;
    }
  }

  /// Called when the user taps Accept on the IncomingCallDialog.
  Future<void> acceptIncoming() async {
    if (lifecycle != CallLifecycle.incoming || callId == null) return;
    _cancelIncomingTimer();
    final j = await _api.acceptCall(callId!);
    if (j.token.isEmpty) {
      throw StateError('acceptCall: backend returned empty join token');
    }
    join = j;
    lifecycle = CallLifecycle.active;
    startedAt = DateTime.now();
    notifyListeners();
    try {
      await _connectRoom(j, publishVideo: isVideo);
    } catch (e) {
      await _disposeRoom();
      try { await _api.endCall(callId!); } catch (_) {/* best effort */}
      _hardReset();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> declineIncoming() async {
    if (lifecycle != CallLifecycle.incoming || callId == null) return;
    final id = callId!;
    _cancelIncomingTimer();
    _hardReset();
    notifyListeners();
    try { await _api.declineCall(id); } catch (_) {/* best effort */}
  }

  /// Universal hangup. Works in any state except idle.
  Future<void> end() async {
    if (lifecycle == CallLifecycle.idle) return;
    final id = callId;
    _cancelIncomingTimer();
    await _disposeRoom();
    _hardReset();
    notifyListeners();
    if (id != null && id.isNotEmpty) {
      try { await _api.endCall(id); } catch (_) {/* best effort */}
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

  /// Start a screen share with system audio. Anti-echo (the web's
  /// `suppressLocalAudioPlayback` trick) doesn't have a direct equivalent in
  /// the livekit_client Dart SDK on Windows — see the gotcha below.
  Future<void> startScreenShare() async {
    final lp = _local;
    if (lp == null || isScreenSharing) return;
    try {
      // On Windows, livekit_client uses flutter-webrtc's getDisplayMedia. The
      // captureScreenAudio flag is honored by the underlying WebRTC layer; the
      // user gets a desktop-capture picker and (when sharing the entire screen)
      // a "share audio" checkbox. Sharing a single window vs the whole screen
      // is the most reliable anti-echo workaround until flutter-webrtc exposes
      // an analog of the browser's suppressLocalAudioPlayback constraint.
      // TODO(calls-anti-echo): plumb a desktop-source picker UI and a
      // virtual-cable hint when system audio is captured.
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
      // User cancelled the picker or capture failed — stay off.
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
    if (lifecycle == CallLifecycle.idle) return;
    isMinimized = true;
    notifyListeners();
  }

  void expand() {
    if (!isMinimized) return;
    isMinimized = false;
    notifyListeners();
  }

  // ---- WS handlers (called from calls_realtime.dart) ----

  /// Server fans this out to us when somebody is calling.
  void onIncomingCall({
    required String callId,
    required bool video,
    required CallPeer caller,
  }) {
    if (lifecycle != CallLifecycle.idle) return;
    this.callId = callId;
    peer = caller;
    isVideo = video;
    lifecycle = CallLifecycle.incoming;
    notifyListeners();
    _cancelIncomingTimer();
    _incomingTimer = Timer(incomingTtl, () {
      if (lifecycle == CallLifecycle.incoming && this.callId == callId) {
        // ignore: discarded_futures
        declineIncoming();
      }
    });
  }

  /// Peer accepted — promote ringingOut to active. Already in the room.
  void onCallAccepted(String acceptedCallId) {
    if (lifecycle != CallLifecycle.ringingOut) return;
    if (callId != acceptedCallId) return;
    lifecycle = CallLifecycle.active;
    startedAt = DateTime.now();
    notifyListeners();
  }

  /// Peer declined — tear down the silent Room and reset.
  void onCallDeclined(String declinedCallId) {
    if (callId != declinedCallId && declinedCallId.isNotEmpty) return;
    // ignore: discarded_futures
    end();
  }

  /// Either side hung up — drop everything.
  void onCallEnded(String endedCallId) {
    if (lifecycle == CallLifecycle.idle) return;
    if (endedCallId.isNotEmpty && callId != endedCallId) return;
    _cancelIncomingTimer();
    // ignore: discarded_futures
    _disposeRoom().then((_) {
      _hardReset();
      notifyListeners();
    });
  }

  void _hardReset() {
    lifecycle = CallLifecycle.idle;
    callId = null;
    peer = null;
    join = null;
    _resetMediaState();
  }

  @override
  void dispose() {
    _cancelIncomingTimer();
    // Fire-and-forget; we don't await in dispose().
    // ignore: discarded_futures
    _disposeRoom();
    super.dispose();
  }
}
