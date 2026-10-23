import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:splitmate/data/db/app_database.dart';
import 'package:splitmate/data/ledger_repository.dart';
import 'package:splitmate/identity/identity.dart';
import 'package:splitmate/sync/change.dart';
import 'package:splitmate/sync/change_log.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A simulated device with its own on-disk SQLite database and identity.
class TestDevice {
  TestDevice._(this.name, this.dir, this.identity, this.db, this.log, this.repo);

  final String name;
  final Directory dir;
  final LocalIdentity identity;
  final Database db;
  final ChangeLog log;
  final LedgerRepository repo;

  String get userId => identity.userId;

  static Future<TestDevice> create(String name,
      {LocalIdentity? identity, int Function()? now}) async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('splitmate_$name');
    final id = identity ?? await LocalIdentity.generate(name);
    final db = await openAppDatabase(databaseFactoryFfi, p.join(dir.path, 'ledger.db'));
    final log = ChangeLog(db, id, now: now);
    await log.init();
    final repo = LedgerRepository(log);
    await repo.ensureLocalUser();
    return TestDevice._(name, dir, id, db, log, repo);
  }

  Future<void> dispose() async {
    await db.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// Every stored change of a group (what a peer would send on full sync).
  Future<List<SyncChange>> allChanges(String groupId) => log.missingFor(groupId, const {});

  /// Simulated one-way sync of one group.
  Future<IngestReport> pullFrom(TestDevice other, String groupId) async {
    final mine = await log.vectorFor(groupId);
    final missing = await other.log.missingFor(groupId, mine);
    final r = await log.ingest(missing);
    repo.notifyChanged();
    return r;
  }

  /// Simulated bidirectional sync of one group.
  Future<void> syncWith(TestDevice other, String groupId) async {
    await pullFrom(other, groupId);
    await other.pullFrom(this, groupId);
  }

  /// Registers [other] as a paired device (what pairing does).
  Future<void> trust(TestDevice other) async {
    await db.insert(
        'users',
        {
          'id': other.userId,
          'display_name': other.name,
          'ed25519_pub': other.identity.ed25519Pub,
          'x25519_pub': other.identity.x25519Pub,
          'is_local': 0,
          'created_at': 0,
          'updated_at': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.insert(
        'sync_devices',
        {
          'device_id': other.identity.deviceId,
          'user_id': other.userId,
          'ed25519_pub': other.identity.ed25519Pub,
          'x25519_pub': other.identity.x25519Pub,
          'display_name': other.name,
          'paired_at': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Adds [other] as a verified member of [groupId] on this (admin) device.
  Future<void> addMember(String groupId, TestDevice other, {String role = 'member'}) async {
    await trust(other);
    await other.trust(this);
    await repo.addVerifiedMember(groupId,
        userId: other.userId,
        displayName: other.name,
        ed25519Pub: other.identity.ed25519Pub,
        x25519Pub: other.identity.x25519Pub,
        role: role);
  }

  /// Balance snapshot that must be identical across converged devices.
  Future<String> balanceFingerprint(String groupId) async {
    final b = await repo.balances(groupId: groupId);
    final nets = b.nets();
    final keys = nets.keys.toList()..sort();
    return keys.map((k) {
      final m = nets[k]!;
      final c = m.keys.toList()..sort();
      return '$k:${c.map((x) => '$x=${m[x]}').join(',')}';
    }).join('|');
  }
}
