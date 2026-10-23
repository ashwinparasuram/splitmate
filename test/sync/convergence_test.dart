import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitmate/core/hlc.dart';
import 'package:splitmate/domain/models.dart';
import 'package:splitmate/domain/split_calculator.dart';
import 'package:splitmate/identity/identity.dart';
import 'package:splitmate/sync/change.dart';
import 'package:splitmate/sync/change_log.dart';
import 'package:uuid/uuid.dart';

import '../support/harness.dart';

ExpenseDraft draft(String groupId, String payer, int amount, List<String> people,
        {String description = 'Dinner', String? notes, SplitType type = SplitType.equal}) =>
    ExpenseDraft(
      groupId: groupId,
      description: description,
      amountMinor: amount,
      currency: 'INR',
      payerId: payer,
      splitType: type,
      participants: [for (final p in people) SplitInput(p, type == SplitType.equal ? 0 : 1)],
      expenseDate: 1700000000000,
      notes: notes,
    );

void main() {
  late TestDevice alice, bob, carol;
  late String g;

  setUp(() async {
    alice = await TestDevice.create('alice');
    bob = await TestDevice.create('bob');
    carol = await TestDevice.create('carol');
    g = await alice.repo.createGroup('Goa trip', 'INR');
    await alice.addMember(g, bob);
    await alice.addMember(g, carol);
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await carol.dispose();
  });

  test('initial sync delivers the group and members; invite needs consent', () async {
    final r = await bob.pullFrom(alice, g);
    expect(r.rejected, 0);
    expect(r.pending, 0);
    expect(r.applied, greaterThan(0));
    final groups = await bob.repo.groups();
    expect(groups.single.name, 'Goa trip');
    expect(groups.single.localStatus, 'invited');
    await bob.repo.setGroupConsent(g, true);
    expect((await bob.repo.group(g))!.localStatus, 'active');
    expect((await bob.repo.members(g)).length, 3);
  });

  test('incremental sync and idempotent duplicate delivery', () async {
    await bob.pullFrom(alice, g);
    await alice.repo.addExpense(draft(g, alice.userId, 120000, [alice.userId, bob.userId, carol.userId]));
    final r = await bob.pullFrom(alice, g);
    expect(r.applied, 1);
    // Re-deliver everything: nothing changes.
    final again = await bob.log.ingest(await alice.allChanges(g));
    expect(again.applied, 0);
    expect(again.duplicates, greaterThan(0));
    final bal = await bob.repo.balances(groupId: g);
    expect(bal.owes(bob.userId, alice.userId, 'INR'), 40000);
    expect(bal.netFor(alice.userId), {'INR': 80000});
  });

  test('changes relayed through a third device are accepted (signatures, not transport)', () async {
    await bob.pullFrom(alice, g);
    await carol.pullFrom(alice, g);
    await bob.repo.addExpense(draft(g, bob.userId, 3000, [alice.userId, bob.userId, carol.userId]));
    await carol.pullFrom(bob, g);
    await alice.pullFrom(carol, g); // Alice never talked to Bob directly.
    expect((await alice.repo.expenses(groupId: g)).single.amountMinor, 3000);
  });

  test('out-of-order arrival becomes pending, then applies when parents arrive', () async {
    await bob.pullFrom(alice, g);
    final id = await alice.repo.addExpense(draft(g, alice.userId, 1000, [alice.userId, bob.userId]));
    final e = (await alice.repo.expense(id))!;
    await alice.repo.editExpense(id, draft(g, alice.userId, 2000, [alice.userId, bob.userId]));
    expect(e.amountMinor, 1000);
    final all = await alice.allChanges(g);
    final edit = all.last;
    final create = all[all.length - 2];
    final r1 = await bob.log.ingest([edit]);
    expect(r1.pending, 1);
    expect(await bob.repo.expense(id), isNull);
    final r2 = await bob.log.ingest([create]);
    expect(r2.applied, 1);
    expect((await bob.repo.expense(id))!.amountMinor, 2000);
    expect(await bob.repo.pendingRemoteChanges(), 0);
  });

  test('concurrent financial edits raise a conflict instead of silent last-write-wins', () async {
    await bob.pullFrom(alice, g);
    final id = await alice.repo.addExpense(draft(g, alice.userId, 1000, [alice.userId, bob.userId]));
    await bob.pullFrom(alice, g);
    // Both edit the amount while offline.
    await alice.repo.editExpense(id, draft(g, alice.userId, 1500, [alice.userId, bob.userId]));
    await bob.repo.editExpense(id, draft(g, alice.userId, 1800, [alice.userId, bob.userId]));
    await alice.syncWith(bob, g);

    final ea = (await alice.repo.expense(id))!;
    final eb = (await bob.repo.expense(id))!;
    expect(ea.conflicted, isTrue);
    expect(eb.conflicted, isTrue);
    expect(ea.amountMinor, eb.amountMinor, reason: 'deterministic provisional winner');
    expect(await alice.balanceFingerprint(g), await bob.balanceFingerprint(g));
    final conflicts = await alice.repo.openConflicts();
    expect(conflicts.single.kind, 'concurrent_edit');
    expect(conflicts.single.headIds.length, 2);

    // Bob resolves by choosing Alice's version; the conflict closes everywhere.
    final aliceHead = (await bob.log.history(EntityType.expense, id))
        .firstWhere((c) => c.data['amount_minor'] == 1500);
    await bob.repo.resolveConflict(EntityType.expense, id, aliceHead.changeId);
    await alice.syncWith(bob, g);
    expect((await alice.repo.expense(id))!.amountMinor, 1500);
    expect((await alice.repo.expense(id))!.conflicted, isFalse);
    expect(await alice.repo.openConflicts(), isEmpty);
    expect(await bob.repo.openConflicts(), isEmpty);
  });

  test('concurrent edits of different fields merge without conflict', () async {
    await bob.pullFrom(alice, g);
    final id = await alice.repo.addExpense(draft(g, alice.userId, 1000, [alice.userId, bob.userId]));
    await bob.pullFrom(alice, g);
    await alice.repo.editExpense(id, draft(g, alice.userId, 1200, [alice.userId, bob.userId]));
    await bob.repo.editExpense(
        id, draft(g, alice.userId, 1000, [alice.userId, bob.userId], notes: 'with tip'));
    await alice.syncWith(bob, g);
    for (final d in [alice, bob]) {
      final e = (await d.repo.expense(id))!;
      expect(e.amountMinor, 1200);
      expect(e.notes, 'with tip');
      expect(e.conflicted, isFalse);
    }
  });

  test('concurrent edit vs delete is flagged; deletions propagate as tombstones', () async {
    await bob.pullFrom(alice, g);
    final id = await alice.repo.addExpense(draft(g, alice.userId, 1000, [alice.userId, bob.userId]));
    final id2 = await alice.repo.addExpense(draft(g, alice.userId, 600, [alice.userId, bob.userId]));
    await bob.pullFrom(alice, g);
    await alice.repo.deleteExpense(id);
    await bob.repo.editExpense(id, draft(g, alice.userId, 1100, [alice.userId, bob.userId]));
    await bob.repo.deleteExpense(id2);
    await alice.syncWith(bob, g);
    expect((await alice.repo.expense(id))!.conflicted, isTrue);
    expect((await alice.repo.expense(id2))!.deleted, isTrue);
    expect((await bob.repo.expense(id2))!.deleted, isTrue);
    expect(await alice.balanceFingerprint(g), await bob.balanceFingerprint(g));
  });

  test('settlement creation is idempotent and voiding is auditable', () async {
    await bob.pullFrom(alice, g);
    await alice.repo.addExpense(draft(g, alice.userId, 1000, [alice.userId, bob.userId]));
    await bob.pullFrom(alice, g);
    final sid = const Uuid().v4();
    for (var i = 0; i < 3; i++) {
      await bob.repo.recordSettlement(
          id: sid, groupId: g, fromUserId: bob.userId, toUserId: alice.userId, amountMinor: 500, currency: 'INR');
    }
    await alice.syncWith(bob, g);
    await alice.syncWith(bob, g);
    expect((await alice.repo.settlements(groupId: g)).length, 1);
    expect((await alice.repo.balances(groupId: g)).nets(), isEmpty);

    await alice.repo.voidSettlement(sid, 'Payment bounced');
    await alice.syncWith(bob, g);
    final s = (await bob.repo.settlements(groupId: g)).single;
    expect(s.voided, isTrue);
    expect(s.voidReason, 'Payment bounced');
    expect((await bob.repo.balances(groupId: g)).owes(bob.userId, alice.userId, 'INR'), 500);
    final history = await bob.log.history(EntityType.settlement, sid);
    expect(history.length, 2);
  });

  test('two devices recording the same payment are flagged as a possible duplicate', () async {
    await bob.pullFrom(alice, g);
    await alice.repo.addExpense(draft(g, alice.userId, 1000, [alice.userId, bob.userId]));
    await bob.pullFrom(alice, g);
    await alice.repo.recordSettlement(
        id: const Uuid().v4(), groupId: g, fromUserId: bob.userId, toUserId: alice.userId, amountMinor: 500, currency: 'INR');
    await bob.repo.recordSettlement(
        id: const Uuid().v4(), groupId: g, fromUserId: bob.userId, toUserId: alice.userId, amountMinor: 500, currency: 'INR');
    await alice.syncWith(bob, g);
    final conflicts = await alice.repo.openConflicts(groupId: g);
    expect(conflicts.single.kind, 'possible_duplicate');
    // Voiding one clears it.
    final dup = conflicts.single.entityId;
    await alice.repo.voidSettlement(dup, 'Duplicate');
    await alice.syncWith(bob, g);
    expect(await alice.repo.openConflicts(groupId: g), isEmpty);
    expect(await bob.repo.openConflicts(groupId: g), isEmpty);
    expect((await bob.repo.balances(groupId: g)).nets(), isEmpty);
  });

  test('a settlement amount can never be edited, only voided', () async {
    await bob.pullFrom(alice, g);
    final sid = const Uuid().v4();
    await alice.repo.recordSettlement(
        id: sid, groupId: g, fromUserId: bob.userId, toUserId: alice.userId, amountMinor: 500, currency: 'INR');
    await bob.pullFrom(alice, g);
    final heads = await bob.log.heads(EntityType.settlement, sid);
    await expectLater(
      bob.log.transaction((txn) => bob.log.append(txn,
          type: EntityType.settlement,
          entityId: sid,
          groupId: g,
          parents: heads,
          data: {
            'from': bob.userId,
            'to': alice.userId,
            'amount_minor': 1,
            'currency': 'INR',
            'settled_at': 0,
            'method': 'cash',
            'voided': false,
          })),
      throwsA(isA<AuthorizationException>()),
    );
  });

  test('forged and tampered changes are rejected', () async {
    await bob.pullFrom(alice, g);
    final mallory = await LocalIdentity.generate('mallory');
    // Mallory signs an expense claiming to be Bob.
    final forged = await SyncChange.create(
      author: mallory,
      type: EntityType.expense,
      entityId: const Uuid().v4(),
      groupId: g,
      parents: const [],
      seq: 1,
      hlc: Hlc(alice.log.now(), 0, mallory.deviceId),
      data: draft(g, bob.userId, 999, [alice.userId, bob.userId]).toData(),
    );
    final asBob = SyncChange(
      formatVersion: forged.formatVersion,
      type: forged.type,
      entityId: forged.entityId,
      groupId: forged.groupId,
      parents: forged.parents,
      authorUserId: bob.userId,
      originDeviceId: forged.originDeviceId,
      originSeq: forged.originSeq,
      hlc: forged.hlc,
      data: forged.data,
      changeId: SyncChange.computeId({...forged.body, 'author': bob.userId}),
      signature: forged.signature,
    );
    final r = await alice.log.ingest([asBob]);
    expect(r.rejected, 1);
    expect(await alice.repo.expenses(groupId: g), isEmpty);

    // Tampered content (id no longer matches) is dropped and never stored.
    final real = (await alice.allChanges(g)).first;
    final tampered = SyncChange.fromWire({...real.toWire(), 'data': {...real.data, 'name': 'Hacked'}});
    final r2 = await bob.log.ingest([tampered]);
    expect(r2.rejected, 1);
    expect((await bob.repo.group(g))!.name, 'Goa trip');

    // An outsider who is not a member is not authorised even with a valid signature.
    final outsiderExpense = await SyncChange.create(
      author: mallory,
      type: EntityType.expense,
      entityId: const Uuid().v4(),
      groupId: g,
      parents: const [],
      seq: 2,
      hlc: Hlc(alice.log.now(), 1, mallory.deviceId),
      data: draft(g, alice.userId, 999, [alice.userId]).toData(),
    );
    final r3 = await alice.log.ingest([outsiderExpense]);
    expect(r3.applied, 0);
    expect(await alice.repo.expenses(groupId: g), isEmpty);
  });

  test('non-admins cannot add members; removed members keep history', () async {
    await bob.pullFrom(alice, g);
    final dave = await TestDevice.create('dave');
    await expectLater(bob.addMember(g, dave), throwsA(isA<AuthorizationException>()));

    await alice.repo.addExpense(draft(g, bob.userId, 900, [alice.userId, bob.userId, carol.userId]));
    await alice.repo.removeMember(g, carol.userId);
    await bob.pullFrom(alice, g);
    final members = await bob.repo.members(g);
    expect(members.firstWhere((m) => m.person.id == carol.userId).status, 'removed');
    expect((await bob.repo.balances(groupId: g)).owes(carol.userId, bob.userId, 'INR'), 300);
    await dave.dispose();
  });

  test('a member removed before an expense was authored cannot add one', () async {
    await bob.pullFrom(alice, g);
    await carol.pullFrom(alice, g);
    await alice.repo.removeMember(g, carol.userId);
    await carol.pullFrom(alice, g);
    await expectLater(
      carol.repo.addExpense(draft(g, carol.userId, 900, [carol.userId, bob.userId])),
      throwsA(isA<AuthorizationException>()),
    );
  });

  test('placeholder members can be linked to their real identity later', () async {
    final dan = await alice.repo.addPlaceholderMember(g, 'Dan');
    await alice.repo.addExpense(draft(g, alice.userId, 900, [alice.userId, dan, bob.userId]));
    final dave = await TestDevice.create('dave');
    await alice.addMember(g, dave);
    await alice.repo.linkPlaceholder(g, dan, dave.userId);
    await dave.pullFrom(alice, g);
    final bal = await dave.repo.balances(groupId: g);
    expect(bal.owes(dave.userId, alice.userId, 'INR'), 300);
    expect(bal.owes(dan, alice.userId, 'INR'), 0);
    await dave.dispose();
  });

  test('random offline edits converge to identical balances on every device', () async {
    await bob.pullFrom(alice, g);
    await carol.pullFrom(alice, g);
    final devices = [alice, bob, carol];
    final users = devices.map((d) => d.userId).toList();
    final rnd = Random(42);
    final ids = <String>[];
    for (var round = 0; round < 6; round++) {
      for (final d in devices) {
        for (var k = 0; k < 3; k++) {
          final roll = rnd.nextInt(10);
          if (roll < 5 || ids.isEmpty) {
            final people = (users.toList()..shuffle(rnd)).take(1 + rnd.nextInt(3)).toList();
            ids.add(await d.repo.addExpense(draft(g, users[rnd.nextInt(3)], 100 + rnd.nextInt(10000), people,
                type: rnd.nextBool() ? SplitType.equal : SplitType.shares)));
          } else if (roll < 8) {
            // Edits concentrate on a few hot expenses so concurrency happens.
            final id = ids[rnd.nextInt(min(ids.length, 4))];
            final e = await d.repo.expense(id);
            if (e == null) continue;
            await d.repo.editExpense(id, draft(g, e.payerId, 100 + rnd.nextInt(10000), users));
          } else {
            final id = ids[rnd.nextInt(ids.length)];
            if (await d.repo.expense(id) != null) await d.repo.deleteExpense(id);
          }
        }
      }
      // Partial, random pairwise syncs.
      for (var s = 0; s < 2; s++) {
        final x = devices[rnd.nextInt(3)], y = devices[rnd.nextInt(3)];
        if (x != y) await x.syncWith(y, g);
      }
    }
    // Full mesh until quiescent.
    for (var i = 0; i < 2; i++) {
      await alice.syncWith(bob, g);
      await bob.syncWith(carol, g);
      await carol.syncWith(alice, g);
    }
    final fa = await alice.balanceFingerprint(g);
    expect(await bob.balanceFingerprint(g), fa);
    expect(await carol.balanceFingerprint(g), fa);
    final ea = (await alice.repo.expenses(groupId: g, includeDeleted: true))
        .map((e) => '${e.id}:${e.amountMinor}:${e.deleted}:${e.conflicted}')
        .toList();
    final ec = (await carol.repo.expenses(groupId: g, includeDeleted: true))
        .map((e) => '${e.id}:${e.amountMinor}:${e.deleted}:${e.conflicted}')
        .toList();
    expect(ec..sort(), ea..sort());
    // The scenario must actually exercise concurrent edits and tombstones.
    expect(ea.where((s) => s.endsWith(':true')), isNotEmpty, reason: 'some conflicts');
    expect(ea.where((s) => s.contains(':true:')), isNotEmpty, reason: 'some deletions');
  });
}

