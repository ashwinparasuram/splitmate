import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:splitmate/domain/models.dart';
import 'package:splitmate/domain/split_calculator.dart';
import 'package:splitmate/sync/pairing.dart';
import 'package:splitmate/sync/secure_channel.dart';
import 'package:splitmate/sync/sync_bundle.dart';
import 'package:splitmate/sync/sync_session.dart';
import 'package:splitmate/sync/transport/frame_channel.dart';

import '../support/harness.dart';

ExpenseDraft draft(String g, String payer, int amount, List<String> people) => ExpenseDraft(
      groupId: g,
      description: 'Groceries',
      amountMinor: amount,
      currency: 'INR',
      payerId: payer,
      splitType: SplitType.equal,
      participants: [for (final p in people) SplitInput(p)],
      expenseDate: 1700000000000,
    );

class Peer {
  Peer(this.d) : pairing = PairingService(d.repo);
  final TestDevice d;
  final PairingService pairing;
}

Future<(HandshakeResult, HandshakeResult)> handshake(Peer responder, Peer initiator,
    {required HandshakeMode mode, Invitation? inv, String? expectedKey, MemoryChannel? rawA, MemoryChannel? rawB}) async {
  final (a, b) = rawA != null ? (rawA, rawB!) : MemoryChannel.pair();
  final results = await Future.wait([
    Handshake.respond(
      raw: a,
      me: responder.d.identity,
      inviteSecretFor: responder.pairing.secretFor,
      isKnownPeer: responder.pairing.isKnownPeer,
      allowedModes: {HandshakeMode.pair, HandshakeMode.sync},
    ),
    Handshake.initiate(
      raw: b,
      me: initiator.d.identity,
      mode: mode,
      expectedPeerKey: expectedKey ?? inv?.ed25519Pub ?? responder.d.identity.ed25519Pub,
      inviteId: inv?.id,
      inviteSecret: inv?.secret,
    ),
  ]);
  return (results[0], results[1]);
}

Future<(SyncResult, SyncResult)> runSync(Peer x, Peer y, {int batchSize = 200}) async {
  final (hx, hy) = await handshake(x, y, mode: HandshakeMode.sync);
  final r = await Future.wait([
    SyncSession(channel: hx.channel, peer: hx.peer, log: x.d.log, batchSize: batchSize).run(),
    SyncSession(channel: hy.channel, peer: hy.peer, log: y.d.log, batchSize: batchSize).run(),
  ]);
  x.d.repo.notifyChanged();
  y.d.repo.notifyChanged();
  return (r[0], r[1]);
}

/// Full pairing as the UI does it: QR -> handshake -> SAS -> both approve -> sync.
Future<void> pair(Peer inviter, Peer scanner, String groupId) async {
  final inv = await inviter.pairing.createInvitation(endpoints: const ['memory'], groupId: groupId);
  final scanned = Invitation.decode(inv.encode());
  final (ha, hb) = await handshake(inviter, scanner, mode: HandshakeMode.pair, inv: scanned);
  expect(ha.sas, hb.sas);
  await Future.wait([
    inviter.pairing.confirm(hs: ha, localApproval: Future.value(true), inviteId: inv.id),
    scanner.pairing.confirm(hs: hb, localApproval: Future.value(true), scannedInvitation: scanned),
  ]);
  await Future.wait([
    SyncSession(channel: ha.channel, peer: ha.peer, log: inviter.d.log).run(),
    SyncSession(channel: hb.channel, peer: hb.peer, log: scanner.d.log).run(),
  ]);
}

