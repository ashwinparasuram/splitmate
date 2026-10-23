import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:splitmate/data/db/app_database.dart';
import 'package:splitmate/data/db/migrations.dart';
import 'package:splitmate/domain/models.dart';
import 'package:splitmate/domain/split_calculator.dart';
import 'package:splitmate/sync/change.dart';
import 'package:splitmate/sync/change_log.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/harness.dart';

void main() {
  sqfliteFfiInit();

  test('creates schema v1 with foreign keys and WAL', () async {
    final dir = await Directory.systemTemp.createTemp('sm_db');
    final db = await openAppDatabase(databaseFactoryFfi, p.join(dir.path, 'a.db'));
    expect(await db.getVersion(), kSchemaVersion);
    final fk = await db.rawQuery('PRAGMA foreign_keys');
    expect(fk.first.values.first, 1);
    final mode = await db.rawQuery('PRAGMA journal_mode');
    expect(mode.first.values.first, 'wal');
    final tables = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
        .map((r) => r['name'])
        .toSet();
    expect(
        tables,
        containsAll([
          'users', 'friends', 'groups', 'group_members', 'group_invitations', 'expenses',
          'expense_participants', 'expense_splits', 'settlements', 'activity_logs',
          'sync_devices', 'sync_changes', 'sync_conflicts', 'backup_metadata',
        ]));
    await db.close();
    await dir.delete(recursive: true);
  });

  test('upgrades an existing database without losing data', () async {
    final dir = await Directory.systemTemp.createTemp('sm_db');
    final path = p.join(dir.path, 'a.db');
    var db = await openAppDatabase(databaseFactoryFfi, path);
    await db.insert('app_meta', {'key': 'k', 'value': 'kept'});
    await db.close();

    final next = {
      ...migrations,
      2: ['ALTER TABLE expenses ADD COLUMN tag TEXT'],
    };
    db = await openAppDatabase(databaseFactoryFfi, path, targetVersion: 2, migrationSet: next);
    expect(await db.getVersion(), 2);
    expect((await db.query('app_meta')).first['value'], 'kept');
    final cols = (await db.rawQuery('PRAGMA table_info(expenses)')).map((r) => r['name']);
    expect(cols, contains('tag'));
    await db.close();

    // Opening a newer database with an older app must fail, not corrupt it.
    await expectLater(openAppDatabase(databaseFactoryFfi, path), throwsA(anything));
    await dir.delete(recursive: true);
  });

  test('referential integrity is enforced', () async {
    final d = await TestDevice.create('alice');
    await expectLater(
      d.db.insert('expense_splits', {'expense_id': 'nope', 'user_id': d.userId, 'owed_minor': 1}),
      throwsA(isA<DatabaseException>()),
    );
    await d.dispose();
  });

  test('a failing step rolls back the whole financial transaction', () async {
    final d = await TestDevice.create('alice');
    final g = await d.repo.createGroup('Trip', 'INR');
    final before = await d.db.rawQuery('SELECT COUNT(*) n FROM sync_changes');
    await expectLater(
      d.log.transaction((txn) async {
        await d.log.append(txn,
            type: EntityType.expense,
            entityId: '11111111-1111-4111-8111-111111111111',
            groupId: g,
            data: ExpenseDraft(
              groupId: g,
              description: 'Dinner',
              amountMinor: 1000,
              currency: 'INR',
              payerId: d.userId,
              splitType: SplitType.equal,
              participants: [SplitInput(d.userId)],
              expenseDate: 0,
            ).toData());
        throw StateError('boom');
      }),
      throwsStateError,
    );
    final after = await d.db.rawQuery('SELECT COUNT(*) n FROM sync_changes');
    expect(after.first['n'], before.first['n']);
    expect(await d.repo.expenses(groupId: g), isEmpty);
    await d.dispose();
  });

  test('local appends that peers would reject are refused', () async {
    final d = await TestDevice.create('alice');
    final g = await d.repo.createGroup('Trip', 'INR');
    await expectLater(
      d.repo.addExpense(ExpenseDraft(
        groupId: g,
        description: 'Bad',
        amountMinor: 1000,
        currency: 'INR',
        payerId: d.userId,
        splitType: SplitType.exact,
        participants: [SplitInput(d.userId, 999)],
        expenseDate: 0,
      )),
      throwsA(isA<AuthorizationException>()),
    );
    await d.dispose();
  });
}
