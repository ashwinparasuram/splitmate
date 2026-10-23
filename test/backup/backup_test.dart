import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitmate/backup/backup_format.dart';
import 'package:splitmate/backup/backup_service.dart';
import 'package:splitmate/backup/backup_storage.dart';
import 'package:splitmate/domain/models.dart';
import 'package:splitmate/domain/split_calculator.dart';
import 'package:splitmate/identity/identity.dart';

import '../support/harness.dart';

const pass = 'correct horse battery';

ExpenseDraft draft(String g, String payer, int amount, List<String> people) => ExpenseDraft(
      groupId: g,
      description: 'Taxi',
      amountMinor: amount,
      currency: 'INR',
      payerId: payer,
      splitType: SplitType.equal,
      participants: [for (final p in people) SplitInput(p)],
      expenseDate: 1700000000000,
    );

BackupService svc(TestDevice d, [InMemorySecretStore? store]) => BackupService(
    repo: d.repo, identityStore: IdentityStore(store ?? InMemorySecretStore()), kdf: KdfParams.testing);

/// Storage double that can simulate every failure mode.
class FlakyStorage implements BackupStorage {
  final files = <String, Uint8List>{};
  BackupStorageError? failNext;
  bool truncateDownloads = false;

  @override
  String get label => 'flaky';

  void _maybeFail() {
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw BackupStorageException(f, f.name);
    }
  }

  @override
  Future<List<RemoteBackup>> list() async {
    _maybeFail();
    return [
      for (final e in files.entries)
        RemoteBackup(id: e.key, name: e.key, sizeBytes: e.value.length, createdAt: DateTime(2026)),
    ];
  }

  @override
  Future<RemoteBackup> upload(String name, Uint8List bytes) async {
    _maybeFail();
    files[name] = bytes;
    return RemoteBackup(id: name, name: name, sizeBytes: bytes.length, createdAt: DateTime(2026));
  }

  @override
  Future<Uint8List> download(RemoteBackup b) async {
    _maybeFail();
    final bytes = files[b.id]!;
    return truncateDownloads ? Uint8List.sublistView(bytes, 0, bytes.length ~/ 2) : bytes;
  }

  @override
  Future<void> delete(RemoteBackup b) async => files.remove(b.id);
}

