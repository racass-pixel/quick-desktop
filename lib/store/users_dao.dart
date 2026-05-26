// Users DAO. Stores the projection used for sidebar/profile/sender rendering.
// Scalar columns we want to index/order (id, handle, last-seen) live plain;
// the rest is bundled into an encrypted blob.

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../api/dto.dart';
import 'db.dart';

class UsersDao {
  UsersDao(this._ldb);
  final LocalDb _ldb;
  Database get _db => _ldb.db;

  Future<void> upsert(User u) async {
    final blob = await _ldb.crypto.encryptJson({
      'bio': u.bio,
    });
    await _db.insert(
      'users',
      {
        'id': u.id,
        'handle': u.handle,
        'display_name': u.displayName,
        'avatar_color': u.avatarColor,
        'presence_seen_at': u.lastSeenAt?.millisecondsSinceEpoch,
        'enc_blob': blob,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertAll(Iterable<User> users) async {
    final batch = _db.batch();
    for (final u in users) {
      final blob = await _ldb.crypto.encryptJson({'bio': u.bio});
      batch.insert(
        'users',
        {
          'id': u.id,
          'handle': u.handle,
          'display_name': u.displayName,
          'avatar_color': u.avatarColor,
          'presence_seen_at': u.lastSeenAt?.millisecondsSinceEpoch,
          'enc_blob': blob,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<User?> get(String id) async {
    final rows = await _db.query(
      'users',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToUser(rows.first);
  }

  Future<List<User>> getMany(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db.query(
      'users',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    final out = <User>[];
    for (final r in rows) {
      final u = await _rowToUser(r);
      out.add(u);
    }
    return out;
  }

  Future<User> _rowToUser(Map<String, Object?> r) async {
    Map<String, dynamic> blob = const {};
    final enc = r['enc_blob'];
    if (enc is List<int> && enc.isNotEmpty) {
      try {
        blob = await _ldb.crypto.decryptJson(Uint8List.fromList(enc));
      } catch (_) {/* tolerate corrupt row */}
    }
    final seenMs = r['presence_seen_at'] as int?;
    return User(
      id: r['id'] as String,
      handle: (r['handle'] as String?) ?? '',
      displayName: (r['display_name'] as String?) ?? '',
      avatarColor: (r['avatar_color'] as String?) ?? '#6F7180',
      lastSeenAt:
          seenMs != null ? DateTime.fromMillisecondsSinceEpoch(seenMs) : null,
      bio: (blob['bio'] as String?) ?? '',
    );
  }
}

// Local convenience for callers that want to peek at how this DAO would
// serialise a user without writing one.
String debugUserJson(User u) =>
    jsonEncode({'id': u.id, 'handle': u.handle, 'displayName': u.displayName});
