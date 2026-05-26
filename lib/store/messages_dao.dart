// Messages DAO. Newest-by-chat queries are served from the indexed
// `(chat_id, created_at DESC)` covering index. Body and the optional voice
// attachment ride in encrypted blob columns.

import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../api/dto.dart';
import 'db.dart';

class MessagesDao {
  MessagesDao(this._ldb);
  final LocalDb _ldb;
  Database get _db => _ldb.db;

  Future<void> upsert(Message m) async {
    final encBody = await _ldb.crypto.encryptString(m.body);
    Uint8List? encAttachments;
    if (m.voice != null) {
      encAttachments = await _ldb.crypto.encryptJson({
        'voice': {
          'fileId': m.voice!.fileId,
          'durationMs': m.voice!.durationMs,
          'peaks': m.voice!.peaks,
          'played': m.voice!.played,
        },
      });
    }
    await _db.insert(
      'messages',
      {
        'id': m.id,
        'chat_id': m.conversationId,
        'sender_id': m.senderId,
        'created_at': m.createdAt.millisecondsSinceEpoch,
        'kind': m.kind,
        'status': _statusToInt(m.status),
        'enc_body': encBody,
        'enc_attachments': encAttachments,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertAll(Iterable<Message> messages) async {
    final batch = _db.batch();
    for (final m in messages) {
      final encBody = await _ldb.crypto.encryptString(m.body);
      Uint8List? encAttachments;
      if (m.voice != null) {
        encAttachments = await _ldb.crypto.encryptJson({
          'voice': {
            'fileId': m.voice!.fileId,
            'durationMs': m.voice!.durationMs,
            'peaks': m.voice!.peaks,
            'played': m.voice!.played,
          },
        });
      }
      batch.insert(
        'messages',
        {
          'id': m.id,
          'chat_id': m.conversationId,
          'sender_id': m.senderId,
          'created_at': m.createdAt.millisecondsSinceEpoch,
          'kind': m.kind,
          'status': _statusToInt(m.status),
          'enc_body': encBody,
          'enc_attachments': encAttachments,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  // Oldest-first list of the most recent `limit` messages for a chat.
  // Matches the in-memory ordering ChatsController uses for display.
  Future<List<Message>> listLatest(String chatId, {int limit = 50}) async {
    final rows = await _db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    final out = <Message>[];
    for (final r in rows) {
      out.add(await _rowToMessage(r));
    }
    return out.reversed.toList();
  }

  // Used by sync: highest-id (== newest) message we already have. Caller
  // hands this to `ListMessages` as `afterId` to fill any gap.
  Future<Message?> latestForChat(String chatId) async {
    final rows = await _db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToMessage(rows.first);
  }

  Future<void> deleteOne(String id) async {
    await _db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateBody(String id, String body) async {
    final encBody = await _ldb.crypto.encryptString(body);
    await _db.update(
      'messages',
      {'enc_body': encBody},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setVoicePlayed(String id) async {
    final rows = await _db.query(
      'messages',
      columns: ['enc_attachments'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final enc = rows.first['enc_attachments'];
    if (enc is! List<int> || enc.isEmpty) return;
    final map = await _ldb.crypto.decryptJson(Uint8List.fromList(enc));
    final v = map['voice'];
    if (v is Map) {
      final cast = v.cast<String, dynamic>();
      cast['played'] = true;
      map['voice'] = cast;
      final reEnc = await _ldb.crypto.encryptJson(map);
      await _db.update(
        'messages',
        {'enc_attachments': reEnc},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<Message> _rowToMessage(Map<String, Object?> r) async {
    String body = '';
    final encBody = r['enc_body'];
    if (encBody is List<int> && encBody.isNotEmpty) {
      try {
        body = await _ldb.crypto.decryptString(Uint8List.fromList(encBody));
      } catch (_) {/* tolerate corrupt row */}
    }
    VoicePayload? voice;
    final encAttach = r['enc_attachments'];
    if (encAttach is List<int> && encAttach.isNotEmpty) {
      try {
        final attach =
            await _ldb.crypto.decryptJson(Uint8List.fromList(encAttach));
        final v = attach['voice'];
        if (v is Map) {
          final m = v.cast<String, dynamic>();
          final peaks = <int>[];
          final rawPeaks = m['peaks'];
          if (rawPeaks is List) {
            for (final p in rawPeaks) {
              if (p is int) peaks.add(p);
              if (p is num) peaks.add(p.toInt());
            }
          }
          voice = VoicePayload(
            fileId: (m['fileId'] as String?) ?? '',
            durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
            peaks: peaks,
            played: (m['played'] as bool?) ?? false,
          );
        }
      } catch (_) {/* tolerate corrupt attachments */}
    }
    return Message(
      id: r['id'] as String,
      conversationId: r['chat_id'] as String,
      senderId: (r['sender_id'] as String?) ?? '',
      body: body,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch((r['created_at'] as int?) ?? 0),
      status: _intToStatus((r['status'] as int?) ?? 1),
      kind: (r['kind'] as String?) ?? 'text',
      voice: voice,
    );
  }
}

int _statusToInt(MessageStatus s) {
  switch (s) {
    case MessageStatus.pending:
      return 0;
    case MessageStatus.sent:
      return 1;
    case MessageStatus.read:
      return 2;
    case MessageStatus.failed:
      return 3;
  }
}

MessageStatus _intToStatus(int v) {
  switch (v) {
    case 0:
      return MessageStatus.pending;
    case 2:
      return MessageStatus.read;
    case 3:
      return MessageStatus.failed;
    case 1:
    default:
      return MessageStatus.sent;
  }
}
