import 'package:flutter/material.dart';

import '../services/updater.dart';

/// Thin top-of-window strip mirroring Telegram Desktop's update affordance.
/// Self-contained: takes an [UpdaterService] instance and re-renders off its
/// stream. Renders nothing while [UpdateIdle] or [UpdateChecking] so it never
/// interrupts the user during the silent boot poll.
class UpdateBanner extends StatelessWidget {
  static const double height = 40;

  // "Ember" — warm amber that draws the eye without screaming. Telegram uses a
  // similar warm hue so users associate it with "soft action required".
  static const Color _embColor = Color(0xFFE8923C);
  static const Color _errColor = Color(0xFFC0392B);

  final UpdaterService service;

  const UpdateBanner({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UpdateState>(
      stream: service.state,
      initialData: service.current,
      builder: (context, snap) {
        final s = snap.data ?? const UpdateIdle();
        if (s is UpdateIdle || s is UpdateChecking) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          height: height,
          width: double.infinity,
          child: switch (s) {
            UpdateAvailable a => _bar(
                color: _embColor,
                text:
                    'Update available  ·  v${a.currentVersion} → v${a.newVersion}',
                action: 'Update',
                onTap: service.startDownload,
              ),
            UpdateDownloading d => _downloading(d),
            UpdateReady r => _bar(
                color: _embColor,
                text: 'Update ready  ·  v${r.newVersion}',
                action: 'Restart to update',
                onTap: service.launchAndQuit,
              ),
            UpdateError e => _bar(
                color: _errColor,
                text: 'Update failed: ${e.message}',
                action: 'Retry',
                onTap: service.retry,
              ),
            _ => const SizedBox.shrink(),
          },
        );
      },
    );
  }

  Widget _bar({
    required Color color,
    required String text,
    required String action,
    required VoidCallback onTap,
  }) {
    return Container(
      color: color,
      padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              action,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _downloading(UpdateDownloading d) {
    final pct = d.progress == null ? null : (d.progress! * 100).clamp(0, 100);
    final label = pct == null
        ? 'Downloading update v${d.newVersion}…'
        : 'Downloading update v${d.newVersion}…  ${pct.toStringAsFixed(0)}%';
    return Stack(
      children: [
        Container(color: _embColor),
        Positioned.fill(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(
              value: d.progress,
              minHeight: 2,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 16),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
