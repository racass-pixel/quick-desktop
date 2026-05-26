// Source picker for screen sharing.
//
// Discord/Zoom-style modal that lists available capture sources (entire
// monitors and individual windows) with live thumbnails, lets the user pick
// a quality preset and toggle system-audio capture, and returns a
// [ScreenShareConfig] describing the choice.
//
// On Windows / macOS / Linux, livekit_client's screen capture is backed by
// flutter_webrtc's `desktopCapturer.getSources`. We render our own UI rather
// than calling into livekit's built-in `ScreenSelectDialog` so the picker
// matches the rest of the call UI.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
// flutter_webrtc is pulled in transitively by livekit_client; we reach into
// it directly for the desktop capturer sources API rather than adding a new
// top-level dependency.
// ignore: depend_on_referenced_packages
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';

import '../../../theme/theme.dart';

/// Result of the picker. Consumed by `CallNotifier.startScreenShare` /
/// `GroupCallNotifier.startScreenShare`.
class ScreenShareConfig {
  const ScreenShareConfig({
    required this.sourceId,
    required this.sourceTitle,
    required this.isWindow,
    required this.captureAudio,
    required this.preset,
  });

  final String sourceId;
  final String sourceTitle;
  final bool isWindow;
  final bool captureAudio;
  final QualityPreset preset;

  int get width => preset.width;
  int get height => preset.height;
  int get fps => preset.fps;

  /// Map our preset onto a LiveKit `VideoParameters` entry. We deliberately
  /// pick the highest-fidelity preset closest to the requested config rather
  /// than constructing one ad-hoc, so the encoder gets sensible defaults.
  VideoParameters get videoParameters {
    switch (preset) {
      case QualityPreset.high1080p30:
        return VideoParametersPresets.screenShareH1080FPS30;
      case QualityPreset.top1440p60:
        return const VideoParameters(
          description: 'screen_1440_60',
          dimensions: VideoDimensions(2560, 1440),
          encoding: VideoEncoding(
            maxBitrate: 5000 * 1000,
            maxFramerate: 60,
          ),
        );
      case QualityPreset.max4k60:
        return const VideoParameters(
          description: 'screen_2160_60',
          dimensions: VideoDimensions(3840, 2160),
          encoding: VideoEncoding(
            maxBitrate: 12000 * 1000,
            maxFramerate: 60,
          ),
        );
    }
  }
}

enum QualityPreset { high1080p30, top1440p60, max4k60 }

extension QualityPresetX on QualityPreset {
  String get label {
    switch (this) {
      case QualityPreset.high1080p30:
        return 'High';
      case QualityPreset.top1440p60:
        return 'Top';
      case QualityPreset.max4k60:
        return 'Maximum';
    }
  }

  String get detail {
    switch (this) {
      case QualityPreset.high1080p30:
        return '1080p, 30 fps';
      case QualityPreset.top1440p60:
        return '1440p, 60 fps';
      case QualityPreset.max4k60:
        return '4K, 60 fps';
    }
  }

  int get width => switch (this) {
        QualityPreset.high1080p30 => 1920,
        QualityPreset.top1440p60 => 2560,
        QualityPreset.max4k60 => 3840,
      };

  int get height => switch (this) {
        QualityPreset.high1080p30 => 1080,
        QualityPreset.top1440p60 => 1440,
        QualityPreset.max4k60 => 2160,
      };

  int get fps => switch (this) {
        QualityPreset.high1080p30 => 30,
        QualityPreset.top1440p60 => 60,
        QualityPreset.max4k60 => 60,
      };
}

/// Show the picker. Returns a [ScreenShareConfig] when the user confirms a
/// source, or `null` if they cancel.
Future<ScreenShareConfig?> showScreenSharePicker(BuildContext context) {
  return showDialog<ScreenShareConfig?>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    barrierDismissible: true,
    builder: (_) => const _ScreenSharePickerDialog(),
  );
}

class _ScreenSharePickerDialog extends StatefulWidget {
  const _ScreenSharePickerDialog();

  @override
  State<_ScreenSharePickerDialog> createState() =>
      _ScreenSharePickerDialogState();
}

class _ScreenSharePickerDialogState extends State<_ScreenSharePickerDialog> {
  final Map<String, rtc.DesktopCapturerSource> _screens = {};
  final Map<String, rtc.DesktopCapturerSource> _windows = {};
  final List<StreamSubscription<dynamic>> _subs = [];