void main() {
  late Peer alice, bob;
  late String g;

  setUp(() async {
    alice = Peer(await TestDevice.create('alice'));
    bob = Peer(await TestDevice.create('bob'));
    g = await alice.d.repo.createGroup('Flat 4B', 'INR');
  });

  tearDown(() async {
    await alice.d.dispose();
    await bob.d.dispose();
  });

  test('QR pairing with SAS approval, then initial sync of the shared group', () async {
    await alice.d.repo.addExpense(draft(g, alice.d.userId, 900, [alice.d.userId]));
    await pair(alice, bob, g);
    final bobGroup = await bob.d.repo.group(g);
    expect(bobGroup!.localStatus, 'active', reason: 'scanning a group invite is consent');
    expect((await bob.d.repo.members(g)).map((m) => m.person.id), contains(bob.d.userId));
    expect((await bob.d.repo.expenses(groupId: g)).length, 1);
    expect(await alice.pairing.isKnownPeer(peerIdentityFor(bob.d)), isTrue);
    expect(await alice.d.repo.unsyncedLocalChanges(), 0);
  });

  test('a declined approval pairs nothing', () async {
    final inv = await alice.pairing.createInvitation(endpoints: const [], groupId: g);
    final (ha, hb) = await handshake(alice, bob, mode: HandshakeMode.pair, inv: inv);
    await expectLater(
      Future.wait([
        alice.pairing.confirm(hs: ha, localApproval: Future.value(false), inviteId: inv.id),
        bob.pairing.confirm(hs: hb, localApproval: Future.value(true), scannedInvitation: inv),
      ]),
      throwsA(isA<PairingException>()),
    );
    expect(await alice.d.db.query('sync_devices'), isEmpty);
    expect((await alice.d.repo.members(g)).length, 1);
  });

  test('a QR code alone is not enough: wrong secret, wrong key and expired invites fail', () async {
    final inv = await alice.pairing.createInvitation(endpoints: const [], groupId: g);
    final forged = Invitation(
      id: inv.id,
      secret: List.filled(32, 7),
      userId: inv.userId,
      deviceId: inv.deviceId,
      displayName: inv.displayName,
      ed25519Pub: inv.ed25519Pub,
      x25519Pub: inv.x25519Pub,
      expiresAt: inv.expiresAt,
      endpoints: inv.endpoints,
      groupId: g,
    );
    await expectLater(handshake(alice, bob, mode: HandshakeMode.pair, inv: forged),
        throwsA(isA<HandshakeException>()));

    // Someone impersonating Alice's device cannot match the pinned key.
    final mallory = Peer(await TestDevice.create('mallory'));
    final inv2 = await mallory.pairing.createInvitation(endpoints: const []);
    await expectLater(
        handshake(mallory, bob, mode: HandshakeMode.pair, inv: inv2, expectedKey: alice.d.identity.ed25519Pub),
        throwsA(isA<HandshakeException>()));
    await mallory.d.dispose();

    final old = await alice.pairing.createInvitation(endpoints: const [], groupId: g);
    await alice.d.db.update('group_invitations', {'expires_at': 0}, where: 'id = ?', whereArgs: [old.id]);
    await expectLater(handshake(alice, bob, mode: HandshakeMode.pair, inv: old),
        throwsA(isA<HandshakeException>()));
  });

  test('unpaired devices cannot open a sync session', () async {
    await expectLater(handshake(alice, bob, mode: HandshakeMode.sync), throwsA(isA<HandshakeException>()));
  });

  test('replayed or tampered records are rejected by the secure channel', () async {
    await pair(alice, bob, g);
    final (a, b) = MemoryChannel.pair();
    final (ha, hb) = await handshake(alice, bob, mode: HandshakeMode.sync, rawA: a, rawB: b);
    final captured = <Uint8List>[];
    // Capture a genuine record by sending through a tap.
    await hb.channel.sendJson({'t': 'ping'});
    final first = await ha.channel.receiveJson();
    expect(first['t'], 'ping');
    // Re-inject an old counter: the receiver expects counter 1 now.
    final replay = Uint8List(8 + 16 + 4);
    captured.add(replay);
    b.inject(replay);
    await expectLater(ha.channel.receiveJson(), throwsA(isA<HandshakeException>()));
  });

  test('incremental sync, both directions, and nothing to send', () async {
    await pair(alice, bob, g);
    await bob.d.repo.addExpense(draft(g, bob.d.userId, 1000, [alice.d.userId, bob.d.userId]));
    await alice.d.repo.addExpense(draft(g, alice.d.userId, 400, [alice.d.userId, bob.d.userId]));
    final (ra, rb) = await runSync(alice, bob);
    expect(ra.received.applied, 1);
    expect(rb.received.applied, 1);
    expect(await alice.d.balanceFingerprint(g), await bob.d.balanceFingerprint(g));
    final (ra2, rb2) = await runSync(alice, bob);
    expect(ra2.sent + rb2.sent, 0);
  });

  test('interrupted sync keeps acknowledged batches and resumes', () async {
    await pair(alice, bob, g);
    for (var i = 0; i < 25; i++) {
      await alice.d.repo.addExpense(draft(g, alice.d.userId, 100 + i, [alice.d.userId, bob.d.userId]));
    }
    final (a, b) = MemoryChannel.pair();
    final (ha, hb) = await handshake(alice, bob, mode: HandshakeMode.sync, rawA: a, rawB: b);
    a.dropAfter = a.sent + 4; // inventory, request, then ~2 batches
    await expectLater(
      Future.wait([
        SyncSession(channel: ha.channel, peer: ha.peer, log: alice.d.log, batchSize: 5, receiveTimeout: const Duration(seconds: 2)).run(),
        SyncSession(channel: hb.channel, peer: hb.peer, log: bob.d.log, batchSize: 5, receiveTimeout: const Duration(seconds: 2)).run(),
      ]),
      throwsA(anything),
    );
    final partial = (await bob.d.repo.expenses(groupId: g)).length;
    expect(partial, inInclusiveRange(1, 24));
    await runSync(alice, bob, batchSize: 5);
    expect((await bob.d.repo.expenses(groupId: g)).length, 25);
  });

  test('only groups shared with the peer are ever exchanged', () async {
    final secret = await alice.d.repo.createGroup('Private', 'INR');
    await alice.d.repo.addExpense(draft(secret, alice.d.userId, 5000, [alice.d.userId]));
    await pair(alice, bob, g);
    expect(await bob.d.repo.group(secret), isNull);
    expect(await bob.d.db.query('sync_changes', where: 'group_id = ?', whereArgs: [secret]), isEmpty);

    // A malicious peer asking for the private group by id gets nothing.
    final (ha, hb) = await handshake(alice, bob, mode: HandshakeMode.sync);
    final aliceSide = SyncSession(channel: ha.channel, peer: ha.peer, log: alice.d.log).run();
    final inv = await hb.channel.receiveJson();
    expect((inv['groups'] as List).map((x) => (x as Map)['id']), isNot(contains(secret)));
    await hb.channel.sendJson({'t': 'inventory', 'groups': []});
    await hb.channel.sendJson({'t': 'request', 'vectors': {secret: {}, g: {}}});
    await hb.channel.receiveJson(); // alice's request
    final batch = await hb.channel.receiveJson();
    final groups = (batch['changes'] as List).map((c) => (c as Map)['group']).toSet();
    expect(groups, isNot(contains(secret)));
    await hb.channel.sendJson({'t': 'ack', 'no': batch['no']});
    await hb.channel.sendJson({'t': 'batch', 'no': 0, 'final': true, 'changes': []});
    await hb.channel.receiveJson(); // ack
    await hb.channel.sendJson({'t': 'done'});
    await aliceSide;
  });

  test('reconnecting after a long offline period converges', () async {
    await pair(alice, bob, g);
    for (var i = 0; i < 40; i++) {
      final a = await alice.d.repo.addExpense(draft(g, alice.d.userId, 1000 + i, [alice.d.userId, bob.d.userId]));
      await bob.d.repo.addExpense(draft(g, bob.d.userId, 500 + i, [alice.d.userId, bob.d.userId]));
      if (i % 5 == 0) await alice.d.repo.deleteExpense(a);
    }
    await runSync(bob, alice, batchSize: 16);
    expect(await alice.d.balanceFingerprint(g), await bob.d.balanceFingerprint(g));
    expect((await bob.d.repo.expenses(groupId: g)).length, 72);
  });

  test('sealed sync files work across networks and are idempotent', () async {
    await pair(alice, bob, g);
    await alice.d.repo.addExpense(draft(g, alice.d.userId, 3000, [alice.d.userId, bob.d.userId]));
    final svcA = BundleService(alice.d.log);
    final svcB = BundleService(bob.d.log);
    final file = await svcA.exportFor(bob.d.identity.deviceId);
    final r1 = await svcB.import(file);
    expect(r1.applied, 1);
    final r2 = await svcB.import(file);
    expect(r2.applied, 0);

    final tampered = Uint8List.fromList(file)..[file.length - 80] ^= 1;
    await expectLater(svcB.import(tampered), throwsA(isA<BundleException>()));
    // Not addressed to Alice.
    await expectLater(svcA.import(file), throwsA(isA<BundleException>()));
  });
}

// Minimal PeerIdentity for a test device.
PeerIdentity peerIdentityFor(TestDevice d) => PeerIdentity(
      userId: d.userId,
      deviceId: d.identity.deviceId,
      displayName: d.name,
      ed25519Pub: d.identity.ed25519Pub,
      x25519Pub: d.identity.x25519Pub,
      schemaVersion: 1,
    );
