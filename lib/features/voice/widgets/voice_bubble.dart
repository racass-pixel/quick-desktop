// TG-style voice message bubble.
//
// Layout:  [ 48px play/pause circle ]  [ 64 waveform bars ]  [ MM:SS · speed ]
//
// Bar colour rules (mirroring quick-web's VoiceBubble.tsx):
//   * Receiver, unplayed     → all bars ember + small ember unread dot
//   * Receiver, played       → all bars ink-3/60 (grey)
//   * Sender, peer unplayed  → all bars ember (no dot — sender's own bubble)
//   * Sender, peer played    → all bars ink-3/60
// During playback, bars before the playhead are ember; after are ink-3/60.
//
// First-play tracking: a receiver's first play fires `onFirstPlay` exactly
// once per bubble instance. The actual `MarkVoicePlayed` RPC is owned by the
// messaging layer — we just call the callback and let it debounce per
// messageId on its own.

import 'package:flutter/material.dart';

import '../../../theme/theme.dart';
import '../state/voice_player.dart';

class VoicePayload {
  const VoicePayload({
    required this.fileId,
    required this.url,
    required this.durationMs,
    required this.peaks,
    required this.played,
    required this.messageId,
  });

  final String fileId;
  // Pre-built playback URL (includes ?token=...). The messaging layer is the
  // canonical place to know the session token, so we let it build the URL
  // once and hand the bubble a ready-to-play string.
  final String url;
  final int durationMs;
  final List<int> peaks;
  final bool played;
  // Server-assigned message id used by the shared player to identify which
  // bubble currently owns playback.
  final String messageId;
}

const int _kBarCount = 64;
const double _kMaxBar = 28;
const double _kMinBar = 3;

class VoiceBubble extends StatefulWidget {
  const VoiceBubble({
    super.key,
    required this.voice,
    required this.isOwn,
    required this.player,
    this.onFirstPlay,
  });

  final VoicePayload voice;
  final bool isOwn;
  final VoicePlayerNotifier player;
  // Receiver-side hook: fires the first time this bubble starts playing.
  final VoidCallback? onFirstPlay;

  @override
  State<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<VoiceBubble> {
  bool _firedFirstPlay = false;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayerChange);
  }

  @override
  void didUpdateWidget(covariant VoiceBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayerChange);
      widget.player.addListener(_onPlayerChange);
    }
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChange);
    super.dispose();
  }

  void _onPlayerChange() {
    if (!mounted) return;
    // The notifier emits on every position update; rebuild so the progress
    // overlay tracks the head. The waveform itself is cheap to redraw —
    // it's a single CustomPaint.
    setState(() {});
  }

  bool get _isCurrent => widget.player.isCurrent(widget.voice.messageId);
  bool get _isPlaying => _isCurrent && widget.player.state.isPlaying;

  int get _currentMs {
    if (!_isCurrent) return 0;
    return widget.player.state.positionMs;
  }

  int get _totalMs {
    if (_isCurrent && widget.player.state.durationMs > 0) {
      return widget.player.state.durationMs;
    }
    return widget.voice.durationMs;
  }

  double get _progress {
    final t = _totalMs;
    if (t <= 0) return 0;
    final p = _currentMs / t;
    if (p.isNaN || p < 0) return 0;
    if (p > 1) return 1;
    return p;
  }

  Future<void> _toggle() async {
    if (_isPlaying) {
      await widget.player.pause();
      return;
    }
    // First-play handoff — receiver only, once.
    if (!widget.isOwn && !widget.voice.played && !_firedFirstPlay) {
      _firedFirstPlay = true;
      try {
        widget.onFirstPlay?.call();
      } catch (_) {
        // The callback is foundation-supplied; never let a thrown error in
        // their handler block local playback.
      }
    }
    await widget.player.play(
      messageId: widget.voice.messageId,
      url: widget.voice.url,
      fallbackDurationMs: widget.voice.durationMs,
    );
  }

  Future<void> _cycleSpeed() => widget.player.cycleSpeed();

  String _fmt(int ms) {
    if (ms < 0) ms = 0;
    final total = ms ~/ 1000;
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final voice = widget.voice;
    final unread = !widget.isOwn && !voice.played;
    final speed = widget.player.state.speed;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 260),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _PlayCircle(playing: _isPlaying, onTap: _toggle),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: _kMaxBar,
                  child: CustomPaint(
                    painter: _WaveformPainter(
                      peaks: voice.peaks,
                      progress: _progress,
                      unread: unread,
                      playing: _isPlaying || _currentMs > 0,
                      isOwn: widget.isOwn,
                      played: voice.played,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      _fmt(_isPlaying || _currentMs > 0 ? _currentMs : _totalMs),
                      style: const TextStyle(
                        color: AppColors.ink3,
                        fontSize: 11,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (_isPlaying || _currentMs > 0) ...[
                      Text(
                        ' / ${_fmt(_totalMs)}',
                        style: TextStyle(
                          color: AppColors.ink3.withValues(alpha: 0.6),
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                    const Spacer(),
                    if (unread)
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: const BoxDecoration(
                          color: AppColors.ember,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _SpeedPill(speed: speed, onTap: _cycleSpeed),
        ],
      ),
    );
  }
}

class _PlayCircle extends StatelessWidget {
  const _PlayCircle({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.ember,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            playing ? Icons.pause : Icons.play_arrow,
            // ink-1 on ember reads slightly off; AppColors.bg matches the
            // web (`text-bg`).
            color: AppColors.bg,
            size: 26,
          ),
        ),
      ),
    );
  }
}

