// tdata schema. Telegram-style local store with encrypted blob columns and
// plain scalar columns for indexing/ordering. Bump kSchemaVersion + register
// a migration when shapes change.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const int kSchemaVersion = 1;

const String kDbFileName = 'tdata.db';

// ---- DDL -------------------------------------------------------------------

const String _ddlUsers = '''
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  handle TEXT,
  display_name TEXT,
  avatar_color TEXT,
  presence_seen_at INTEGER,
  enc_blob BLOB
)
''';

const String _ddlChats = '''
CREATE TABLE IF NOT EXISTS chats (
  id TEXT PRIMARY KEY,
  kind TEXT,
  last_message_at INTEGER,
  last_message_id TEXT,
  unread_count INTEGER DEFAULT 0,
  pinned_at INTEGER,
  enc_blob BLOB
)
''';

const String _ddlChatMembers = '''
CREATE TABLE IF NOT EXISTS chat_members (
  chat_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT,
  joined_at INTEGER,
  PRIMARY KEY (chat_id, user_id)
)
''';

const String _ddlMessages = '''
CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  sender_id TEXT,
  created_at INTEGER NOT NULL,
  kind TEXT,
  status INTEGER DEFAULT 1,
  enc_body BLOB,
  enc_attachments BLOB
)
''';

const String _idxMessagesChatTime =
    'CREATE INDEX IF NOT EXISTS idx_messages_chat_time '
    'ON messages (chat_id, created_at DESC)';

const String _ddlMediaCache = '''
CREATE TABLE IF NOT EXISTS media_cache (
  file_id TEXT PRIMARY KEY,
  local_path TEXT NOT NULL,
  mime TEXT,
  size_bytes INTEGER,
  cached_at INTEGER NOT NULL
)
''';

const String _ddlOutbox = '''
CREATE TABLE IF NOT EXISTS outbox (
  local_id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  attempt_count INTEGER DEFAULT 0,
  last_error TEXT
)
''';

const String _idxOutboxChatTime =
    'CREATE INDEX IF NOT EXISTS idx_outbox_chat_time '
    'ON outbox (chat_id, created_at ASC)';

// ---- Apply / migrate -------------------------------------------------------

Future<void> applySchema(Database db) async {
  await db.execute(_ddlUsers);
  await db.execute(_ddlChats);
  await db.execute(_ddlChatMembers);
  await db.execute(_ddlMessages);
  await db.execute(_idxMessagesChatTime);
  await db.execute(_ddlMediaCache);
  await db.execute(_ddlOutbox);
  await db.execute(_idxOutboxChatTime);
}

Future<void> migrate(Database db, int fromVersion, int toVersion) async {
  // No migrations yet — all v1. Future bumps register here.
  // Example:
  // if (fromVersion < 2) {
  //   await db.execute('ALTER TABLE messages ADD COLUMN reactions BLOB');
  // }
}
