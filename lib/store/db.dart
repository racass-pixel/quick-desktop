// LocalDb singleton. Owns the sqflite_common_ffi Database handle, the
// associated StoreCrypto, and the on-disk file path. Open once at boot
// (after the session token is known) and pass via Riverpod to the DAOs.

import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'crypto.dart';
import 'schema.dart';

class LocalDb {
  LocalDb._(this.db, this.crypto, this.dbPath);

  final Database db;
  final StoreCrypto crypto;
  final String dbPath;

  static LocalDb? _instance;
  static Future<LocalDb>? _opening;

  static LocalDb? get instanceOrNull => _instance;

  // Open the per-session DB. The crypto key is derived from `sessionToken` so
  // switching accounts produces a different key and old rows fail to decrypt
  // (caller should wipe before opening with a new token; see `wipe`).
  static Future<LocalDb> open(String sessionToken) async {
    if (_instance != null) return _instance!;
    if (_opening != null) return _opening!;
    final completer = Completer<LocalDb>();
    _opening = completer.future;
    try {
      sqfliteFfiInit();
      final factory = databaseFactoryFfi;
      final dir = await _appSupportDir();
      final dbPath = '${dir.path}${Platform.pathSeparator}$kDbFileName';

      Database db;
      try {
        db = await factory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: kSchemaVersion,
            onConfigure: (d) async {
              await d.execute('PRAGMA journal_mode=WAL');
              await d.execute('PRAGMA foreign_keys=ON');
            },
            onCreate: (d, v) async {
              await applySchema(d);
            },
            onUpgrade: (d, from, to) async {
              await migrate(d, from, to);
              await applySchema(d);
            },
          ),
        );
      } catch (e) {
        // Corrupt file — quarantine and retry with a fresh DB.
        await _quarantine(dbPath);
        db = await factory.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: kSchemaVersion,
            onConfigure: (d) async {
              await d.execute('PRAGMA journal_mode=WAL');
              await d.execute('PRAGMA foreign_keys=ON');
            },
            onCreate: (d, v) async {
              await applySchema(d);
            },
          ),
        );
      }

      final crypto = await StoreCrypto.fromSessionToken(sessionToken);
      final inst = LocalDb._(db, crypto, dbPath);
      _instance = inst;
      completer.complete(inst);
      return inst;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _opening = null;
    }
  }

  // Close the handle. Call on sign-out before `wipe`.
  Future<void> close() async {
    try {
      await db.close();
    } catch (_) {/* ignore */}
    if (identical(_instance, this)) _instance = null;
  }

  // Delete the on-disk database (used on sign-out / account switch).
  Future<void> wipe() async {
    await close();
    final f = File(dbPath);
    if (await f.exists()) {
      try {
        await f.delete();
      } catch (_) {/* swallow — best effort */}
    }
    // sqflite also writes -wal and -shm sidecars
    for (final suffix in const ['-wal', '-shm', '-journal']) {
      final side = File('$dbPath$suffix');
      if (await side.exists()) {
        try {
          await side.delete();
        } catch (_) {/* ignore */}
      }
    }
  }

  static Future<Directory> _appSupportDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}quick',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> _quarantine(String path) async {
    final f = File(path);
    if (!await f.exists()) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dst = '$path.corrupt-$ts';
    try {
      await f.rename(dst);
    } catch (_) {
      // If rename fails (e.g. file locked), try copy + delete
      try {
        await f.copy(dst);
        await f.delete();
      } catch (_) {/* give up — open will likely still fail */}
    }
  }
}
