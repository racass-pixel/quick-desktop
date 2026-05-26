// Full-screen call view. Drives both 1:1 (CallNotifier) and group
// (GroupCallNotifier) — only one of the two notifiers will have an active
// session at a time; we pick whichever is non-idle.
//
// Layout:
//   [   participant grid (Expanded)   ]
//   [   control bar (mic / cam / share / hangup / minimize)  ]
//
// Telegram-quality dark styling: panel surfaces, ember accent for primary,
// red for hangup, ink-1 text. No emoji.

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../theme/theme.dart';
import '../state/call_state.dart';
import '../state/group_call_state.dart';
import '../widgets/participant_tile.dart';

class CallScreen extends StatelessWidget {
  const CallScreen({
    super.key,
    required this.call,
    required this.group,
  });

  final CallNotifier call;
  final GroupCallNotifier group;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([call, group]),
      builder: (_, _) {
        final inGroup = group.lifecycle == GroupCallLifecycle.active;
        final inDirect = call.lifecycle == CallLifecycle.ringingOut ||
            call.lifecycle == CallLifecycle.active;
        if (!inGroup && !inDirect) {
          // Caller-side guard: don't render an empty stage.
          return const SizedBox.shrink();
        }
        final tiles = <_TileData>[];
        if (inGroup) {
          tiles.addAll(_buildGroupTiles(group));
        } else {
          tiles.addAll(_buildDirectTiles(call));
        }
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Column(
              children: [
                _Header(
                  title: inGroup
                      ? 'Voice chat'
                      : (call.peer?.displayName ?? 'Call'),
                  subtitle: inGroup
                      ? '${tiles.length} participants'
                      : _statusLabel(call.lifecycle),
                  onMinimize: () =>
                      inGroup ? group.minimize() : call.minimize(),
                ),
                Expanded(child: _Grid(tiles: tiles)),
                _Controls(
                  micOn: inGroup ? group.isAudio : call.isAudio,
                  cameraOn: inGroup ? group.isVideo : call.isVideo,
                  screenOn: inGroup ? group.isScreenSharing : call.isScreenSharing,
                  onToggleMic: () =>
                      inGroup ? group.toggleMic() : call.toggleMic(),
                  onToggleCamera: () =>
                      inGroup ? group.toggleCamera() : call.toggleCamera(),
                  onToggleScreen: () => inGroup
                      ? (group.isScreenSharing
                          ? group.stopScreenShare()
                          : group.startScreenShare())
                      : (call.isScreenSharing
                          ? call.stopScreenShare()
                          : call.startScreenShare()),
                  onHangup: () =>
                      inGroup ? group.leaveGroupCall() : call.end(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _statusLabel(CallLifecycle s) {
    switch (s) {
      case CallLifecycle.ringingOut:
        return 'Calling...';
      case CallLifecycle.active:
        return 'Connected';
      case CallLifecycle.incoming:
      case CallLifecycle.idle:
        return '';
    }
  }
}

class _TileData {
  _TileData({
    required this.key,
    required this.displayName,
    required this.colorHex,
    required this.isActiveSpeaker,
    required this.isLocal,
    required this.micMuted,
    this.videoTrack,
  });
  final String key;
  final String displayName;
  final String colorHex;
  final bool isActiveSpeaker;
  final bool isLocal;
  final bool micMuted;
  final VideoTrack? videoTrack;
}

List<_TileData> _buildDirectTiles(CallNotifier n) {
  final tiles = <_TileData>[];
  final lp = n.local;
  if (lp != null) {
    VideoTrack? localVid;
    for (final pub in lp.videoTrackPublications) {
      final t = pub.track;
      if (t is VideoTrack) {
        // Prefer camera over screen for the local face tile.
        localVid = t;
        if (pub.source == TrackSource.camera) break;
      }
    }
    tiles.add(_TileData(
      key: 'local',
      displayName: 'You',
      colorHex: '#EA580C',
      isActiveSpeaker: n.activeSpeakers.contains(lp.identity),
      isLocal: true,
      micMuted: !n.isAudio,
      videoTrack: localVid,
    ));
  }
  for (final rp in n.remotes.values) {
    VideoTrack? rt;
    for (final pub in rp.videoTrackPublications) {
      final t = pub.track;
      if (t is VideoTrack) {
        rt = t;
        if (pub.source == TrackSource.camera) break;
      }
    }
    tiles.add(_TileData(
      key: 'remote-${rp.sid}',
      displayName: n.peer?.displayName ??
          (rp.name.isNotEmpty ? rp.name : rp.identity),
      colorHex: n.peer?.avatarColor ?? '#6F7180',
      isActiveSpeaker: n.activeSpeakers.contains(rp.identity),
      isLocal: false,
      micMuted: !rp.isMicrophoneEnabled(),
      videoTrack: rt,
    ));
  }
  return tiles;
}

List<_TileData> _buildGroupTiles(GroupCallNotifier n) {
  final tiles = <_TileData>[];
  final lp = n.local;
  if (lp != null) {
    VideoTrack? localVid;
    for (final pub in lp.videoTrackPublications) {
      final t = pub.track;
      if (t is VideoTrack) {
        localVid = t;
        if (pub.source == TrackSource.camera) break;
      }
    }
    tiles.add(_TileData(
      key: 'local',
      displayName: 'You',
      colorHex: '#EA580C',
      isActiveSpeaker: n.activeSpeakers.contains(lp.identity),
      isLocal: true,
      micMuted: !n.isAudio,
      videoTrack: localVid,
    ));
  }
  for (final rp in n.remotes.values) {
    VideoTrack? rt;
    for (final pub in rp.videoTrackPublications) {
      final t = pub.track;
      if (t is VideoTrack) {
        rt = t;
        if (pub.source == TrackSource.camera) break;
      }
    }
    tiles.add(_TileData(
      key: 'remote-${rp.sid}',
      displayName: rp.name.isNotEmpty ? rp.name : rp.identity,
      colorHex: '#6F7180',
      isActiveSpeaker: n.activeSpeakers.contains(rp.identity),
      isLocal: false,
      micMuted: !rp.isMicrophoneEnabled(),
      videoTrack: rt,
    ));
  }
  return tiles;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onMinimize,
  });
  final String title;
  final String subtitle;
  final VoidCallback onMinimize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      color: AppColors.ink1,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    )),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle,
                        style: const TextStyle(
                          color: AppColors.ink2,
                          fontSize: 12,
                        )),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: onMinimize,
            icon: const Icon(Icons.expand_more, color: AppColors.ink2),
            tooltip: 'Minimize',
          ),
        ],
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.tiles});
  final List<_TileData> tiles;

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) {
      return const Center(
        child: Text('Waiting for participants...',
            style: TextStyle(color: AppColors.ink2)),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      final cols = _columnsFor(tiles.length, c.maxWidth);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: GridView.builder(
          itemCount: tiles.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 16 / 10,
          ),
          itemBuilder: (_, i) {
            final t = tiles[i];
            return CallParticipantTile(
              key: ValueKey(t.key),
              displayName: t.displayName,
              avatarColorHex: t.colorHex,
              isActiveSpeaker: t.isActiveSpeaker,
              videoTrack: t.videoTrack,
              isLocal: t.isLocal,
              micMuted: t.micMuted,
            );
          },
        ),
      );
    });
  }

  int _columnsFor(int n, double w) {
    if (n <= 1) return 1;
    if (n <= 2) return 2;
    if (n <= 4) return 2;
    if (n <= 9) return 3;
    return w >= 1100 ? 4 : 3;
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.micOn,
    required this.cameraOn,
    required this.screenOn,
    required this.onToggleMic,
    required this.onToggleCamera,
    required this.onToggleScreen,
    required this.onHangup,
  });

  final bool micOn;
  final bool cameraOn;
  final bool screenOn;
  final VoidCallback onToggleMic;
  final VoidCallback onToggleCamera;
  final VoidCallback onToggleScreen;
  final VoidCallback onHangup;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(
        color: AppColors.panel,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _CtrlButton(
            icon: micOn ? Icons.mic : Icons.mic_off,
            active: micOn,
            label: micOn ? 'Mute' : 'Unmute',
            onTap: onToggleMic,
          ),
          const SizedBox(width: 12),
          _CtrlButton(
            icon: cameraOn ? Icons.videocam : Icons.videocam_off,
            active: cameraOn,
            label: cameraOn ? 'Stop video' : 'Start video',
            onTap: onToggleCamera,
          ),
          const SizedBox(width: 12),
          _CtrlButton(
            icon: screenOn ? Icons.stop_screen_share : Icons.screen_share,
            active: screenOn,
            label: screenOn ? 'Stop sharing' : 'Share screen',
            onTap: onToggleScreen,
          ),
          const SizedBox(width: 24),
          _CtrlButton(
            icon: Icons.call_end,
            active: true,
            danger: true,
            label: 'Hang up',
            onTap: onHangup,
          ),
        ],
      ),
    );
  }
}

class _CtrlButton extends StatelessWidget {
  const _CtrlButton({
    required this.icon,
    required this.active,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (danger) {
      bg = AppColors.err;
      fg = Colors.white;
    } else if (active) {
      bg = AppColors.raised;
      fg = AppColors.ink1;
    } else {
      bg = AppColors.err.withValues(alpha: 0.18);
      fg = AppColors.err;
    }
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.line),
          ),
          child: Icon(icon, color: fg, size: 24),
        ),
      ),
    );
  }
}
