// Per-composer pending upload state. Tracks each file picked by AttachButton
// from the moment it enters the upload pipeline to the moment its file_id is
// captured for the next outgoing message.

import 'package:flutter/foundation.dart';

import '../../../api/media_upload.dart';

class PendingUpload {
  PendingUpload({
    required this.localId,
    required this.filename,
    required this.sizeBytes,
    this.progress = 0,
    this.upload,
    this.error,
  });

  final String localId;
  final String filename;
  final int sizeBytes;
  double progress;
  MediaUpload? upload;
  String? error;

  bool get done => upload != null;
  bool get failed => error != null;
}

class UploadQueue extends ChangeNotifier {
  final List<PendingUpload> items = <PendingUpload>[];

  void add(PendingUpload p) {
    items.add(p);
    notifyListeners();
  }

  void update(String localId, {double? progress, MediaUpload? upload, String? error}) {
    final i = items.indexWhere((e) => e.localId == localId);
    if (i < 0) return;
    final p = items[i];
    if (progress != null) p.progress = progress;
    if (upload != null) p.upload = upload;
    if (error != null) p.error = error;
    notifyListeners();
  }

  void remove(String localId) {
    items.removeWhere((e) => e.localId == localId);
    notifyListeners();
  }

  void clear() {
    items.clear();
    notifyListeners();
  }

  // Returns the file_ids ready to send + clears those entries from the queue.
  List<String> drainReady() {
    final out = <String>[];
    items.removeWhere((p) {
      if (p.upload != null) {
        out.add(p.upload!.fileId);
        return true;
      }
      return false;
    });
    notifyListeners();
    return out;
  }
}
