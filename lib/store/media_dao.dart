// Media cache DAO. Tracks downloaded voice/image blobs on disk so the player
// can reuse the local file instead of re-fetching. Files live next to the DB
// in `<app-support>/quick/media/`. The file itself is NOT encrypted at rest
// — these are server-issued opaque IDs and re-downloadable; the index entry
// holds only the file path, mime, and bookkeeping.

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'db.dart';

class CachedMedia {
  CachedMedia({
    required this.fileId,
    required this.localPath,
    required this.mime,
    required this.sizeBytes,
    required this.cachedAt,
  });
  final String fileId;
  final String localPath;
  final String mime;
  final int sizeBytes;
  final DateTime cachedAt;
}

class MediaDao {
  MediaDao(this._ldb);
  final LocalDb _ldb;
  Database get _db => _ldb.db;

  Future<CachedMedia?> get(String fileId) async {
    final rows = await _db.query(
      'media_cache',
      where: 'file_id = ?',
      whereArgs: [fileId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return CachedMedia(
      fileId: r['file_id'] as String,
      localPath: r['local_path'] as String,
      mime: (r['mime'] as String?) ?? '',
      sizeBytes: (r['size_bytes'] as int?) ?? 0,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(
          (r['cached_at'] as int?) ?? 0),
    );
  }

  Future<void> put({
    required String fileId,
    required String localPath,
    required String mime,
    required int sizeBytes,
  }) async {
    await _db.insert(
      'media_cache',
      {
        'file_id': fileId,
        'local_path': localPath,
        'mime': mime,
        'size_bytes': sizeBytes,
        'cached_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Evict on best-effort LRU until total size is below `maxBytes`. Callers
  // can invoke this from idle hooks; not called automatically.
  Future<void> evictUntil(int maxBytes) async {
    final rows = await _db.query(
      'media_cache',
      orderBy: 'cached_at ASC',
    );
    int total = 0;
    for (final r in rows) {
      total += (r['size_bytes'] as int?) ?? 0;
    }
    if (total <= maxBytes) return;
    for (final r in rows) {
      if (total <= maxBytes) break;
      final path = r['local_path'] as String;
      final id = r['file_id'] as String;
      final size = (r['size_bytes'] as int?) ?? 0;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {/* swallow */}
      await _db.delete('media_cache', where: 'file_id = ?', whereArgs: [id]);
      total -= size;
    }
  }

  // Convenience: directory media files should be stored in.
  static Future<Directory> mediaDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}quick${Platform.pathSeparator}media',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
