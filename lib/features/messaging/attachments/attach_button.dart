// Paperclip button in the composer. Opens the system file picker, then
// streams each pick through MediaUploader, reporting progress into the
// provided UploadQueue.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../../theme/theme.dart';
import 'upload_state.dart';

class AttachButton extends ConsumerWidget {
  const AttachButton({super.key, required this.queue});
  final UploadQueue queue;

  Future<void> _pickAndUpload(WidgetRef ref) async {
    final uploader = ref.read(mediaUploaderProvider);
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(allowMultiple: true);
    } catch (_) {
      return;
    }
    if (result == null) return;
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      final localId =
          'up_${DateTime.now().microsecondsSinceEpoch}_${f.name.hashCode}';
      queue.add(PendingUpload(
        localId: localId,
        filename: f.name,
        sizeBytes: f.size,
      ));
      // Fire-and-forget; UploadProgress row will reflect state.
      // ignore: discarded_futures
      uploader.uploadPath(
        path,
        filename: f.name,
        onProgress: (p) => queue.update(localId, progress: p),
      ).then((up) {
        queue.update(localId, upload: up, progress: 1.0);
      }).catchError((e) {
        queue.update(localId, error: e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      tooltip: 'Attach files',
      iconSize: 20,
      onPressed: () => _pickAndUpload(ref),
      icon: const Icon(Icons.attach_file, color: AppColors.ink2),
    );
  }
}
