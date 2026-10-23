import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import 'change.dart';
import 'change_log.dart';
import 'secure_channel.dart';

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => 'Sync failed: $message';
}

class SyncProgress {
  const SyncProgress(this.phase, {this.sent = 0, this.toSend = 0, this.received = 0});
  final String phase;
  final int sent;
  final int toSend;
  final int received;
}

class SyncResult {
  SyncResult({required this.sent, required this.received, required this.groups});
  final int sent;
  final IngestReport received;
  final List<String> groups;
}

/// One run of the sync protocol over an authenticated [SecureChannel].
/// See docs/DESIGN.md §9 for the message flow.
class SyncSession {
  SyncSession({
    required this.channel,
    required this.peer,
    required this.log,
    this.batchSize = 200,
    this.onProgress,
    this.receiveTimeout = const Duration(seconds: 60),
  });

  final SecureChannel channel;
  final PeerIdentity peer;
  final ChangeLog log;
  final int batchSize;
  final Duration receiveTimeout;
  final void Function(SyncProgress)? onProgress;

  Database get _db => log.db;

  /// Groups this device may share with the peer: the peer must be an active
  /// member, and we must not have declined the group ourselves.
  Future<List<Map<String, Object?>>> _offer() => _db.rawQuery('''
    SELECT g.id, g.name FROM groups g
    JOIN group_members m ON m.group_id = g.id
    WHERE m.user_id = ? AND m.status = 'active' AND g.local_status <> 'declined'
    ORDER BY g.id''', [peer.userId]);

  Future<SyncResult> run() async {
    final report = IngestReport();
    var sent = 0;
    try {
      onProgress?.call(const SyncProgress('Comparing groups'));
      final offered = await _offer();
      final offeredIds = offered.map((g) => g['id']! as String).toSet();
      await channel.sendJson({'t': 'inventory', 'groups': offered});

      final inv = await _expect('inventory');
      final theirGroups = [
        for (final g in (inv['groups'] as List? ?? const []))
          if (g is Map && g['id'] is String) g['id']! as String,
      ];
      final declined = {
        for (final r in await _db.query('groups',
            columns: ['id'], where: "local_status = 'declined'"))
          r['id']! as String,
      };
      final wanted = theirGroups.where((g) => !declined.contains(g)).toSet();
      await channel.sendJson({
        't': 'request',
        'vectors': {for (final g in wanted) g: await log.vectorFor(g)},
      });

      final req = await _expect('request');
      final vectors = (req['vectors'] as Map? ?? const {}).cast<String, Object?>();
      // Never serve a group the peer is not entitled to, whatever it asks for.
      final outgoing = <SyncChange>[];
      for (final g in vectors.keys.where(offeredIds.contains).toList()..sort()) {
        final v = (vectors[g] as Map? ?? const {}).map((k, val) => MapEntry(k as String, val is int ? val : 0));
        outgoing.addAll(await log.missingFor(g, v));
      }

      onProgress?.call(SyncProgress('Exchanging changes', toSend: outgoing.length));

      var peerFinal = false;
      var peerDone = false;
      final acks = <int, Completer<Map<String, Object?>>>{};
      final allAcked = Completer<void>();
      final finished = Completer<void>();

      Future<void> sender() async {
        var no = 0;
        for (var i = 0; i <= outgoing.length; i += batchSize) {
          final chunk = outgoing.sublist(i, (i + batchSize).clamp(0, outgoing.length));
          final last = i + batchSize >= outgoing.length;
          final c = acks[no] = Completer();
          await channel.sendJson({
            't': 'batch',
            'no': no,
            'final': last,
            'changes': [for (final ch in chunk) ch.toWire()],
          });
          await c.future;
          sent += chunk.length;
          onProgress?.call(SyncProgress('Exchanging changes',
              sent: sent, toSend: outgoing.length, received: report.applied));
          no++;
          if (last) break;
        }
        allAcked.complete();
      }

      Future<void> maybeFinish() async {
        if (allAcked.isCompleted && peerFinal && !finished.isCompleted) {
          finished.complete();
          await channel.sendJson({'t': 'done'});
        }
      }

      Future<void> receiver() async {
        while (!peerDone) {
          final m = await channel.receiveJson(timeout: receiveTimeout);
          switch (m['t']) {
            case 'batch':
              final raw = m['changes'] as List? ?? const [];
              final parsed = <SyncChange>[];
              var malformed = 0;
              for (final r in raw) {
                try {
                  final c = SyncChange.fromWire(r);
                  if (wanted.contains(c.groupId)) {
                    parsed.add(c);
                  } else {
                    malformed++; // a group we did not ask for
                  }
                } on FormatException {
                  malformed++;
                }
              }
              final r = await log.ingest(parsed);
              r.rejected += malformed;
              report
                ..applied += r.applied
                ..pending += r.pending
                ..rejected += r.rejected
                ..duplicates += r.duplicates
                ..groups.addAll(r.groups);
              await channel.sendJson({'t': 'ack', 'no': m['no'], ...r.toJson()});
              if (m['final'] == true) {
                peerFinal = true;
                await maybeFinish();
              }
            case 'ack':
              acks[m['no']]?.complete(m);
            case 'done':
              peerDone = true;
            case 'error':
              throw SyncException('peer reported: ${m['message']}');
            default:
              throw SyncException('unexpected message ${m['t']}');
          }
        }
      }

      final senderFuture = sender().then((_) => maybeFinish());
      await Future.wait([senderFuture, receiver()], eagerError: true);
      if (!finished.isCompleted) await maybeFinish();

      await _recordSuccess(wanted.union(offeredIds));
      onProgress?.call(SyncProgress('Done', sent: sent, toSend: outgoing.length, received: report.applied));
      return SyncResult(sent: sent, received: report, groups: wanted.union(offeredIds).toList());
    } on HandshakeException catch (e) {
      throw SyncException(e.message);
    } finally {
      await channel.close();
    }
  }

  Future<Map<String, Object?>> _expect(String type) async {
    final m = await channel.receiveJson(timeout: receiveTimeout);
    if (m['t'] == 'error') throw SyncException('peer reported: ${m['message']}');
    if (m['t'] != type) throw SyncException('expected $type, got ${m['t']}');
    return m;
  }

  Future<void> _recordSuccess(Set<String> groups) async {
    final vector = <String, Object?>{};
    for (final g in groups) {
      vector[g] = await log.vectorFor(g);
    }
    await _db.update(
        'sync_devices',
        {'last_sync_at': log.now(), 'peer_vector': jsonEncode(vector)},
        where: 'device_id = ?',
        whereArgs: [peer.deviceId]);
  }
}