  rtc.DesktopCapturerSource? _selected;
  bool _captureAudio = true;
  QualityPreset _preset = QualityPreset.high1080p30;
  bool _loading = true;
  Timer? _refresh;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _subs.add(rtc.desktopCapturer.onAdded.stream.listen((s) {
      if (!mounted) return;
      setState(() => _placeSource(s));
    }));
    _subs.add(rtc.desktopCapturer.onRemoved.stream.listen((s) {
      if (!mounted) return;
      setState(() {
        _screens.remove(s.id);
        _windows.remove(s.id);
        if (_selected?.id == s.id) _selected = null;
      });
    }));
    _subs.add(rtc.desktopCapturer.onThumbnailChanged.stream.listen((_) {
      if (!mounted) return;
      setState(() {});
    }));
    // Initial load + periodic refresh — flutter_webrtc walks the OS only
    // when asked, so we poll every few seconds to pick up new windows.
    unawaited(_loadSources());
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        await rtc.desktopCapturer.updateSources(
          types: [rtc.SourceType.Screen, rtc.SourceType.Window],
        );
      } catch (_) {/* swallow — picker stays usable */}
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  void _placeSource(rtc.DesktopCapturerSource s) {
    if (s.type == rtc.SourceType.Screen) {
      _screens[s.id] = s;
    } else {
      _windows[s.id] = s;
    }
  }

  Future<void> _loadSources() async {
    try {
      final list = await rtc.desktopCapturer.getSources(
        types: [rtc.SourceType.Screen, rtc.SourceType.Window],
      );
      if (!mounted) return;
      setState(() {
        _screens.clear();
        _windows.clear();
        for (final s in list) {
          _placeSource(s);
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _onPick(rtc.DesktopCapturerSource s) {
    setState(() {
      _selected = s;
      // Sharing a single window almost never captures system audio on
      // Windows; flip the default off so users aren't surprised.
      if (s.type == rtc.SourceType.Window) {
        _captureAudio = false;
      }
    });
  }

  void _confirm() {
    final s = _selected;
    if (s == null) return;
    Navigator.of(context).pop(ScreenShareConfig(
      sourceId: s.id,
      sourceTitle: s.name.isNotEmpty
          ? s.name
          : (s.type == rtc.SourceType.Screen ? 'Display' : 'Window'),
      isWindow: s.type == rtc.SourceType.Window,
      captureAudio: _captureAudio &&
          // Cannot guarantee window audio capture; only allow on full screen.
          s.type == rtc.SourceType.Screen,
      preset: _preset,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width.clamp(720.0, 1080.0).toDouble();
    final h = (size.height * 0.82).clamp(560.0, 800.0).toDouble();
    final canShare = _selected != null;
    final fullScreenSelected =
        _selected?.type == rtc.SourceType.Screen;

    return Center(
      child: Material(
        color: AppColors.panel,
        elevation: 24,
        borderRadius: BorderRadius.circular(AppRadii.rXl),
        child: SizedBox(
          width: w,
          height: h,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onClose: () => Navigator.of(context).maybePop()),
              const Divider(height: 1, color: AppColors.line),
              Expanded(
                child: _Body(
                  loading: _loading,
                  error: _error,
                  screens: _screens.values.toList(growable: false),
                  windows: _windows.values.toList(growable: false),
                  selected: _selected,
                  onPick: _onPick,
                ),
              ),
              const Divider(height: 1, color: AppColors.line),
              _Footer(
                preset: _preset,
                onPresetChanged: (p) => setState(() => _preset = p),
                captureAudio: _captureAudio,
                onCaptureAudioChanged: (v) =>
                    setState(() => _captureAudio = v),
                showEchoTip: fullScreenSelected && _captureAudio,
                canShare: canShare,
                onCancel: () => Navigator.of(context).maybePop(),
                onShare: _confirm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 12, 16),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Share your screen',
                  style: TextStyle(
                    color: AppColors.ink1,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Pick a display or a specific window. Others will see what you choose.',
                  style: TextStyle(color: AppColors.ink2, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, color: AppColors.ink2),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.loading,
    required this.error,
    required this.screens,
    required this.windows,
    required this.selected,
    required this.onPick,
  });

  final bool loading;
  final Object? error;
  final List<rtc.DesktopCapturerSource> screens;
  final List<rtc.DesktopCapturerSource> windows;
  final rtc.DesktopCapturerSource? selected;
  final void Function(rtc.DesktopCapturerSource) onPick;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'Could not load capture sources.\n$error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.ink2, fontSize: 13),
          ),
        ),
      );
    }
    if (screens.isEmpty && windows.isEmpty) {
      return const Center(
        child: Text(
          'No capture sources available.',
          style: TextStyle(color: AppColors.ink2),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (screens.isNotEmpty) ...[
            const _SectionLabel('Screens'),
            const SizedBox(height: 10),
            _Grid(
              sources: screens,
              selected: selected,
              onPick: onPick,
              minTileWidth: 240,
            ),
          ],
          if (screens.isNotEmpty && windows.isNotEmpty)
            const SizedBox(height: 22),
          if (windows.isNotEmpty) ...[
            const _SectionLabel('Windows'),
            const SizedBox(height: 10),
            _Grid(
              sources: windows,
              selected: selected,
              onPick: onPick,
              minTileWidth: 200,
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: AppColors.ink2,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.sources,
    required this.selected,
    required this.onPick,
    required this.minTileWidth,
  });

  final List<rtc.DesktopCapturerSource> sources;
  final rtc.DesktopCapturerSource? selected;
  final void Function(rtc.DesktopCapturerSource) onPick;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = (c.maxWidth / minTileWidth).floor().clamp(2, 5);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: sources.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 200 / 150,
        ),
        itemBuilder: (_, i) {
          final s = sources[i];
          return _SourceTile(
            source: s,
            selected: selected?.id == s.id,
            onTap: () => onPick(s),
          );
        },
      );
    });
  }
}

class _SourceTile extends StatefulWidget {
  const _SourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });
  final rtc.DesktopCapturerSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  final List<StreamSubscription<dynamic>> _subs = [];
  Uint8List? _thumb;
  String _name = '';

  @override
  void initState() {
    super.initState();
    _name = widget.source.name;
    final initial = widget.source.thumbnail;
    if (initial != null && initial.isNotEmpty) _thumb = initial;
    _subs.add(widget.source.onThumbnailChanged.stream.listen((t) {
      if (!mounted) return;
      setState(() => _thumb = t);
    }));
    _subs.add(widget.source.onNameChanged.stream.listen((n) {
      if (!mounted) return;
      setState(() => _name = n);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final borderColor =
        widget.selected ? AppColors.ember : AppColors.line;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.rMd),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: AppColors.raised,
            borderRadius: BorderRadius.circular(AppRadii.rMd),
            border: Border.all(
              color: borderColor,
              width: widget.selected ? 2 : 1,
            ),
            boxShadow: widget.selected
                ? [
                    BoxShadow(
                      color: AppColors.ember.withValues(alpha: 0.25),
                      blurRadius: 16,
                      spreadRadius: 0,
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(AppRadii.rSm),
                  ),
                  clipBehavior: Clip.antiAlias,
                  alignment: Alignment.center,
                  child: _thumb != null
                      ? Image.memory(
                          _thumb!,
                          gaplessPlayback: true,
                          fit: BoxFit.contain,
                        )
                      : Icon(
                          widget.source.type == rtc.SourceType.Screen
                              ? Icons.desktop_windows_outlined
                              : Icons.web_asset_outlined,
                          color: AppColors.ink3,
                          size: 36,
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    widget.source.type == rtc.SourceType.Screen
                        ? Icons.desktop_windows_outlined
                        : Icons.web_asset_outlined,
                    size: 14,
                    color: widget.selected
                        ? AppColors.ember
                        : AppColors.ink2,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _name.isNotEmpty ? _name : 'Untitled',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.selected
                            ? AppColors.ink1
                            : AppColors.ink1,
                        fontSize: 12.5,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.preset,
    required this.onPresetChanged,
    required this.captureAudio,
    required this.onCaptureAudioChanged,
    required this.showEchoTip,
    required this.canShare,
    required this.onCancel,
    required this.onShare,
  });

  final QualityPreset preset;
  final ValueChanged<QualityPreset> onPresetChanged;
  final bool captureAudio;
  final ValueChanged<bool> onCaptureAudioChanged;
  final bool showEchoTip;
  final bool canShare;
  final VoidCallback onCancel;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _QualityDropdown(
                value: preset,
                onChanged: onPresetChanged,
              ),
              const SizedBox(width: 16),
              _AudioToggle(
                value: captureAudio,
                onChanged: onCaptureAudioChanged,
              ),
              const Spacer(),
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.ink2,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                ),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: canShare ? onShare : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.ember,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AppColors.ember.withValues(alpha: 0.35),
                  disabledForegroundColor:
                      Colors.white.withValues(alpha: 0.7),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 22, vertical: 14),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                icon: const Icon(Icons.screen_share_outlined, size: 18),
                label: const Text('Start sharing'),
              ),
            ],
          ),
          if (showEchoTip)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
                decoration: BoxDecoration(
                  color: AppColors.ember.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadii.rSm),
                  border: Border.all(
                    color: AppColors.ember.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        size: 16, color: AppColors.ember),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Tip: sharing an entire screen with audio can echo remote voices back. '
                        'Mute the app output, or share a single window without audio for the cleanest result.',
                        style: TextStyle(
                          color: AppColors.ink1,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _QualityDropdown extends StatelessWidget {
  const _QualityDropdown({required this.value, required this.onChanged});
  final QualityPreset value;
  final ValueChanged<QualityPreset> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(AppRadii.rSm),
        border: Border.all(color: AppColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<QualityPreset>(
          value: value,
          dropdownColor: AppColors.raised,
          icon: const Icon(Icons.expand_more, color: AppColors.ink2),
          style: const TextStyle(color: AppColors.ink1, fontSize: 13),
          onChanged: (p) {
            if (p != null) onChanged(p);
          },
          items: [
            for (final p in QualityPreset.values)
              DropdownMenuItem(
                value: p,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.tune,
                        size: 14, color: AppColors.ink2),
                    const SizedBox(width: 8),
                    Text(
                      p.label,
                      style: const TextStyle(
                        color: AppColors.ink1,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      p.detail,
                      style: const TextStyle(
                        color: AppColors.ink2,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AudioToggle extends StatelessWidget {
  const _AudioToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.rSm);
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: radius,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: value,
                  onChanged: (v) => onChanged(v ?? false),
                  activeColor: AppColors.ember,
                  checkColor: Colors.white,
                  side: const BorderSide(
                      color: AppColors.line, width: 1.5),
                  materialTapTargetSize:
                      MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Share audio',
                style: TextStyle(
                  color: AppColors.ink1,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
