// Single tile in the call grid: video texture if any video track is published,
// avatar fallback otherwise. The green pulsing ring is driven by the
// `isActiveSpeaker` flag (which the parent computes from the notifier's
// activeSpeakers Set).

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../theme/theme.dart';

class CallParticipantTile extends StatefulWidget {
  const CallParticipantTile({
    super.key,
    required this.displayName,
    required this.avatarColorHex,
    required this.isActiveSpeaker,
    this.videoTrack,
    this.isLocal = false,
    this.micMuted = false,
  });

  /// Camera or screen-share VideoTrack to render. Null falls back to avatar.
  final VideoTrack? videoTrack;
  final String displayName;
  final String avatarColorHex;
  final bool isActiveSpeaker;
  final bool isLocal;
  final bool micMuted;

  @override
  State<CallParticipantTile> createState() => _CallParticipantTileState();
}

class _CallParticipantTileState extends State<CallParticipantTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasVideo = widget.videoTrack != null;
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) {
        final ringWidth =
            widget.isActiveSpeaker ? (2.0 + _pulse.value * 2.0) : 0.0;
        final ringColor = const Color(0xFF22C55E)
            .withValues(alpha: widget.isActiveSpeaker ? 0.85 : 0.0);
        return Container(
          decoration: BoxDecoration(
            color: AppColors.raised,
            borderRadius: BorderRadius.circular(AppRadii.rLg),
            border: Border.all(
              color: ringColor,
              width: ringWidth,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasVideo)
                VideoTrackRenderer(
                  widget.videoTrack!,
                  fit: VideoViewFit.cover,
                  mirrorMode: widget.isLocal
                      ? VideoViewMirrorMode.mirror
                      : VideoViewMirrorMode.off,
                )
              else
                _AvatarFallback(
                  name: widget.displayName,
                  colorHex: widget.avatarColorHex,
                ),
              // Bottom-left name pill.
              Positioned(
                left: 10,
                bottom: 10,
                child: _NamePill(
                  name: widget.isLocal
                      ? '${widget.displayName} (you)'
                      : widget.displayName,
                  micMuted: widget.micMuted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({required this.name, required this.colorHex});
  final String name;
  final String colorHex;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 96,
        height: 96,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: avatarColor(colorHex, name),
          shape: BoxShape.circle,
        ),
        child: Text(
          avatarInitials(name),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 38,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _NamePill extends StatelessWidget {
  const _NamePill({required this.name, required this.micMuted});
  final String name;
  final bool micMuted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppRadii.rSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (micMuted) ...[
            const Icon(Icons.mic_off, size: 14, color: AppColors.err),
            const SizedBox(width: 6),
          ],
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
