// Hold-to-record microphone button for the composer's right edge.
//
// The composer (foundation) decides when to render this — it lives only when
// the text input is empty. While idle the button shows a mic icon; while
// recording we expand into a "0:01 · slide left to cancel" bar and morph the
// mic into a red stop square. Releasing the press stops the recorder, drops
// anything < 800ms (TG-style), uploads the blob, then calls
// onLocalVoiceMessage so the messaging layer can insert an optimistic bubble.
//
// The actual SendVoiceMessage RPC fires here too, but the optimistic
// callback is what makes the bubble appear immediately — the RPC's returned
// Message stub is forwarded via onServerMessage so the messaging layer can
// replace the optimistic stub with the real row.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/theme.dart';
import '../api/voice_api.dart';
import '../state/voice_recorder.dart';
import '../widgets/voice_bubble.dart' show VoicePayload;

const int _kMinVoiceMs = 800;
const double _kCancelSwipePx = 80;

// Mirror of api/dto.dart's Message — kept narrow so the composer can wire
// this without importing the full DTO surface (foundation may move the
// Message type around).
class VoiceSendResult {
  const VoiceSendResult({
    required this.payload,
    required this.serverMessageId,
    required this.serverCreatedAt,
  });
  final VoicePayload payload;
  final String serverMessageId;
  final DateTime serverCreatedAt;
}

typedef OnLocalVoiceMessage = void Function(VoicePayload payload);
typedef OnVoiceMessageSent = void Function(VoiceSendResult result);
typedef OnVoiceError = void Function(String message);

class VoiceRecorderButton extends StatefulWidget {
  const VoiceRecorderButton({
    super.key,
    required this.api,
    required this.conversationId,
    required this.token,
    this.onLocalVoiceMessage,
    this.onSent,
    this.onError,
    this.enabled = true,
  });

  final VoiceApi api;
  final String conversationId;
  // Used to mint the playback URL we hand back in the optimistic payload so
  // the receiver UI can stream while the message is still being persisted.
  final String token;
  final OnLocalVoiceMessage? onLocalVoiceMessage;
  final OnVoiceMessageSent? onSent;
  final OnVoiceError? onError;
  final bool enabled;

  @override
  State<VoiceRecorderButton> createState() => _VoiceRecorderButtonState();
}

enum _Phase { idle, recording, uploading }

class _VoiceRecorderButtonState extends State<VoiceRecorderButton> {
  VoiceRecorder? _recorder;
  StreamSubscription<VoiceRecorderTick>? _tickSub;
  _Phase _phase = _Phase.idle;
  int _elapsedMs = 0;
  double _level = 0;
  // Pointer-tracking refs — kept off setState so move events don't churn.
  Offset? _pressOrigin;
  double _swipeDx = 0;
  bool _cancelOnRelease = false;

  @override
  void dispose() {
    _tickSub?.cancel();
    _recorder?.dispose();
    super.dispose();
  }

  bool get _isRecordingPhase => _phase == _Phase.recording;

  Future<void> _onLongPressStart(LongPressStartDetails details) async {
    if (!widget.enabled || _phase != _Phase.idle) return;
    _pressOrigin = details.globalPosition;
    _swipeDx = 0;
    _cancelOnRelease = false;
    final recorder = VoiceRecorder();
    _recorder = recorder;
    try {
      await recorder.start();
    } on VoicePermissionDeniedException {
      widget.onError?.call('Microphone access denied');
      _recorder = null;
      return;
    } catch (e) {
      widget.onError?.call('Could not start recording');
      _recorder = null;
      return;
    }
    // The user might have already released before getUserMedia resolved.
    if (_pressOrigin == null) {
      await recorder.cancel();
      _recorder = null;
      return;
    }
    if (!mounted) {
      await recorder.cancel();
      return;
    }
    _tickSub = recorder.ticks.listen((t) {
      if (!mounted) return;
      setState(() {
        _elapsedMs = t.elapsedMs;
        _level = t.level;
      });
    });
    HapticFeedback.selectionClick();
    setState(() {
      _phase = _Phase.recording;
    });
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails d) {
    if (!_isRecordingPhase || _pressOrigin == null) return;
    final dx = d.globalPosition.dx - _pressOrigin!.dx;
    // Pin to (-CANCEL*1.5, 0] so the visual indicator can over-travel a bit.
    final clamped = dx.clamp(-_kCancelSwipePx * 1.5, 0).toDouble();
    if (clamped != _swipeDx) {
      setState(() {
        _swipeDx = clamped;
      });
    }
  }

  Future<void> _onLongPressEnd(LongPressEndDetails details) async {
    final cancelled = _swipeDx <= -_kCancelSwipePx || _cancelOnRelease;
    await _finish(cancelled: cancelled);
  }

