// Telegram-style 6-emoji quick-pick popover. Anchors near a tap origin and
// closes on outside tap / Escape. The "+" button expands to ten more common
// emojis. The caller wires the actual AddReaction / RemoveReaction RPC.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';

const _quickEmojis = ['❤️', '👍', '👎', '🔥', '💯', '😂'];
const _extraEmojis = ['😢', '😡', '🎉', '👏', '🙏', '👀', '🚀', '⭐', '✅', '❌'];

const _panelW = 260.0;
const _panelH = 56.0;

// Show the picker as an overlay anchored at `anchor`. Closes when the user
// picks an emoji, taps outside, or presses Escape.
void showReactionPickerOverlay({
  required BuildContext context,
  required Offset anchor,
  required Message message,
  required void Function(String emoji) onPick,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _ReactionPickerLayer(
      anchor: anchor,
      message: message,
      onPick: (e) {
        onPick(e);
        entry.remove();
      },
      onDismiss: entry.remove,
    ),
  );
  overlay.insert(entry);
}

class _ReactionPickerLayer extends StatefulWidget {
  const _ReactionPickerLayer({
    required this.anchor,
    required this.message,
    required this.onPick,
    required this.onDismiss,
  });
  final Offset anchor;
  final Message message;
  final void Function(String emoji) onPick;
  final VoidCallback onDismiss;

  @override
  State<_ReactionPickerLayer> createState() => _ReactionPickerLayerState();
}

class _ReactionPickerLayerState extends State<_ReactionPickerLayer> {
  bool _expanded = false;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context).size;
    const pad = 8.0;
    final left = (widget.anchor.dx - _panelW / 2)
        .clamp(pad, mq.width - _panelW - pad);
    final top = (widget.anchor.dy - _panelH - 8)
        .clamp(pad, mq.height - _panelH - pad);

    final emojis = _expanded ? [..._quickEmojis, ..._extraEmojis] : _quickEmojis;
    return Stack(
      children: [
        // Dismiss layer
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: KeyboardListener(
            focusNode: _focusNode,
            onKeyEvent: (ev) {
              if (ev is KeyDownEvent &&
                  ev.logicalKey == LogicalKeyboardKey.escape) {
                widget.onDismiss();
              }
            },
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: _expanded ? 320 : _panelW + 8,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.panel,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: AppColors.line),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(110),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Wrap(
                  spacing: 2,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final e in emojis)
                      _EmojiButton(
                        emoji: e,
                        onTap: () => widget.onPick(e),
                      ),
                    if (!_expanded)
                      _PlusButton(
                        onTap: () => setState(() => _expanded = true),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmojiButton extends StatefulWidget {
  const _EmojiButton({required this.emoji, required this.onTap});
  final String emoji;
  final VoidCallback onTap;

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 120),
          scale: _hover ? 1.2 : 1.0,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover ? AppColors.raised : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(widget.emoji,
                style: const TextStyle(fontSize: 18, height: 1)),
          ),
        ),
      ),
    );
  }
}

class _PlusButton extends StatelessWidget {
  const _PlusButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        child: const Icon(Icons.add, size: 16, color: AppColors.ink3),
      ),
    );
  }
}
