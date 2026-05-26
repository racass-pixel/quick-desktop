// Shared voice-message player.
//
// Telegram only ever plays one voice message at a time — hitting Play on a
// second bubble pauses the first. To get the same behaviour without each
// VoiceBubble owning a private just_audio handle (which would also chew
// through native player slots on long chats), we centralise one
// AudioPlayer in this notifier and let bubbles drive it via messageId.
//
// We deliberately don't import Riverpod here even though the rest of the
// project picked it: keeping the notifier framework-agnostic means
// VoiceBubble can be embedded into any host (a future panel, a settings
// preview, etc.) by handing it a notifier instance through InheritedWidget
// or constructor. The compose layer registers a Riverpod provider over
// `VoicePlayerNotifier()` in main.dart wiring.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

class VoicePlayerState {
  const VoicePlayerState({
    this.currentMessageId,
    this.isPlaying = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.speed = 1.0,
    this.errorMessageId,
  });

  // null when nothing is loaded; the bubble keys off this to know which one
  // owns the player slot.
  final String? currentMessageId;
  final bool isPlaying;
  final int positionMs;
  final int durationMs;
  final double speed;
  // When a load/play fails this is set to the messageId that failed, so the
  // matching bubble can show an inline "Couldn't play" pill. Cleared on the
  // next successful play.
  final String? errorMessageId;

  VoicePlayerState copyWith({
    Object? currentMessageId = _sentinel,
    bool? isPlaying,
    int? positionMs,
    int? durationMs,
    double? speed,
    Object? errorMessageId = _sentinel,
  }) {
    return VoicePlayerState(
      currentMessageId: identical(currentMessageId, _sentinel)
          ? this.currentMessageId
          : currentMessageId as String?,
      isPlaying: isPlaying ?? this.isPlaying,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      speed: speed ?? this.speed,
      errorMessageId: identical(errorMessageId, _sentinel)
          ? this.errorMessageId
          : errorMessageId as String?,
    );
  }
}

const _sentinel = Object();

class VoicePlayerNotifier extends ChangeNotifier {
  VoicePlayerNotifier() : _player = AudioPlayer() {
    _stateSub = _player.playerStateStream.listen((s) {
      final newPlaying = s.playing && s.processingState != ProcessingState.completed;
      if (s.processingState == ProcessingState.completed) {
        // TG-style: rewind so a tap on the same bubble starts from zero.
        _player.seek(Duration.zero);
        _state = _state.copyWith(isPlaying: false, positionMs: 0);
        notifyListeners();
        return;
      }
      if (newPlaying != _state.isPlaying) {
        _state = _state.copyWith(isPlaying: newPlaying);
        notifyListeners();
      }
    });
    // Surface decode/network failures so the bubble can render a "Couldn't
    // play" pill. Without this just_audio errors only land on stderr and the
    // user sees a dead play button.
    _errSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace _) {
        final id = _state.currentMessageId;
        _state = _state.copyWith(
          isPlaying: false,
          errorMessageId: id,
        );
        notifyListeners();
      },
    );
    _posSub = _player.positionStream.listen((d) {
      if (_state.currentMessageId == null) return;
      _state = _state.copyWith(positionMs: d.inMilliseconds);
      notifyListeners();
    });
    _durSub = _player.durationStream.listen((d) {
      if (d == null) return;
      _state = _state.copyWith(durationMs: d.inMilliseconds);
      notifyListeners();
    });
  }

  final AudioPlayer _player;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlaybackEvent>? _errSub;

  VoicePlayerState _state = const VoicePlayerState();
  VoicePlayerState get state => _state;

  // Begin playback of [url] under [messageId]. If a different message is
  // currently loaded we swap to the new one (matching TG's one-at-a-time
  // behaviour); if the same one is loaded we just resume from where it left
  // off.
  Future<void> play({
    required String messageId,
    required String url,
    int? fallbackDurationMs,
  }) async {
    if (_state.currentMessageId != messageId) {
      _state = VoicePlayerState(
        currentMessageId: messageId,
        durationMs: fallbackDurationMs ?? 0,
        speed: _state.speed,
      );
      notifyListeners();
      try {
        // AudioSource.uri lets us pin Content-Type expectations and pass a
        // hint headers map if the backend ever serves voice without one. For
        // now plain setUrl is sufficient on Windows (Media Foundation sniffs
        // the container), but going via AudioSource also makes future header
        // tweaks (Range, etc.) a one-line change.
        await _player.setAudioSource(AudioSource.uri(Uri.parse(url)));
        // setAudioSource resets playbackRate to 1.0 — re-apply the user's
        // chosen speed.
        await _player.setSpeed(_state.speed);
      } catch (_) {
        // Surface a failed load by tagging the messageId so the bubble can
        // render an inline "Couldn't play" pill.
        _state = VoicePlayerState(
          speed: _state.speed,
          errorMessageId: messageId,
        );
        notifyListeners();
        return;
      }
    }
    try {
      await _player.play();
    } catch (_) {
      _state = _state.copyWith(
        isPlaying: false,
        errorMessageId: messageId,
      );
      notifyListeners();
    }
  }

  Future<void> pause() async {
    if (!_state.isPlaying) return;
    await _player.pause();
  }

  // Cycle 1x → 1.5x → 2x → 1x. Persists across messages so a user who likes
  // 1.5x keeps it for the rest of the session.
  Future<void> cycleSpeed() async {
    const speeds = <double>[1.0, 1.5, 2.0];
    final i = speeds.indexOf(_state.speed);
    final next = speeds[(i + 1) % speeds.length];
    _state = _state.copyWith(speed: next);
    notifyListeners();
    await _player.setSpeed(next);
  }

  // True when [messageId] is the slot owner (regardless of play/pause).
  bool isCurrent(String messageId) => _state.currentMessageId == messageId;

  @override
  Future<void> dispose() async {
    await _stateSub?.cancel();
    await _posSub?.cancel();
    await _durSub?.cancel();
    await _errSub?.cancel();
    await _player.dispose();
    super.dispose();
  }
}