void main() {
  late TestDevice alice, bob;
  late String g;

  setUp(() async {
    alice = await TestDevice.create('alice');
    bob = await TestDevice.create('bob');
    g = await alice.repo.createGroup('Office lunch', 'INR');
    await alice.addMember(g, bob);
    await alice.repo.addExpense(draft(g, alice.userId, 120000, [alice.userId, bob.userId]));
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  test('restore onto a fresh installation adopts the identity and reproduces balances', () async {
    final storage = FlakyStorage();
    final remote = await svc(alice).backupTo(storage, pass);
    expect(await svc(alice).lastBackupAt(), isNotNull);

    final fresh = await TestDevice.create('new-phone');
    final secrets = InMemorySecretStore();
    final report = await svc(fresh, secrets).restore(await storage.download(remote), pass);
    expect(report.mode, RestoreMode.adoptIdentity);
    expect(report.ingest.rejected, 0);
    expect(report.ingest.pending, 0);
    expect(fresh.log.identity.userId, alice.userId);
    expect(fresh.log.identity.deviceId, isNot(alice.identity.deviceId));
    expect((await IdentityStore(secrets).load())!.userId, alice.userId);
    expect(await fresh.balanceFingerprint(g), await alice.balanceFingerprint(g));

    // The restored device can keep authoring changes peers accept.
    await fresh.repo.addExpense(draft(g, alice.userId, 500, [alice.userId, bob.userId]));
    await bob.trust(fresh);
    final r = await bob.pullFrom(fresh, g);
    expect(r.rejected, 0);
    await fresh.dispose();
  });

  test('restore when local data already exists merges and keeps newer local changes', () async {
    final bytes = await svc(alice).createBackupBytes(pass);
    await alice.repo.addExpense(draft(g, alice.userId, 999, [alice.userId]));
    final before = await alice.balanceFingerprint(g);
    final report = await svc(alice).restore(bytes, pass);
    expect(report.mode, RestoreMode.merge);
    expect(report.ingest.applied, 0);
    expect((await alice.repo.expenses(groupId: g)).length, 2, reason: 'nothing overwritten');
    expect(await alice.balanceFingerprint(g), before);
  });

  test("restoring someone else's backup over existing data is refused", () async {
    final bytes = await svc(alice).createBackupBytes(pass);
    await bob.repo.createGroup('Mine', 'INR');
    await expectLater(svc(bob).restore(bytes, pass), throwsA(isA<RestoreConflictException>()));
  });

  test('wrong passphrase, corruption, truncation and tampered headers are rejected', () async {
    final bytes = await svc(alice).createBackupBytes(pass);
    await expectLater(svc(alice).open(bytes, 'wrong passphrase'),
        throwsA(isA<BackupFormatException>().having((e) => e.wrongKeyOrCorrupt, 'wrongKey', true)));

    final flipped = Uint8List.fromList(bytes)..[bytes.length - 40] ^= 0x01;
    await expectLater(svc(alice).open(flipped, pass), throwsA(isA<BackupFormatException>()));

    final truncated = Uint8List.sublistView(bytes, 0, bytes.length - 100);
    await expectLater(svc(alice).open(truncated, pass), throwsA(isA<BackupFormatException>()));

    // Tamper with the checksum recorded in the header: AAD makes it fail.
    final header = BackupCodec.readHeader(bytes);
    final json = Map.of(header.json)..['payload_sha256'] = '0' * 64;
    final newHeader = utf8.encode(jsonEncode(json));
    final rebuilt = BytesBuilder()
      ..add(bytes.sublist(0, 5))
      ..add((ByteData(4)..setUint32(0, newHeader.length)).buffer.asUint8List())
      ..add(newHeader)
      ..add(bytes.sublist(9 + header.bytes.length));
    await expectLater(svc(alice).open(rebuilt.takeBytes(), pass), throwsA(isA<BackupFormatException>()));

    await expectLater(svc(alice).open(Uint8List.fromList(utf8.encode('hello')), pass),
        throwsA(isA<BackupFormatException>()));
    // Nothing was touched by any failed attempt.
    expect((await alice.repo.expenses(groupId: g)).length, 1);
  });

  test('storage failures surface clearly and never affect local data', () async {
    final storage = FlakyStorage();
    for (final kind in [
      BackupStorageError.unavailable,
      BackupStorageError.authExpired,
      BackupStorageError.uploadFailed,
    ]) {
      storage.failNext = kind;
      await expectLater(svc(alice).backupTo(storage, pass),
          throwsA(isA<BackupStorageException>().having((e) => e.kind, 'kind', kind)));
    }
    expect(storage.files, isEmpty);
    expect(await svc(alice).lastBackupAt(), isNull);

    final remote = await svc(alice).backupTo(storage, pass);
    storage.truncateDownloads = true;
    final partial = await storage.download(remote);
    final fresh = await TestDevice.create('phone');
    await expectLater(svc(fresh).restore(partial, pass), throwsA(isA<BackupFormatException>()));
    expect(await fresh.repo.groups(), isEmpty);
    await fresh.dispose();
  });

  test('snapshot is consistent while writes are in flight', () async {
    final writes = <Future<void>>[];
    final snaps = <Future<Uint8List>>[];
    for (var i = 0; i < 10; i++) {
      writes.add(alice.repo.addExpense(draft(g, alice.userId, 100 + i, [alice.userId, bob.userId])));
      snaps.add(svc(alice).createBackupBytes(pass));
    }
    await Future.wait(writes);
    for (final s in await Future.wait(snaps)) {
      final fresh = await TestDevice.create('snap');
      final r = await svc(fresh).restore(s, pass);
      expect(r.ingest.pending, 0, reason: 'no dangling parents in a snapshot');
      expect(r.ingest.rejected, 0);
      await fresh.dispose();
    }
  });

  test('local folder storage writes atomically and lists newest first', () async {
    final dir = await Directory.systemTemp.createTemp('sm_backups');
    final storage = LocalFolderBackupStorage(dir);
    await svc(alice).backupTo(storage, pass);
    final list = await storage.list();
    expect(list.single.name, endsWith('.smbk'));
    expect(dir.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    await storage.delete(list.single);
    expect(await storage.list(), isEmpty);
    await dir.delete(recursive: true);
  });
}
