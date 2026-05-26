// Strip of in-flight uploads rendered above the composer. Each row shows
// the filename, a linear progress bar, and a cancel/dismiss button.

import 'package:flutter/material.dart';

import '../../../theme/theme.dart';
import 'upload_state.dart';

class UploadProgressStrip extends StatelessWidget {
  const UploadProgressStrip({super.key, required this.queue});
  final UploadQueue queue;

  String _fmtSize(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)}KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: queue,
      builder: (_, __) {
        if (queue.items.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            color: AppColors.raised,
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in queue.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(
                        p.failed
                            ? Icons.error_outline
                            : (p.done ? Icons.check_circle : Icons.upload_file),
                        size: 16,
                        color: p.failed
                            ? AppColors.err
                            : (p.done
                                ? AppColors.emberSoft
                                : AppColors.ink2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    p.filename,
                                    style: const TextStyle(
                                        color: AppColors.ink1, fontSize: 12),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  _fmtSize(p.sizeBytes),
                                  style: const TextStyle(
                                      color: AppColors.ink3, fontSize: 11),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: p.failed
                                    ? 1.0
                                    : (p.done ? 1.0 : p.progress),
                                minHeight: 3,
                                backgroundColor: AppColors.bg,
                                color: p.failed
                                    ? AppColors.err
                                    : AppColors.ember,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        iconSize: 14,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => queue.remove(p.localId),
                        icon: const Icon(Icons.close, color: AppColors.ink3),
                        tooltip: 'Remove',
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
