// Modal shown while the CallNotifier is in lifecycle == incoming.
// Mount at the app root so it overlays any screen. Auto-dismisses when
// lifecycle leaves incoming (peer canceled, we accepted, etc.).
//
// Buttons: Accept (green) → call.acceptIncoming(); Decline (red) →
// call.declineIncoming(). After accept the dialog closes and CallScreen takes
// over.

import 'package:flutter/material.dart';

import '../../../theme/theme.dart';
import '../state/call_state.dart';

class IncomingCallOverlay extends StatelessWidget {
  const IncomingCallOverlay({super.key, required this.call});
  final CallNotifier call;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: call,
      builder: (_, _) {
        if (call.lifecycle != CallLifecycle.incoming) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
            alignment: Alignment.center,
            child: _IncomingCard(call: call),
          ),
        );
      },
    );
  }
}

class _IncomingCard extends StatelessWidget {
  const _IncomingCard({required this.call});
  final CallNotifier call;

  @override
  Widget build(BuildContext context) {
    final peer = call.peer;
    final name = peer?.displayName ?? 'Caller';
    final colorHex = peer?.avatarColor ?? '#6F7180';
    final video = call.isVideo;
    return Material(
      color: AppColors.panel,
      borderRadius: BorderRadius.circular(AppRadii.rXl),
      elevation: 24,
      shadowColor: Colors.black,
      child: Container(
        width: 340,
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadii.rXl),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
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
            const SizedBox(height: 18),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.ink1,
                fontSize: 19,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              video ? 'Incoming video call' : 'Incoming call',
              style: const TextStyle(color: AppColors.ink2, fontSize: 13),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: _ActionBtn(
                    icon: Icons.call_end,
                    label: 'Decline',
                    color: AppColors.err,
                    onTap: () => call.declineIncoming(),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _ActionBtn(
                    icon: video ? Icons.videocam : Icons.call,
                    label: 'Accept',
                    color: const Color(0xFF22C55E),
                    onTap: () => call.acceptIncoming(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.rMd),
      onTap: onTap,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadii.rMd),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
