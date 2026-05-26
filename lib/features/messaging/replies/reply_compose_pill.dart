// Pill rendered above the composer when the user has picked a message to
// reply to. Shows an ember rail, the original sender's display name, an
// 80-char body preview, and a close button that cancels the reply target.

import 'package:flutter/material.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';

class ReplyComposePill extends StatelessWidget {
  const ReplyComposePill({
    super.key,
    required this.message,
    required this.senderName,
    required this.onCancel,
  });

  final Message message;
  final String senderName;
  final VoidCallback onCancel;

  static const _previewMax = 80;

  String _preview() {
    final body =
        message.displayBody.isNotEmpty ? message.displayBody : message.body;
    if (body.isNotEmpty) {
      return body.length > _previewMax
          ? '${body.substring(0, _previewMax)}…'
          : body;
    }
    if (message.attachments.isNotEmpty) {
      final a = message.attachments.first;
      if (a.kind == 'image') return 'Photo';
      return a.filename.isNotEmpty ? a.filename : 'Attachment';
    }
    if (message.voice != null) return 'Voice message';
    return 'Message';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.raised.withAlpha(150),
        border: const Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 16, color: AppColors.ember),
          const SizedBox(width: 8),
          Container(
            width: 2,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.ember,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reply to $senderName',
                  style: const TextStyle(
                    color: AppColors.ember,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _preview(),
                  style: const TextStyle(
                    color: AppColors.ink3,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cancel reply',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            onPressed: onCancel,
            icon: const Icon(Icons.close, color: AppColors.ink3),
          ),
        ],
      ),
    );
  }
}
