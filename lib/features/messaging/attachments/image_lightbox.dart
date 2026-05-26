// Full-screen image viewer. Tap-outside or X to dismiss. Download button
// opens the URL with the system's default handler via url_launcher.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../theme/theme.dart';

void showImageLightbox(BuildContext context, String url, {String? caption}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withAlpha(220),
    builder: (_) => _LightboxLayer(url: url, caption: caption),
  );
}

class _LightboxLayer extends StatelessWidget {
  const _LightboxLayer({required this.url, this.caption});
  final String url;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                child: Center(
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    loadingBuilder: (_, child, p) => p == null
                        ? child
                        : const Center(
                            child: SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image,
                      size: 64,
                      color: AppColors.ink3,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Open in browser',
                  onPressed: () async {
                    final uri = Uri.tryParse(url);
                    if (uri != null) {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    }
                  },
                  icon: const Icon(Icons.download, color: Colors.white),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ],
            ),
          ),
          if (caption != null && caption!.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Text(
                caption!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.ink1, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}
