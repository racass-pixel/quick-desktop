// Inline image preview inside a message bubble. Max width 320px; clicking
// opens the lightbox.

import 'package:flutter/material.dart';

import '../../../api/dto.dart';
import '../../../theme/theme.dart';
import 'image_lightbox.dart';

class ImageBubble extends StatelessWidget {
  const ImageBubble({super.key, required this.attachment, required this.url});
  final Attachment attachment;
  final String url;

  @override
  Widget build(BuildContext context) {
    final aspect = (attachment.width > 0 && attachment.height > 0)
        ? attachment.width / attachment.height
        : 1.4;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showImageLightbox(context, url,
            caption: attachment.filename),
        borderRadius: BorderRadius.circular(AppRadii.rMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.rMd),
            child: AspectRatio(
              aspectRatio: aspect.clamp(0.5, 2.5),
              child: Image.network(
                url,
                fit: BoxFit.cover,
                loadingBuilder: (_, child, p) => p == null
                    ? child
                    : Container(
                        color: AppColors.bg,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                errorBuilder: (_, __, ___) => Container(
                  color: AppColors.raised,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image,
                      color: AppColors.ink3, size: 32),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
