// Chats DAO. Backs the sidebar conversation list. Plain columns drive
// ordering (`last_message_at`), the encrypted blob holds the title, peer
// snapshot, preview text, and rest of the conversation projection.

import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../api/dto.dart';
import 'db.dart';

class ChatsDao {
  ChatsDao(this._ldb);
  final LocalDb _ldb;
  Database get _db => _ldb.db;

  Future<void> upsert(Conversation c) async {
    final blob = await _ldb.crypto.encryptJson(_convToBlob(c));
    await _db.insert(
      'chats',
      {
        'id': c.id,
        'kind': c.type,
        'last_message_at': c.lastMessageAt?.millisecondsSinceEpoch,
        'last_message_id': c.preview?.id,
        'unread_count': c.unreadCount,
        'pinned_at': null,
        'enc_blob': blob,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertAll(Iterable<Conversation> chats) async {
    final batch = _db.batch();
    for (final c in chats) {
      final blob = await _ldb.crypto.encryptJson(_convToBlob(c));
      batch.insert(
        'chats',
        {
          'id': c.id,
          'kind': c.type,
          'last_message_at': c.lastMessageAt?.millisecondsSinceEpoch,
          'last_message_id': c.preview?.id,
          'unread_count': c.unreadCount,
          'enc_blob': blob,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  // Most-recent first, mirroring the sidebar order.
  Future<List<Conversation>> listAll() async {
    final rows = await _db.query(
      'chats',
      orderBy: 'last_message_at DESC',
    );
    final out = <Conversation>[];
    for (final r in rows) {
      out.add(await _rowToConv(r));
    }
    return out;
  }

  Future<Conversation?> get(String id) async {
    final rows = await _db.query(
      'chats',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToConv(rows.first);
  }

  Future<void> delete(String id) async {
    await _db.delete('chats', where: 'id = ?', whereArgs: [id]);
    await _db.delete('messages', where: 'chat_id = ?', whereArgs: [id]);
    await _db.delete('chat_members', where: 'chat_id = ?', whereArgs: [id]);
  }

  Future<void> setUnread(String id, int unread) async {
    await _db.update(
      'chats',
      {'unread_count': unread},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setPinned(String id, DateTime? pinnedAt) async {
    await _db.update(
      'chats',
      {'pinned_at': pinnedAt?.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Map<String, dynamic> _convToBlob(Conversation c) => {
        'title': c.title,
        'peer': c.peer == null
            ? null
            : {
                'id': c.peer!.id,
                'handle': c.peer!.handle,
                'displayName': c.peer!.displayName,
                'avatarColor': c.peer!.avatarColor,
                'lastSeenAt': c.peer!.lastSeenAt?.toIso8601String(),
                'bio': c.peer!.bio,
              },
        'avatarColor': c.avatarColor,
        'memberCount': c.memberCount,
        'myRole': c.myRole,
        'preview': c.preview == null
            ? null
            : {
                'id': c.preview!.id,
                'conversationId': c.preview!.conversationId,
                'senderId': c.preview!.senderId,
                'body': c.preview!.body,
                'createdAt': c.preview!.createdAt.toIso8601String(),
                'kind': c.preview!.kind,
              },
      };

  Future<Conversation> _rowToConv(Map<String, Object?> r) async {
    Map<String, dynamic> blob = const {};
    final enc = r['enc_blob'];
    if (enc is List<int> && enc.isNotEmpty) {
      try {
        blob = await _ldb.crypto.decryptJson(Uint8List.fromList(enc));
      } catch (_) {/* corrupt row — fall back to scalar only */}
    }
    final lastMs = r['last_message_at'] as int?;
    User? peer;
    final p = blob['peer'];
    if (p is Map<String, dynamic>) {
      peer = User(
        id: (p['id'] as String?) ?? '',
        handle: (p['handle'] as String?) ?? '',
        displayName: (p['displayName'] as String?) ?? '',
        avatarColor: (p['avatarColor'] as String?) ?? '#6F7180',
        lastSeenAt: (p['lastSeenAt'] is String)
            ? DateTime.tryParse(p['lastSeenAt'] as String)
            : null,
        bio: (p['bio'] as String?) ?? '',
      );
    }
    Message? preview;
    final pv = blob['preview'];
    if (pv is Map<String, dynamic>) {
      preview = Message(
        id: (pv['id'] as String?) ?? '',
        conversationId: (pv['conversationId'] as String?) ?? '',
        senderId: (pv['senderId'] as String?) ?? '',
        body: (pv['body'] as String?) ?? '',
        createdAt: DateTime.tryParse((pv['createdAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        kind: (pv['kind'] as String?) ?? 'text',
      );
    }
    return Conversation(
      id: r['id'] as String,
      type: (r['kind'] as String?) ?? 'dm',
      title: (blob['title'] as String?) ?? '',
      peer: peer,
      lastMessageAt:
          lastMs != null ? DateTime.fromMillisecondsSinceEpoch(lastMs) : null,
      preview: preview,
      unreadCount: (r['unread_count'] as int?) ?? 0,
      memberCount: (blob['memberCount'] as int?) ?? 0,
      avatarColor: (blob['avatarColor'] as String?) ?? '#6F7180',
      myRole: (blob['myRole'] as String?) ?? '',
    );
  }
}