  Future<void> _finish({required bool cancelled}) async {
    final recorder = _recorder;
    _pressOrigin = null;
    if (recorder == null) {
      setState(() => _phase = _Phase.idle);
      return;
    }
    if (cancelled) {
      await _tickSub?.cancel();
      _tickSub = null;
      await recorder.cancel();
      _recorder = null;
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _elapsedMs = 0;
        _level = 0;
        _swipeDx = 0;
      });
      return;
    }
    setState(() => _phase = _Phase.uploading);
    try {
      await _tickSub?.cancel();
      _tickSub = null;
      final result = await recorder.stop();
      if (result.durationMs < _kMinVoiceMs) {
        // TG-style: silently drop the recording. Delete the bytes too so we
        // don't leak orphans in the temp directory.
        try {
          if (await result.file.exists()) await result.file.delete();
        } catch (_) {
          // ignore
        }
        if (!mounted) return;
        setState(() {
          _phase = _Phase.idle;
          _elapsedMs = 0;
          _level = 0;
          _swipeDx = 0;
        });
        return;
      }
      final fileId = await widget.api.uploadVoice(
        result.file,
        result.durationMs,
        result.peaks,
      );
      // Optimistic bubble — fire the local callback before the RPC ack so
      // the message appears in the thread instantly.
      final url = widget.api.buildPlaybackUrl(fileId, widget.token);
      final optimisticPayload = VoicePayload(
        fileId: fileId,
        url: url,
        durationMs: result.durationMs,
        peaks: result.peaks,
        played: false,
        // Temp id — the real message id comes back from sendVoiceMessage.
        // The messaging layer correlates by fileId or via its own tempId
        // bookkeeping when it gets the server-stamped Message.
        messageId: 'tmp:$fileId',
      );
      widget.onLocalVoiceMessage?.call(optimisticPayload);
      final msg = await widget.api.sendVoiceMessage(
        widget.conversationId,
        fileId,
      );
      widget.onSent?.call(VoiceSendResult(
        payload: VoicePayload(
          fileId: fileId,
          url: url,
          durationMs: result.durationMs,
          peaks: result.peaks,
          played: false,
          messageId: msg.id.isNotEmpty ? msg.id : optimisticPayload.messageId,
        ),
        serverMessageId: msg.id,
        serverCreatedAt: msg.createdAt,
      ));
      // Best-effort cleanup of the local file once the bytes are in the
      // backend. If the file is still being uploaded by a flaky network we
      // leave it; OS temp cleanup will reap eventually.
      try {
        if (await result.file.exists()) await result.file.delete();
      } catch (_) {
        // ignore
      }
    } on VoiceUploadException catch (e) {
      widget.onError?.call('Voice upload failed (${e.httpStatus})');
    } catch (_) {
      widget.onError?.call('Voice message failed to send');
    } finally {
      _recorder = null;
      if (mounted) {
        setState(() {
          _phase = _Phase.idle;
          _elapsedMs = 0;
          _level = 0;
          _swipeDx = 0;
        });
      }
    }
  }

  String _fmtTimer(int ms) {
    if (ms < 0) ms = 0;
    final total = ms ~/ 1000;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // The mic button itself stays at a fixed 40x40 — the composer slot
    // assumes that. During recording, we overlay an absolutely positioned
    // recording bar above the composer; here we just return the button and
    // let _RecordingOverlay render via an Overlay entry off the button's
    // RenderBox. For MVP we render the bar inline as a Row when recording —
    // foundation can swap to a true overlay if it wants the bar to span the
    // full composer width.
    if (_phase == _Phase.uploading) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.ember,
            ),
          ),
        ),
      );
    }

    final mic = GestureDetector(
      onLongPressStart: widget.enabled ? _onLongPressStart : null,
      onLongPressMoveUpdate: _onLongPressMoveUpdate,
      onLongPressEnd: _onLongPressEnd,
      onLongPressCancel: () {
        if (_isRecordingPhase) {
          _finish(cancelled: true);
        }
      },
      onTap: () {
        // A bare tap (no hold) — surface a "Hold to record" hint so the
        // user discovers the gesture.
        if (widget.enabled && _phase == _Phase.idle) {
          widget.onError?.call('Hold to record');
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: _isRecordingPhase ? 48 : 40,
        height: _isRecordingPhase ? 48 : 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isRecordingPhase
              ? AppColors.err
              : Colors.transparent,
        ),
        child: Icon(
          _isRecordingPhase ? Icons.stop : Icons.mic,
          color: _isRecordingPhase ? Colors.white : AppColors.ink2,
          size: _isRecordingPhase ? 22 + (_level * 6) : 22,
        ),
      ),
    );

    if (!_isRecordingPhase) {
      return mic;
    }

    // While recording, show timer + slide-to-cancel hint to the left of the
    // mic. The composer will typically grant us the full width when text is
    // empty; if not, the hint clips gracefully.
    final cancelProgress = (-_swipeDx / _kCancelSwipePx).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Pulse dot
        Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.err.withValues(alpha: 0.6 + _level * 0.4),
          ),
        ),
        Text(
          _fmtTimer(_elapsedMs),
          style: const TextStyle(
            color: AppColors.ink1,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 16),
        Opacity(
          opacity: (1 - cancelProgress).clamp(0.3, 1.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chevron_left, color: AppColors.ink3, size: 16),
              const SizedBox(width: 2),
              Text(
                'Slide to cancel',
                style: TextStyle(
                  color: AppColors.ink3.withValues(alpha: 0.9),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Transform.translate(
          offset: Offset(_swipeDx, 0),
          child: mic,
        ),
      ],
    );
  }
}

// Re-export the File type so foundation code that wires this button doesn't
// need a dart:io import just to read it back.
typedef VoiceFile = File;
