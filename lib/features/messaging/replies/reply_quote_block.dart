// Small quoted card rendered above a message bubble when the message
// is a reply. Tapping it asks the controller to scroll-to + pulse the
// original message via the provided callback.

import 'package:flutter/material.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';

class ReplyQuoteBlock extends StatelessWidget {
  const ReplyQuoteBlock({
    super.key,
    required this.original,
    required this.senderName,
    required this.onTap,
  });

  final Message? original;
  final String senderName;
  final VoidCallback onTap;

  String _preview() {
    final m = original;
    if (m == null) return 'Message';
    final body = m.displayBody.isNotEmpty ? m.displayBody : m.body;
    if (body.isNotEmpty) {
      return body.length > 80 ? '${body.substring(0, 80)}…' : body;
    }
    if (m.attachments.isNotEmpty) {
      final a = m.attachments.first;
      if (a.kind == 'image') return 'Photo';
      return a.filename.isNotEmpty ? a.filename : 'Attachment';
    }
    if (m.voice != null) return 'Voice message';
    return 'Message';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.rSm),
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
            decoration: BoxDecoration(
              color: AppColors.bg.withAlpha(120),
              borderRadius: BorderRadius.circular(AppRadii.rSm),
              border: const Border(
                left: BorderSide(color: AppColors.ember, width: 2),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: const TextStyle(
                    color: AppColors.ember,
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  _preview(),
                  style: const TextStyle(
                    color: AppColors.ink2,
                    fontSize: 11.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
