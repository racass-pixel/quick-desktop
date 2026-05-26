// Outbox DAO. Persists unsent messages so a crash/reboot doesn't lose them.
// The payload column is JSON (encrypted) and intentionally schema-loose — we
// only care about the chat_id, local_id, and creation order.

import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'db.dart';

class OutboxEntry {
  OutboxEntry({
    required this.localId,
    required this.chatId,
    required this.payload,
    required this.createdAt,
    this.attemptCount = 0,
    this.lastError,
  });

  final String localId;
  final String chatId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int attemptCount;
  final String? lastError;
}

class OutboxDao {
  OutboxDao(this._ldb);
  final LocalDb _ldb;
  Database get _db => _ldb.db;

  Future<void> enqueue(OutboxEntry e) async {
    final encPayload = await _ldb.crypto.encryptString(jsonEncode(e.payload));
    await _db.insert(
      'outbox',
      {
        'local_id': e.localId,
        'chat_id': e.chatId,
        // payload_json column is TEXT for ease of inspection; we store the
        // base64 of the encrypted bytes (caveat: still encrypted).
        'payload_json': _b64(encPayload),
        'created_at': e.createdAt.millisecondsSinceEpoch,
        'attempt_count': e.attemptCount,
        'last_error': e.lastError,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> dequeue(String localId) async {
    await _db.delete(
      'outbox',
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<void> bumpAttempt(String localId, String? error) async {
    await _db.rawUpdate(
      '''
      UPDATE outbox
      SET attempt_count = attempt_count + 1,
          last_error = ?
      WHERE local_id = ?
      ''',
      [error, localId],
    );
  }

  Future<List<OutboxEntry>> listForChat(String chatId) async {
    final rows = await _db.query(
      'outbox',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at ASC',
    );
    return _rowsTo(rows);
  }

  Future<List<OutboxEntry>> listAll() async {
    final rows = await _db.query(
      'outbox',
      orderBy: 'created_at ASC',
    );
    return _rowsTo(rows);
  }

  Future<List<OutboxEntry>> _rowsTo(List<Map<String, Object?>> rows) async {
    final out = <OutboxEntry>[];
    for (final r in rows) {
      Map<String, dynamic> payload = const {};
      final raw = r['payload_json'] as String?;
      if (raw != null && raw.isNotEmpty) {
        try {
          final enc = _unB64(raw);
          final json = await _ldb.crypto.decryptString(enc);
          final decoded = jsonDecode(json);
          if (decoded is Map) {
            payload = decoded.cast<String, dynamic>();
          }
        } catch (_) {/* tolerate corrupt entry */}
      }
      out.add(
        OutboxEntry(
          localId: r['local_id'] as String,
          chatId: r['chat_id'] as String,
          payload: payload,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
              (r['created_at'] as int?) ?? 0),
          attemptCount: (r['attempt_count'] as int?) ?? 0,
          lastError: r['last_error'] as String?,
        ),
      );
    }
    return out;
  }
}

String _b64(Uint8List bytes) => base64Encode(bytes);
Uint8List _unB64(String s) => base64Decode(s);
