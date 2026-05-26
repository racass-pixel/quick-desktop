// Pill bubble for non-image attachments. Filename + size + a download
// button that pops the system handler via url_launcher.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';

class FileBubble extends StatelessWidget {
  const FileBubble({super.key, required this.attachment, required this.url});
  final Attachment attachment;
  final String url;

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  IconData _icon() {
    final m = attachment.mime.toLowerCase();
    if (m.startsWith('audio/')) return Icons.audio_file;
    if (m.startsWith('video/')) return Icons.movie;
    if (m.contains('pdf')) return Icons.picture_as_pdf;
    if (m.contains('zip') || m.contains('compressed')) {
      return Icons.folder_zip;
    }
    return Icons.insert_drive_file;
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.bg.withAlpha(140),
          borderRadius: BorderRadius.circular(AppRadii.rMd),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.ember.withAlpha(40),
                borderRadius: BorderRadius.circular(AppRadii.rSm),
              ),
              child: Icon(_icon(), size: 20, color: AppColors.ember),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.filename.isNotEmpty
                        ? attachment.filename
                        : 'File',
                    style: const TextStyle(
                      color: AppColors.ink1,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _fmtSize(attachment.sizeBytes),
                    style: const TextStyle(
                        color: AppColors.ink3, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Download',
              iconSize: 18,
              onPressed: () async {
                final uri = Uri.tryParse(url);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: const Icon(Icons.download, color: AppColors.ink2),
            ),
          ],
        ),
      ),
    );
  }
}