class _SpeedPill extends StatelessWidget {
  const _SpeedPill({required this.speed, required this.onTap});
  final double speed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 1x rendered without a decimal, 1.5x kept as-is, 2x without decimal. The
    // pill is a fixed-width feel via tabular figures so the cycle doesn't
    // shift the layout.
    final label = speed == speed.roundToDouble()
        ? '${speed.toInt()}x'
        : '${speed}x';
    return Align(
      alignment: Alignment.topCenter,
      child: Material(
        color: AppColors.ink3.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.ink2,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.unread,
    required this.playing,
    required this.isOwn,
    required this.played,
  });

  final List<int> peaks;
  final double progress;
  final bool unread;
  final bool playing;
  final bool isOwn;
  final bool played;

  @override
  void paint(Canvas canvas, Size size) {
    // Pad/truncate the source array to exactly _kBarCount so a malformed
    // input doesn't blow up the layout (e.g. backend sends 63 due to a
    // round-trip bug).
    final src = peaks;
    final padded = List<int>.filled(_kBarCount, 0);
    for (var i = 0; i < _kBarCount && i < src.length; i++) {
      padded[i] = src[i];
    }

    // Bar width + spacing: 2px bars on 4px stride (2px gap), centred so the
    // total drawn width fits the available size.
    const barW = 2.0;
    final stride = size.width / _kBarCount;
    final emberPaint = Paint()..color = AppColors.ember;
    final emberSoft = Paint()..color = AppColors.ember.withValues(alpha: 0.8);
    final grey = Paint()..color = AppColors.ink3.withValues(alpha: 0.6);

    for (var i = 0; i < _kBarCount; i++) {
      final v = padded[i].clamp(0, 255) / 255.0;
      final h = (v * _kMaxBar).clamp(_kMinBar, _kMaxBar).toDouble();
      final x = i * stride + (stride - barW) / 2;
      final y = (size.height - h) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barW, h),
        const Radius.circular(1),
      );

      final Paint p;
      if (unread) {
        p = emberPaint;
      } else if (playing) {
        // (i + 0.5) / N gives the bar's centre as a 0..1 progress.
        final beforeHead = (i + 0.5) / _kBarCount <= progress;
        p = beforeHead ? emberPaint : grey;
      } else {
        final ownUnplayed = isOwn && !played;
        p = ownUnplayed ? emberSoft : grey;
      }
      canvas.drawRRect(rect, p);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) {
    return old.progress != progress ||
        old.unread != unread ||
        old.playing != playing ||
        old.isOwn != isOwn ||
        old.played != played ||
        !identical(old.peaks, peaks);
  }
}
