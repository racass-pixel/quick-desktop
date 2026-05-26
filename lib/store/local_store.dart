// Facade over the open `LocalDb` + DAOs. Held as a Riverpod provider so any
// code path can read-through the cache and write-through on update without
// having to thread a LocalDb instance around. All methods are best-effort —
// failures swallow with a debug log so the network path is never blocked by
// the local store.
//
// Lifecycle: `boot(token)` is called once from `AuthController.bootstrap` /
// `onVerified` after the session token is known. `shutdown()` is called on
// sign-out before clearing the secure-storage token; `wipe()` does the same
// then deletes the file.

import 'dart:async';
// ignore: unused_import — used for debugPrint via debug builds
import 'package:flutter/foundation.dart';

import '../api/dto.dart';
import 'chats_dao.dart';
import 'db.dart';
import 'messages_dao.dart';
import 'media_dao.dart';
import 'outbox_dao.dart';
import 'users_dao.dart';

class LocalStore {
  LocalStore._(this.ldb, this.users, this.chats, this.messages, this.media,
      this.outbox);

  final LocalDb ldb;
  final UsersDao users;
  final ChatsDao chats;
  final MessagesDao messages;
  final MediaDao media;
  final OutboxDao outbox;

  static LocalStore? _instance;
  static Future<LocalStore>? _opening;

  static LocalStore? get instanceOrNull => _instance;

  static Future<LocalStore> boot(String sessionToken) async {
    if (_instance != null) return _instance!;
    if (_opening != null) return _opening!;
    final c = Completer<LocalStore>();
    _opening = c.future;
    try {
      final ldb = await LocalDb.open(sessionToken);
      final store = LocalStore._(
        ldb,
        UsersDao(ldb),
        ChatsDao(ldb),
        MessagesDao(ldb),
        MediaDao(ldb),
        OutboxDao(ldb),
      );
      _instance = store;
      c.complete(store);
      return store;
    } catch (e, st) {
      c.completeError(e, st);
      rethrow;
    } finally {
      _opening = null;
    }
  }

  static Future<void> shutdown() async {
    final i = _instance;
    _instance = null;
    if (i != null) await i.ldb.close();
  }

  // Sign-out path. Closes the DB and deletes the file so a future sign-in
  // with a different account starts from a clean slate.
  static Future<void> wipe() async {
    final i = _instance;
    _instance = null;
    if (i != null) {
      await i.ldb.wipe();
    } else {
      // Re-open just to wipe — needed when caller doesn't have a token but
      // wants to nuke leftover data. Skipped on null: nothing to wipe.
    }
  }

  // ------------- conversation helpers ---------------------------------------

  Future<List<Conversation>> hydrateConvs() async {
    try {
      return await chats.listAll();
    } catch (e) {
      // ignore: avoid_print
      debugPrint('[store] hydrateConvs failed: $e');
      return const [];
    }
  }

  Future<void> persistConvs(Iterable<Conversation> convs) async {
    try {
      await chats.upsertAll(convs);
      // Mirror peer users into the users table for future lookups.
      final peers = <User>[];
      for (final c in convs) {
        if (c.peer != null) peers.add(c.peer!);
      }
      if (peers.isNotEmpty) {
        await users.upsertAll(peers);
      }
    } catch (e) {
      debugPrint('[store] persistConvs failed: $e');
    }
  }

  Future<void> persistConv(Conversation c) async {
    try {
      await chats.upsert(c);
      if (c.peer != null) await users.upsert(c.peer!);
    } catch (e) {
      debugPrint('[store] persistConv failed: $e');
    }
  }

  // ------------- message helpers --------------------------------------------

  Future<List<Message>> hydrateMessages(String chatId, {int limit = 50}) async {
    try {
      return await messages.listLatest(chatId, limit: limit);
    } catch (e) {
      debugPrint('[store] hydrateMessages($chatId) failed: $e');
      return const [];
    }
  }

  Future<Message?> latestForChat(String chatId) async {
    try {
      return await messages.latestForChat(chatId);
    } catch (_) {
      return null;
    }
  }

  Future<void> persistMessages(Iterable<Message> msgs) async {
    try {
      await messages.upsertAll(msgs);
    } catch (e) {
      debugPrint('[store] persistMessages failed: $e');
    }
  }

  Future<void> persistMessage(Message m) async {
    try {
      await messages.upsert(m);
    } catch (e) {
      debugPrint('[store] persistMessage failed: $e');
    }
  }

  Future<void> deleteMessage(String id) async {
    try {
      await messages.deleteOne(id);
    } catch (_) {/* best effort */}
  }
}
