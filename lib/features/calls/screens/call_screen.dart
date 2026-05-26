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
import '../widgets/screen_share_picker.dart';

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
        final screenShareCfg = inGroup
            ? group.screenShareConfig
            : call.screenShareConfig;
        final isScreenOn = inGroup
            ? group.isScreenSharing
            : call.isScreenSharing;
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
                Expanded(
                  child: Stack(
                    children: [
                      _Grid(tiles: tiles),
                      if (isScreenOn)
                        Positioned(
                          top: 12,
                          right: 20,
                          child: _ScreenShareBadge(
                            title: screenShareCfg?.sourceTitle ?? 'Screen',
                            onStop: () => inGroup
                                ? group.stopScreenShare()
                                : call.stopScreenShare(),
                          ),
                        ),
                    ],
                  ),
                ),
                _Controls(
                  micOn: inGroup ? group.isAudio : call.isAudio,
                  cameraOn: inGroup ? group.isVideo : call.isVideo,
                  screenOn: isScreenOn,
                  onToggleMic: () =>
                      inGroup ? group.toggleMic() : call.toggleMic(),
                  onToggleCamera: () =>
                      inGroup ? group.toggleCamera() : call.toggleCamera(),
                  onToggleScreen: () async {
                    if (isScreenOn) {
                      if (inGroup) {
                        await group.stopScreenShare();
                      } else {
                        await call.stopScreenShare();
                      }
                      return;
                    }
                    final cfg = await showScreenSharePicker(context);
                    if (cfg == null) return;
                    if (inGroup) {
                      await group.startScreenShare(cfg);
                    } else {
                      await call.startScreenShare(cfg);
                    }
                  },
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
    this.isScreenShare = false,
  });
  final String key;
  final String displayName;
  final String colorHex;
  final bool isActiveSpeaker;
  final bool isLocal;
  final bool micMuted;
  final VideoTrack? videoTrack;

  /// True for tiles that render a screen-share track instead of a camera/avatar.
  /// Promoted to the front of the grid so they get the biggest cell.
  final bool isScreenShare;
}

/// Split a participant's published video tracks into a `(camera, screen)`
/// pair. Either may be null. Screen-share tracks are surfaced as their own
/// tile (Discord-style) so the shared screen gets a prominent cell.
({VideoTrack? camera, VideoTrack? screen}) _splitTracks(
    Iterable<TrackPublication> pubs) {
  VideoTrack? camera;
  VideoTrack? screen;
  for (final pub in pubs) {
    final t = pub.track;
    if (t is! VideoTrack) continue;
    switch (pub.source) {
      case TrackSource.screenShareVideo:
        screen = t;
        break;
      case TrackSource.camera:
        camera = t;
        break;
      default:
        camera ??= t;
    }
  }
  return (camera: camera, screen: screen);
}

List<_TileData> _buildDirectTiles(CallNotifier n) {
  final screenTiles = <_TileData>[];
  final cameraTiles = <_TileData>[];
  final lp = n.local;
  if (lp != null) {
    final split = _splitTracks(lp.videoTrackPublications);
    if (split.screen != null) {
      screenTiles.add(_TileData(
        key: 'local-screen',
        displayName: n.screenShareConfig?.sourceTitle.isNotEmpty == true
            ? 'You: ${n.screenShareConfig!.sourceTitle}'
            : 'Your screen',
        colorHex: '#EA580C',
        isActiveSpeaker: false,
        isLocal: true,
        micMuted: !n.isAudio,
        videoTrack: split.screen,
        isScreenShare: true,
      ));
    }
    cameraTiles.add(_TileData(
      key: 'local',
      displayName: 'You',
      colorHex: '#EA580C',
      isActiveSpeaker: n.activeSpeakers.contains(lp.identity),
      isLocal: true,
      micMuted: !n.isAudio,
      videoTrack: split.camera,
    ));
  }
  for (final rp in n.remotes.values) {
    final split = _splitTracks(rp.videoTrackPublications);
    if (split.screen != null) {
      screenTiles.add(_TileData(
        key: 'remote-screen-${rp.sid}',
        displayName: '${n.peer?.displayName ?? rp.name}: screen',
        colorHex: n.peer?.avatarColor ?? '#6F7180',
        isActiveSpeaker: false,
        isLocal: false,
        micMuted: !rp.isMicrophoneEnabled(),
        videoTrack: split.screen,
        isScreenShare: true,
      ));
    }
    cameraTiles.add(_TileData(
      key: 'remote-${rp.sid}',
      displayName: n.peer?.displayName ??
          (rp.name.isNotEmpty ? rp.name : rp.identity),
      colorHex: n.peer?.avatarColor ?? '#6F7180',
      isActiveSpeaker: n.activeSpeakers.contains(rp.identity),
      isLocal: false,
      micMuted: !rp.isMicrophoneEnabled(),
      videoTrack: split.camera,
    ));
  }
  return [...screenTiles, ...cameraTiles];
}

