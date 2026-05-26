// Aggregated-reaction pills rendered below a message bubble. Groups raw
// `Reaction { user_id, emoji }` rows by emoji into "<glyph> <count>" pills.
// Tapping a pill toggles the caller's reaction. Mine-pills are ember-tinted.

import 'package:flutter/material.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';

class ReactionStrip extends StatelessWidget {
  const ReactionStrip({
    super.key,
    required this.reactions,
    required this.currentUserId,
    required this.onToggle,
  });

  final List<Reaction> reactions;
  final String? currentUserId;
  final void Function(String emoji) onToggle;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final counts = <String, _Bucket>{};
    for (final r in reactions) {
      final b = counts[r.emoji] ?? _Bucket();
      b.count++;
      if (currentUserId != null && r.userId == currentUserId) b.mine = true;
      counts[r.emoji] = b;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: counts.entries
            .map(
              (e) => _Pill(
                emoji: e.key,
                count: e.value.count,
                mine: e.value.mine,
                onTap: () => onToggle(e.key),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _Bucket {
  int count = 0;
  bool mine = false;
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.emoji,
    required this.count,
    required this.mine,
    required this.onTap,
  });
  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = mine ? AppColors.ember.withAlpha(40) : AppColors.raised;
    final border = mine ? AppColors.ember.withAlpha(120) : AppColors.line;
    final fg = mine ? AppColors.ember : AppColors.ink2;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 13, height: 1)),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  color: fg,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
