import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../data/db/migrations.dart';
import '../data/ledger_repository.dart';
import '../identity/identity.dart';
import '../sync/change.dart';
import '../sync/change_log.dart';
import 'backup_format.dart';
import 'backup_storage.dart';

const String kAppVersion = '1.0.0';

enum RestoreMode {
  /// Empty device: the backup's identity is adopted (with a new device id).
  adoptIdentity,

  /// Same identity: merge, keeping anything that only exists locally.
  merge,
}

class RestoreConflictException implements Exception {
  RestoreConflictException(this.message);
  final String message;
  @override
  String toString() => message;
}

class RestoreReport {
  RestoreReport(this.mode, this.ingest, this.header);
  final RestoreMode mode;
  final IngestReport ingest;
  final BackupHeader header;
}

/// Builds encrypted snapshots and merges them back. See docs/DESIGN.md §10.
class BackupService {
  BackupService({required this.repo, required this.identityStore, this.kdf = const KdfParams()});

  final LedgerRepository repo;
  final IdentityStore identityStore;
  final KdfParams kdf;

  ChangeLog get log => repo.log;

  /// Consistent snapshot: every table is read inside one SQLite transaction,
  /// so under WAL it is a single point-in-time view. The live database file
  /// is never copied.
  Future<Map<String, Object?>> snapshot() async {
    final seeds = await log.identity.exportSeeds();
    return log.db.transaction((txn) async {
      final changes = await txn.query('sync_changes', orderBy: 'origin_device_id, origin_seq');
      final users = await txn.rawQuery('''
        SELECT * FROM users WHERE is_local = 0 AND (
          id IN (SELECT user_id FROM friends) OR id IN (SELECT user_id FROM sync_devices))''');
      return {
        'schema_version': kSchemaVersion,
        'identity': {
          'user_id': log.identity.userId,
          'display_name': log.identity.displayName,
          'ed25519_seed': b64(seeds.signing),
          'x25519_seed': b64(seeds.agreement),
        },
        'sync_changes': [
          for (final c in changes)
            {
              'wire': SyncChange.fromRow(c).toWire(),
              'is_local': c['is_local'],
            },
        ],
        'users': users,
        'friends': await txn.query('friends'),
        'sync_devices': await txn.query('sync_devices'),
        'meta': await txn.query('app_meta', where: "key LIKE 'consent:%'"),
        'dismissed_conflicts': await txn.query('sync_conflicts',
            columns: ['entity_type', 'entity_id', 'kind'], where: "resolution = 'kept_both'"),
      };
    });
  }

  Future<Uint8List> createBackupBytes(String passphrase) async {
    final payload = await snapshot();
    return BackupCodec.encode(
      payload: payload,
      passphrase: passphrase,
      kdf: kdf,
      headerFields: {
        'schema_version': kSchemaVersion,
        'app_version': kAppVersion,
        'created_at': log.now(),
        'user_id': log.identity.userId,
        'display_name': log.identity.displayName,
        'device_id': log.identity.deviceId,
        'change_count': (payload['sync_changes']! as List).length,
      },
    );
  }

  Future<RemoteBackup> backupTo(BackupStorage storage, String passphrase) async {
    final bytes = await createBackupBytes(passphrase);
    final header = BackupCodec.readHeader(bytes);
    final stamp = DateTime.fromMillisecondsSinceEpoch(log.now(), isUtc: true)
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final remote = await storage.upload('splitmate-$stamp.smbk', bytes);
    await _record('backup', storage.label, remote.id, remote.name, bytes.length, header);
    return remote;
  }

  /// Whether this device has nothing that a restore could clash with.
  Future<bool> isFreshDevice() async {
    final r = await log.db.rawQuery('SELECT COUNT(*) n FROM sync_changes');
    final f = await log.db.rawQuery('SELECT COUNT(*) n FROM friends');
    return (r.first['n']! as int) == 0 && (f.first['n']! as int) == 0;
  }