List<_TileData> _buildGroupTiles(GroupCallNotifier n) {
  final screenTiles = <_TileData>[];
  final cameraTiles = <_TileData>[];
  final lp = n.local;
  if (lp != null) {
    final split = _splitTracks(lp.videoTrackPublications);
    if (split.screen != null) {
      screenTiles.add(_TileData(
        key: 'local-screen',
        displayName: n.screenShareConfig?.sourceTitle.isNotEmpty == true
            ? 'You: ${n.screenShareConfig!.sourceTitle}'
            : 'Your screen',
        colorHex: '#EA580C',
        isActiveSpeaker: false,
        isLocal: true,
        micMuted: !n.isAudio,
        videoTrack: split.screen,
        isScreenShare: true,
      ));
    }
    cameraTiles.add(_TileData(
      key: 'local',
      displayName: 'You',
      colorHex: '#EA580C',
      isActiveSpeaker: n.activeSpeakers.contains(lp.identity),
      isLocal: true,
      micMuted: !n.isAudio,
      videoTrack: split.camera,
    ));
  }
  for (final rp in n.remotes.values) {
    final split = _splitTracks(rp.videoTrackPublications);
    if (split.screen != null) {
      screenTiles.add(_TileData(
        key: 'remote-screen-${rp.sid}',
        displayName:
            '${rp.name.isNotEmpty ? rp.name : rp.identity}: screen',
        colorHex: '#6F7180',
        isActiveSpeaker: false,
        isLocal: false,
        micMuted: !rp.isMicrophoneEnabled(),
        videoTrack: split.screen,
        isScreenShare: true,
      ));
    }
    cameraTiles.add(_TileData(
      key: 'remote-${rp.sid}',
      displayName: rp.name.isNotEmpty ? rp.name : rp.identity,
      colorHex: '#6F7180',
      isActiveSpeaker: n.activeSpeakers.contains(rp.identity),
      isLocal: false,
      micMuted: !rp.isMicrophoneEnabled(),
      videoTrack: split.camera,
    ));
  }
  return [...screenTiles, ...cameraTiles];
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
    final screens = tiles.where((t) => t.isScreenShare).toList();
    final people = tiles.where((t) => !t.isScreenShare).toList();

    // Discord-style: when a screen is shared, devote the top region to the
    // shared screens and reduce the camera/avatar gallery to a strip below.
    if (screens.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: LayoutBuilder(builder: (context, c) {
          final screenCols = screens.length == 1 ? 1 : 2;
          return Column(
            children: [
              Expanded(
                flex: 7,
                child: GridView.builder(
                  itemCount: screens.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: screenCols,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 16 / 9,
                  ),
                  itemBuilder: (_, i) {
                    final t = screens[i];
                    return CallParticipantTile(
                      key: ValueKey(t.key),
                      displayName: t.displayName,
                      avatarColorHex: t.colorHex,
                      isActiveSpeaker: t.isActiveSpeaker,
                      videoTrack: t.videoTrack,
                      isLocal: t.isLocal,
                      micMuted: t.micMuted,
                      isScreenShare: t.isScreenShare,
                    );
                  },
                ),
              ),
              if (people.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 110,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: people.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (_, i) {
                      final t = people[i];
                      return AspectRatio(
                        aspectRatio: 16 / 10,
                        child: CallParticipantTile(
                          key: ValueKey(t.key),
                          displayName: t.displayName,
                          avatarColorHex: t.colorHex,
                          isActiveSpeaker: t.isActiveSpeaker,
                          videoTrack: t.videoTrack,
                          isLocal: t.isLocal,
                          micMuted: t.micMuted,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          );
        }),
      );
    }

    return LayoutBuilder(builder: (context, c) {
      final cols = _columnsFor(people.length, c.maxWidth);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: GridView.builder(
          itemCount: people.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 16 / 10,
          ),
          itemBuilder: (_, i) {
            final t = people[i];
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
            label: screenOn ? 'Sharing' : 'Share screen',
            highlighted: screenOn,
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
    this.highlighted = false,
  });
  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  /// When true, paint the button as a primary "live" affordance — ember-filled
  /// with a stronger glow. Used for the screen-share button while sharing so
  /// it stands out from the muted/unmuted variants.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Color border;
    List<BoxShadow>? shadow;
    if (danger) {
      bg = AppColors.err;
      fg = Colors.white;
      border = AppColors.err;
    } else if (highlighted) {
      bg = AppColors.ember;
      fg = Colors.white;
      border = AppColors.emberSoft;
      shadow = [
        BoxShadow(
          color: AppColors.ember.withValues(alpha: 0.35),
          blurRadius: 16,
          spreadRadius: 1,
        ),
      ];
    } else if (active) {
      bg = AppColors.raised;
      fg = AppColors.ink1;
      border = AppColors.line;
    } else {
      bg = AppColors.err.withValues(alpha: 0.18);
      fg = AppColors.err;
      border = AppColors.line;
    }
    // Material wraps the InkWell with a circle shape so hover/focus highlights
    // are clipped to the button. Without this, the InkWell hover paints onto
    // the nearest Material ancestor (the Scaffold), producing a grey rectangle
    // that fills the call stage.
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: border),
              boxShadow: shadow,
            ),
            child: Icon(icon, color: fg, size: 24),
          ),
        ),
      ),
    );
  }
}

/// Floating overlay in the top-right of the call stage announcing that screen
/// sharing is live, with a quick stop affordance. Mirrors Zoom/Discord's
/// "you are sharing" chip.
class _ScreenShareBadge extends StatelessWidget {
  const _ScreenShareBadge({required this.title, required this.onStop});
  final String title;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: AppColors.panel,
          borderRadius: BorderRadius.circular(AppRadii.rMd),
          border: Border.all(
            color: AppColors.ember.withValues(alpha: 0.55),
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.ember.withValues(alpha: 0.18),
              blurRadius: 18,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppColors.ember,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Sharing',
              style: TextStyle(
                color: AppColors.ink1,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.ink2,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onStop,
                child: Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.err.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.stop_rounded,
                      size: 18, color: AppColors.err),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
