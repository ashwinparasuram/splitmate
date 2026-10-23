import 'package:sqflite_common/sqlite_api.dart';

import 'migrations.dart';

/// Opens (creating or migrating) the SplitMate database.
///
/// [factory] is `databaseFactory` from sqflite on device and
/// `databaseFactoryFfi` in host tests.
Future<Database> openAppDatabase(
  DatabaseFactory factory,
  String path, {
  int targetVersion = kSchemaVersion,
  Map<int, List<String>>? migrationSet,
}) {
  final set = migrationSet ?? migrations;
  Future<void> migrate(Database db, int from, int to) async {
    for (var v = from + 1; v <= to; v++) {
      final steps = set[v];
      if (steps == null) throw StateError('Missing migration for schema v$v');
      for (final sql in steps) {
        await db.execute(sql);
      }
    }
  }

  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: targetVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        // WAL gives readers a consistent snapshot while a writer is active,
        // which the backup exporter relies on.
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
      onCreate: (db, version) => migrate(db, 0, version),
      onUpgrade: migrate,
      onDowngrade: (db, from, to) => throw StateError(
          'Database schema v$from is newer than this app (v$to). Update the app.'),
    ),
  );
}
