// Floating mini-call window. Shown when the call notifier is minimized.
// Position it as an overlay at the bottom-right of the app shell.
//
// Click the pip body or the return button → call expand() to bring back the
// full CallScreen. The red button always hangs up.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../theme/theme.dart';
import '../state/call_state.dart';
import '../state/group_call_state.dart';

class CallPip extends StatelessWidget {
  const CallPip({
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
        final showGroup = group.lifecycle == GroupCallLifecycle.active && group.isMinimized;
        final showCall = (call.lifecycle == CallLifecycle.ringingOut ||
                call.lifecycle == CallLifecycle.active) &&
            call.isMinimized;
        if (!showGroup && !showCall) return const SizedBox.shrink();

        final title = showGroup
            ? 'Voice chat'
            : (call.peer?.displayName ?? 'Call');
        final colorHex = showGroup ? '#EA580C' : (call.peer?.avatarColor ?? '#EA580C');
        final started = showGroup ? group.startedAt : call.startedAt;
        final onExpand = showGroup ? group.expand : call.expand;
        final onHangup = showGroup ? group.leaveGroupCall : call.end;

        return Positioned(
          right: 20,
          bottom: 20,
          child: _PipBody(
            title: title,
            colorHex: colorHex,
            startedAt: started,
            onExpand: onExpand,
            onHangup: () => onHangup(),
          ),
        );
      },
    );
  }
}

class _PipBody extends StatefulWidget {
  const _PipBody({
    required this.title,
    required this.colorHex,
    required this.startedAt,
    required this.onExpand,
    required this.onHangup,
  });

  final String title;
  final String colorHex;
  final DateTime? startedAt;
  final VoidCallback onExpand;
  final VoidCallback onHangup;

  @override
  State<_PipBody> createState() => _PipBodyState();
}

class _PipBodyState extends State<_PipBody> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String _elapsed() {
    final start = widget.startedAt;
    if (start == null) return '...';
    final d = DateTime.now().difference(start);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.rLg),
        onTap: widget.onExpand,
        child: Container(
          width: 280,
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: AppColors.panel,
            borderRadius: BorderRadius.circular(AppRadii.rLg),
            border: Border.all(color: AppColors.line),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: avatarColor(widget.colorHex, widget.title),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  avatarInitials(widget.title),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.ink1,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _elapsed(),
                      style: const TextStyle(
                        color: AppColors.ink2,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _PipBtn(
                icon: Icons.open_in_full,
                color: const Color(0xFF22C55E),
                onTap: widget.onExpand,
                tooltip: 'Return to call',
              ),
              const SizedBox(width: 6),
              _PipBtn(
                icon: Icons.call_end,
                color: AppColors.err,
                onTap: widget.onHangup,
                tooltip: 'Hang up',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PipBtn extends StatelessWidget {
  const _PipBtn({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    // Wrap InkWell in its own Material(transparent, circle) so the hover
    // highlight is clipped to the 36px circle. Otherwise the highlight paints
    // onto the outer pip Material (280px wide), producing a giant grey block.
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
        ),
      ),
    );
  }
}
