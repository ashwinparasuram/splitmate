import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import '../backup/backup_service.dart';
import '../data/db/app_database.dart';
import '../data/ledger_repository.dart';
import '../identity/identity.dart';
import '../sync/change_log.dart';
import '../sync/pairing.dart';
import '../sync/sync_bundle.dart';
import 'sync_controller.dart';

/// Platform secure storage: Android Keystore-backed encrypted preferences,
/// iOS Keychain (this device only, after first unlock so sync can run).
class PlatformSecretStore implements SecretStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Everything the UI needs, created once the local identity exists.
class AppServices {
  AppServices._({
    required this.identityStore,
    required this.log,
    required this.repo,
    required this.pairing,
    required this.bundles,
    required this.backup,
    required this.sync,
    required this.documentsDir,
  });

  /// Platform secure storage for small secrets (e.g. the opt-in scheduled
  /// backup passphrase). Never written to SQLite or to a backup.
  final SecretStore secrets = PlatformSecretStore();
  final IdentityStore identityStore;
  final ChangeLog log;
  final LedgerRepository repo;
  final PairingService pairing;
  final BundleService bundles;
  final BackupService backup;
  final SyncController sync;
  final Directory documentsDir;

  static Future<String> databasePath() async =>
      p.join(await sqflite.getDatabasesPath(), 'splitmate.db');

  static Future<AppServices> open(LocalIdentity identity, IdentityStore store) async {
    final db = await openAppDatabase(sqflite.databaseFactory, await databasePath());
    final log = ChangeLog(db, identity);
    await log.init();
    final repo = LedgerRepository(log);
    await repo.ensureLocalUser();
    final pairing = PairingService(repo);
    return AppServices._(
      identityStore: store,
      log: log,
      repo: repo,
      pairing: pairing,
      bundles: BundleService(log),
      backup: BackupService(repo: repo, identityStore: store),
      sync: SyncController(repo: repo, pairing: pairing),
      documentsDir: await getApplicationDocumentsDirectory(),
    );
  }

  Directory get receiptsDir => Directory(p.join(documentsDir.path, 'receipts'));

  /// Wipes everything on this device: database, receipts and private keys.
  Future<void> deleteAllData() async {
    await sync.stopHosting();
    await log.db.close();
    await sqflite.deleteDatabase(await databasePath());
    if (await receiptsDir.exists()) await receiptsDir.delete(recursive: true);
    await identityStore.clear();
    await secrets.delete('backup.passphrase');
  }
}
