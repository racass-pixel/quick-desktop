// Bottom-right toast stack rendered as an overlay. Subscribes to the Toaster
// singleton and renders the most recent N entries, animating insertion and
// removal. Each toast pauses its auto-dismiss while hovered (handled by the
// service); the widget just propagates pointer enter/exit events.

import 'package:flutter/material.dart';

import '../services/toaster.dart';
import '../theme/theme.dart';
import '../ui/widgets/avatar.dart';

class ToastLayer extends StatefulWidget {
  const ToastLayer({super.key});

  @override
  State<ToastLayer> createState() => _ToastLayerState();
}

class _ToastLayerState extends State<ToastLayer> {
  late final Stream<List<ToastSpec>> _stream;

  @override
  void initState() {
    super.initState();
    _stream = Toaster.instance.toasts;
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: StreamBuilder<List<ToastSpec>>(
          stream: _stream,
          initialData: Toaster.instance.current,
          builder: (context, snap) {
            final list = snap.data ?? const <ToastSpec>[];
            // Show newest 3 at the bottom, newest closest to the bottom edge.
            final visible = list.length <= Toaster.maxVisible
                ? list
                : list.sublist(list.length - Toaster.maxVisible);
            return Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 20, bottom: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final t in visible)
                      Padding(
                        key: ValueKey(t.id),
                        padding: const EdgeInsets.only(top: 10),
                        child: _ToastCard(spec: t),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({required this.spec});
  final ToastSpec spec;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0.25, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctl, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _ctl, curve: Curves.easeOut);
    _ctl.forward();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _onEnter(PointerEvent _) {
    Toaster.instance.pauseTimer(widget.spec.id);
  }

  void _onExit(PointerEvent _) {
    Toaster.instance.resumeTimer(widget.spec.id);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final spec = widget.spec;
    final isCall = spec.kind == ToastKind.incomingCall;
    final isGroup = spec.kind == ToastKind.groupCallStarted;
    final card = Container(
      width: 360,
      constraints: const BoxConstraints(minHeight: 80),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: spec.onTap == null
                ? null
                : () {
                    spec.onTap?.call();
                    Toaster.instance.dismiss(spec.id);
                  },
            hoverColor: Colors.white.withValues(alpha: 0.03),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Avatar(
                    name: spec.avatarSeed,
                    colorHex: spec.avatarColorHex,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                spec.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.ink1,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            _CloseButton(onTap: () {
                              Toaster.instance.dismiss(spec.id);
                            }),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          spec.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.ink2,
                            fontSize: 12.5,
                            height: 1.3,
                          ),
                        ),
                        if (isCall) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _PillButton(
                                color: const Color(0xFF22C55E),
                                label: 'Accept',
                                onTap: () {
                                  spec.onAccept?.call();
                                  Toaster.instance.dismiss(spec.id);
                                },
                              ),
                              const SizedBox(width: 8),
                              _PillButton(
                                color: AppColors.err,
                                label: 'Decline',
                                onTap: () {
                                  spec.onDecline?.call();
                                  Toaster.instance.dismiss(spec.id);
                                },
                              ),
                            ],
                          ),
                        ] else if (isGroup) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              _PillButton(
                                color: AppColors.ember,
                                label: 'Join',
                                onTap: () {
                                  spec.onJoin?.call();
                                  Toaster.instance.dismiss(spec.id);
                                },
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return card;
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkResponse(
        onTap: onTap,
        radius: 14,
        child: const Padding(
          padding: EdgeInsets.all(2),
          child: Icon(Icons.close, size: 16, color: AppColors.ink3),
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.color,
    required this.label,
    required this.onTap,
  });

  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(8);
    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color,
            borderRadius: radius,
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