  /// Decrypts and validates without touching the database.
  Future<(BackupHeader, Map<String, Object?>)> open(Uint8List bytes, String passphrase) async {
    final header = BackupCodec.readHeader(bytes);
    if (header.schemaVersion > kSchemaVersion) {
      throw BackupFormatException('This backup was made by a newer version of SplitMate. Update the app first.');
    }
    final payload = await BackupCodec.decode(bytes, passphrase);
    return (header, payload);
  }

  /// Restores by *merging*: changes are ingested through the normal
  /// validation path, and nothing local is ever overwritten.
  Future<RestoreReport> restore(Uint8List bytes, String passphrase, {String source = 'file'}) async {
    final (header, payload) = await open(bytes, passphrase);
    final identity = (payload['identity']! as Map).cast<String, Object?>();
    final backupUser = identity['user_id']! as String;

    RestoreMode mode;
    if (backupUser == log.identity.userId) {
      mode = RestoreMode.merge;
    } else if (await isFreshDevice()) {
      mode = RestoreMode.adoptIdentity;
    } else {
      throw RestoreConflictException(
          'This backup belongs to "${identity['display_name']}", but this device already has '
          'data for "${log.identity.displayName}". To restore it, reset the app first '
          '(Settings → Privacy → Delete all data).');
    }

    if (mode == RestoreMode.adoptIdentity) {
      final adopted = await LocalIdentity.fromSeeds(
        userId: backupUser,
        deviceId: const Uuid().v4(), // a new installation is a new device
        displayName: identity['display_name']! as String,
        signingSeed: unb64(identity['ed25519_seed']! as String),
        agreementSeed: unb64(identity['x25519_seed']! as String),
      );
      final oldUser = log.identity.userId;
      await identityStore.save(adopted);
      await log.db.transaction((txn) async {
        await txn.delete('users', where: 'id = ? AND is_local = 1', whereArgs: [oldUser]);
        await txn.delete('app_meta', where: "key IN ('device_seq', 'hlc_last')");
      });
      await log.resetIdentity(adopted);
      await repo.ensureLocalUser();
    }

    final db = log.db;
    await db.transaction((txn) async {
      for (final u in (payload['users'] as List? ?? const [])) {
        await txn.insert('users', (u as Map).cast<String, Object?>(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final d in (payload['sync_devices'] as List? ?? const [])) {
        await txn.insert('sync_devices', (d as Map).cast<String, Object?>(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final f in (payload['friends'] as List? ?? const [])) {
        await txn.insert('friends', (f as Map).cast<String, Object?>(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final m in (payload['meta'] as List? ?? const [])) {
        await txn.insert('app_meta', (m as Map).cast<String, Object?>(),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });

    final changes = <SyncChange>[];
    var malformed = 0;
    for (final c in (payload['sync_changes'] as List? ?? const [])) {
      try {
        changes.add(SyncChange.fromWire((c as Map)['wire']));
      } on FormatException {
        malformed++;
      }
    }
    final report = await log.ingest(changes);
    report.rejected += malformed;

    for (final d in (payload['dismissed_conflicts'] as List? ?? const [])) {
      final m = (d as Map).cast<String, Object?>();
      await db.update('sync_conflicts', {'resolved_at': log.now(), 'resolution': 'kept_both'},
          where: 'entity_type = ? AND entity_id = ? AND kind = ? AND resolved_at IS NULL',
          whereArgs: [m['entity_type'], m['entity_id'], m['kind']]);
    }
    await _record('restore', source, null, 'restore', bytes.length, header);
    repo.notifyChanged();
    return RestoreReport(mode, report, header);
  }

  Future<void> _record(String direction, String location, String? remoteId, String name, int size,
      BackupHeader header) async {
    await log.db.insert('backup_metadata', {
      'id': const Uuid().v4(),
      'direction': direction,
      'location': location,
      'remote_id': remoteId,
      'file_name': name,
      'size_bytes': size,
      'payload_sha256': header.payloadSha256,
      'schema_version': header.schemaVersion,
      'format_version': header.formatVersion,
      'created_at': log.now(),
    });
  }

  Future<int?> lastBackupAt() async {
    final r = await log.db.query('backup_metadata',
        columns: ['created_at'], where: "direction = 'backup'", orderBy: 'created_at DESC', limit: 1);
    return r.isEmpty ? null : r.first['created_at']! as int;
  }
}
