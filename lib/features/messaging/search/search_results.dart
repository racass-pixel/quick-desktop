// Renders Messaging.SearchMessages results. Each row shows sender avatar,
// display name, the matched body snippet (highlighting the query in ember),
// the conversation title, and a relative time stamp.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';
import '../../../ui/widgets/avatar.dart';

class MessageSearchResults extends StatelessWidget {
  const MessageSearchResults({
    super.key,
    required this.query,
    required this.results,
    required this.conversations,
    required this.onOpen,
    this.busy = false,
  });

  final String query;
  final List<Message> results;
  // conversationId -> Conversation, used to surface the chat title.
  final Map<String, Conversation> conversations;
  final bool busy;
  // Called when the user taps a result. Receives the message, so the caller
  // can route to the right chat + scroll-to + pulse.
  final void Function(Message m) onOpen;

  String _relative(DateTime t) {
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (now.year == t.year && now.month == t.month && now.day == t.day) {
      return DateFormat.Hm().format(t);
    }
    if (d.inDays < 7) return DateFormat.E().format(t);
    return DateFormat.yMd().format(t);
  }

  @override
  Widget build(BuildContext context) {
    if (busy && results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text(
            'No messages found',
            style: TextStyle(color: AppColors.ink3, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (_, i) {
        final m = results[i];
        final conv = conversations[m.conversationId];
        final title = conv?.displayTitle() ?? '';
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onOpen(m),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Avatar(
                    name: conv?.avatarSeed() ?? '?',
                    colorHex: conv?.avatarColorHex() ?? '#6F7180',
                    size: 36,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                  color: AppColors.ink1,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13.5,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              _relative(m.createdAt),
                              style: const TextStyle(
                                  color: AppColors.ink3, fontSize: 11),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        _SnippetText(
                          body: m.renderedBody.isNotEmpty
                              ? m.renderedBody
                              : (m.attachments.isNotEmpty
                                  ? 'Attachment'
                                  : (m.voice != null ? 'Voice message' : '')),
                          query: query,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SnippetText extends StatelessWidget {
  const _SnippetText({required this.body, required this.query});
  final String body;
  final String query;

  @override
  Widget build(BuildContext context) {
    if (body.isEmpty) {
      return const Text('',
          style: TextStyle(color: AppColors.ink3, fontSize: 12.5));
    }
    final q = query.trim();
    if (q.isEmpty) {
      return Text(
        body,
        style: const TextStyle(color: AppColors.ink2, fontSize: 12.5),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    // Highlight the first occurrence of the query case-insensitively. Long
    // bodies get clamped to a window around the match.
    final lc = body.toLowerCase();
    final idx = lc.indexOf(q.toLowerCase());
    if (idx < 0) {
      return Text(
        body,
        style: const TextStyle(color: AppColors.ink2, fontSize: 12.5),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    final start = (idx - 24).clamp(0, body.length);
    final end = (idx + q.length + 40).clamp(0, body.length);
    final pre = (start > 0 ? '…' : '') + body.substring(start, idx);
    final hit = body.substring(idx, idx + q.length);
    final post =
        body.substring(idx + q.length, end) + (end < body.length ? '…' : '');
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(color: AppColors.ink2, fontSize: 12.5),
        children: [
          TextSpan(text: pre),
          TextSpan(
            text: hit,
            style: const TextStyle(
              color: AppColors.ember,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: post),
        ],
      ),
    );
  }
}
