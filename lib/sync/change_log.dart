import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../core/hlc.dart';
import '../core/money.dart';
import '../domain/split_calculator.dart';
import '../identity/identity.dart';
import 'change.dart';
import 'group_state.dart';
import 'merge.dart';
import 'payload_validation.dart';

class AuthorizationException implements Exception {
  AuthorizationException(this.reason);
  final String reason;
  @override
  String toString() => 'Not allowed: $reason';
}

class IngestReport {
  int applied = 0;
  int pending = 0;
  int rejected = 0;
  int duplicates = 0;
  final Set<String> groups = {};

  Map<String, Object?> toJson() =>
      {'applied': applied, 'pending': pending, 'rejected': rejected, 'duplicates': duplicates};

  @override
  String toString() => jsonEncode(toJson());
}

class _Verdict {
  const _Verdict(this.status, [this.reason]);
  final String status;
  final String? reason;
  static const applied = _Verdict('applied');
  bool get isApplied => status == 'applied';
}

const _maxFutureSkew = Duration(hours: 24);
const duplicateSettlementWindow = Duration(hours: 48);

/// The authoritative, signed change log and its materialisation into the
/// entity tables. See docs/DESIGN.md §2, §6-§8.
class ChangeLog {
  ChangeLog(this.db, this.identity, {int Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  final Database db;
  LocalIdentity identity;
  final int Function() _now;
  late HlcClock _clock;
  final Map<String, bool> _sigCache = {};

  int now() => _now();

  Future<void> init() async {
    final last = await _meta(db, 'hlc_last');
    Hlc? parsed;
    if (last != null && Hlc.isValid(last)) parsed = Hlc.parse(last);
    _clock = HlcClock(identity.deviceId,
        last: parsed == null ? null : Hlc(parsed.millis, parsed.counter, identity.deviceId),
        now: _now);
  }

  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) =>
      db.transaction(action);

  // ---------------------------------------------------------------- local

  /// Appends a locally authored change and materialises it, atomically with
  /// whatever else [txn] does. Throws [AuthorizationException] if the change
  /// would be rejected by peers.
  Future<SyncChange> append(
    Transaction txn, {
    required EntityType type,
    required String entityId,
    required String groupId,
    required Map<String, Object?> data,
    List<String>? parents,
  }) async {
    final invalid = validatePayload(type, data);
    if (invalid != null) throw AuthorizationException(invalid);

    final heads = parents ?? await _heads(txn, type, entityId);
    final seq = int.parse(await _meta(txn, 'device_seq') ?? '0') + 1;
    await _setMeta(txn, 'device_seq', '$seq');
    final hlc = _clock.tick();
    await _setMeta(txn, 'hlc_last', hlc.toString());

    final change = await SyncChange.create(
      author: identity,
      type: type,
      entityId: entityId,
      groupId: groupId,
      parents: heads,
      seq: seq,
      hlc: hlc,
      data: data,
    );
    _sigCache['${change.changeId}|${identity.ed25519Pub}'] = true;

    final state = await _loadGroupState(txn, groupId);
    final parentRows = <String, (String, SyncChange)>{};
    for (final p in change.parents) {
      final r = await txn.query('sync_changes', where: 'change_id = ?', whereArgs: [p]);
      if (r.isNotEmpty) {
        parentRows[p] = (r.first['status']! as String, SyncChange.fromRow(r.first));
      }
    }
    final verdict = await _evaluate(change, state, (id) => parentRows[id],
        pairedKeys: await _pairedKeys(txn));
    if (!verdict.isApplied) throw AuthorizationException(verdict.reason ?? verdict.status);

    await txn.insert('sync_changes', {
      ...change.toRow(),
      'status': 'applied',
      'is_local': 1,
      'received_at': _now(),
    });

    if (type == EntityType.group || type == EntityType.member) {
      await replayGroup(txn, groupId);
    } else {
      final applied = await _appliedForEntity(txn, type, entityId);
      final merged = mergeEntity(applied);
      if (type == EntityType.expense) {
        await _writeExpense(txn, merged, groupId, null);
      } else {
        await _writeSettlement(txn, merged, groupId);
        await _detectDuplicateSettlements(txn, groupId);
      }
      await _syncConflict(txn, type, entityId, groupId, merged);
      await _logActivity(txn, change, remote: false);
    }
    return change;
  }

  // --------------------------------------------------------------- remote

  /// Stores and applies remote changes. All-or-nothing per call.
  Future<IngestReport> ingest(List<SyncChange> changes) async {
    final report = IngestReport();
    await db.transaction((txn) async {
      final inserted = <String>{};
      for (final c in changes) {
        // Integrity: the id must be the hash of the content. Anything else is
        // dropped without storing so it cannot squat on a genuine change's id.
        if (SyncChange.computeId(c.body) != c.changeId) {
          report.rejected++;
          continue;
        }
        final existing = await txn.query('sync_changes',
            columns: ['status', 'signature'], where: 'change_id = ?', whereArgs: [c.changeId]);
        if (existing.isNotEmpty) {
          final row = existing.first;
          if (row['status'] != 'applied' && row['signature'] != c.signature) {
            // A relay may have delivered a bad signature first; Ed25519 is
            // deterministic, so a different signature deserves a retry.
            await txn.update('sync_changes',
                {'signature': c.signature, 'status': 'pending', 'status_reason': 'resubmitted'},
                where: 'change_id = ?', whereArgs: [c.changeId]);
            report.groups.add(c.groupId);
          } else {
            report.duplicates++;
          }
          continue;
        }
        final clash = await txn.query('sync_changes',
            columns: ['change_id'],
            where: 'origin_device_id = ? AND origin_seq = ?',
            whereArgs: [c.originDeviceId, c.originSeq]);
        if (clash.isNotEmpty) {
          // Same device and sequence number, different content: equivocation.
          report.rejected++;
          continue;
        }
        final hlc = Hlc.parse(c.hlc);
        final future = hlc.millis > _now() + _maxFutureSkew.inMilliseconds;
        await txn.insert('sync_changes', {
          ...c.toRow(),
          'status': future ? 'rejected' : 'pending',
          'status_reason': future ? 'invalid:clock_skew' : 'new',
          'is_local': 0,
          'received_at': _now(),
        });
        if (!future) _clock.observe(hlc);
        inserted.add(c.changeId);
        report.groups.add(c.groupId);
      }
      await _setMeta(txn, 'hlc_last', _clock.last.toString());
      for (final g in report.groups) {
        await replayGroup(txn, g);
      }
      if (inserted.isNotEmpty) {
        final rows = await txn.query('sync_changes',
            columns: ['change_id', 'status'],
            where: 'change_id IN (${List.filled(inserted.length, '?').join(',')})',
            whereArgs: inserted.toList());
        for (final r in rows) {
          switch (r['status']) {
            case 'applied':
              report.applied++;
            case 'pending':
              report.pending++;
            default:
              report.rejected++;
          }
        }
      }
    });
    return report;
  }

  /// Re-evaluates every change of [groupId] in HLC order and rewrites the
  /// group's materialised rows. Statuses and rows are a pure function of the
  /// set of stored changes, which is what makes devices converge.
  Future<void> replayGroup(Transaction txn, String groupId) async {
    final rows = await txn.query('sync_changes', where: 'group_id = ?', whereArgs: [groupId]);
    final all = <SyncChange>[];
    final stored = <String, (String, String?)>{};
    for (final r in rows) {
      final c = SyncChange.fromRow(r);
      all.add(c);
      stored[c.changeId] = (r['status']! as String, r['status_reason'] as String?);
    }
    all.sort((a, b) {
      final c = a.hlc.compareTo(b.hlc);
      return c != 0 ? c : a.changeId.compareTo(b.changeId);
    });

    final state = GroupState(groupId);
    final byId = {for (final c in all) c.changeId: c};
    final status = <String, _Verdict>{};
    final appliedByEntity = <String, List<SyncChange>>{};
    final pairedKeys = await _pairedKeys(txn);

    for (final c in all) {
      final prev = stored[c.changeId]!;
      _Verdict v;
      if (prev.$2 != null && prev.$2!.startsWith('invalid:')) {
        v = _Verdict('rejected', prev.$2);
      } else {
        v = await _evaluate(c, state, (id) {
          final p = byId[id];
          final s = status[id];
          if (p == null) return null;
          // A parent sorted after its child has not been evaluated: invalid order.
          return (s?.status ?? 'unevaluated', p);
        }, pairedKeys: pairedKeys);
      }
      status[c.changeId] = v;
      if (v.isApplied) {
        final list = appliedByEntity.putIfAbsent('${c.type.name}:${c.entityId}', () => []);
        list.add(c);
        if (c.type == EntityType.group || c.type == EntityType.member) {
          _applyMembership(state, c.type, c.entityId, list, appliedByEntity);
        }
      }
    }

    for (final c in all) {
      final v = status[c.changeId]!;
      final prev = stored[c.changeId]!;
      if (prev.$1 != v.status || prev.$2 != v.reason) {
        await txn.update('sync_changes', {'status': v.status, 'status_reason': v.reason},
            where: 'change_id = ?', whereArgs: [c.changeId]);
      }
    }

    await _rewriteGroup(txn, groupId, state, appliedByEntity);

    // Activity mirrors exactly the applied set.
    final logged = await txn.query('activity_logs',
        columns: ['change_id'], where: 'group_id = ?', whereArgs: [groupId]);
    final loggedIds = logged.map((r) => r['change_id']! as String).toSet();
    for (final c in all) {
      final applied = status[c.changeId]!.isApplied;
      if (applied && !loggedIds.contains(c.changeId)) {
        await _logActivity(txn, c, remote: c.originDeviceId != identity.deviceId);
      } else if (!applied && loggedIds.contains(c.changeId)) {
        await txn.delete('activity_logs', where: 'change_id = ?', whereArgs: [c.changeId]);
      }
    }
  }

  // ------------------------------------------------------------- evaluate

  Future<_Verdict> _evaluate(
    SyncChange c,
    GroupState s,
    (String, SyncChange)? Function(String id) parentOf, {
    required Map<String, String> pairedKeys,
  }) async {
    if (c.formatVersion > kChangeFormatVersion) {
      return const _Verdict('pending', 'unsupported_version');
    }
    final invalid = validatePayload(c.type, c.data);
    if (invalid != null) return _Verdict('rejected', 'invalid:$invalid');

    for (final p in c.parents) {
      final info = parentOf(p);
      if (info == null) return const _Verdict('pending', 'missing_parent');
      final (pStatus, parent) = info;
      if (parent.type != c.type || parent.entityId != c.entityId) {
        return const _Verdict('rejected', 'invalid:parent_entity');
      }
      if (parent.hlc.compareTo(c.hlc) >= 0) {
        return const _Verdict('rejected', 'invalid:parent_order');
      }
      if (pStatus == 'rejected') return const _Verdict('rejected', 'parent_rejected');
      if (pStatus != 'applied') return const _Verdict('pending', 'parent_pending');
    }

    final d = c.data;
    String? key;
    switch (c.type) {
      case EntityType.group:
        final creator = (d['creator']! as Map).cast<String, Object?>();
        if (c.parents.isEmpty) {
          if (c.entityId != c.groupId) return const _Verdict('rejected', 'invalid:group_id');
          if (creator['user_id'] != c.authorUserId) {
            return const _Verdict('rejected', 'invalid:creator_mismatch');
          }
          key = creator['ed25519_pub'] as String?;
          final known = pairedKeys[c.authorUserId];
          if (known != null && known != key) {
            return const _Verdict('rejected', 'invalid:key_mismatch');
          }
        } else {
          if (!s.exists) return const _Verdict('pending', 'unknown_group');
          if (creator['user_id'] != s.creatorId || d['type'] != s.type) {
            return const _Verdict('rejected', 'invalid:immutable_group_fields');
          }
          final m = s[c.authorUserId];
          if (m == null) return const _Verdict('pending', 'unknown_author');
          if (!m.isAdmin) return const _Verdict('rejected', 'not_admin');
          key = m.ed25519Pub;
        }
      case EntityType.member:
        if (!s.exists) return const _Verdict('pending', 'unknown_group');
        final target = d['user_id']! as String;
        if (memberEntityId(c.groupId, target) != c.entityId) {
          return const _Verdict('rejected', 'invalid:member_id');
        }
        final author = s[c.authorUserId];
        if (author == null) return const _Verdict('pending', 'unknown_author');
        final current = s[target];
        final selfLeave = c.authorUserId == target &&
            d['status'] == 'removed' &&
            current != null &&
            d['role'] == current.role &&
            d['ed25519_pub'] == current.ed25519Pub;
        if (!author.isAdmin && !selfLeave) return const _Verdict('rejected', 'not_admin');
        final newKey = d['ed25519_pub'] as String?;
        if (newKey != null) {
          final bound = current?.ed25519Pub ?? pairedKeys[target];
          if (bound != null && bound != newKey) {
            return const _Verdict('rejected', 'key_mismatch');
          }
          if (target == identity.userId && newKey != identity.ed25519Pub) {
            return const _Verdict('rejected', 'key_mismatch');
          }
        }
        final merged = d['merged_into'] as String?;
        if (merged != null && s[merged] == null) {
          return const _Verdict('pending', 'unknown_member');
        }
        key = author.ed25519Pub;
      case EntityType.expense:
      case EntityType.settlement:
        if (!s.exists) return const _Verdict('pending', 'unknown_group');
        final author = s[c.authorUserId];
        if (author == null) return const _Verdict('pending', 'unknown_author');
        if (!author.isActive) return const _Verdict('rejected', 'author_not_member');
        key = author.ed25519Pub;
        final people = c.type == EntityType.expense
            ? [
                d['payer_id']! as String,
                for (final p in d['participants']! as List) (p as Map)['user_id']! as String,
              ]
            : [d['from']! as String, d['to']! as String];
        for (final u in people) {
          final m = s[u];
          if (m == null) return const _Verdict('pending', 'unknown_member');
          if (c.parents.isEmpty && !m.isActive) {
            return const _Verdict('rejected', 'participant_not_member');
          }
        }
        if (c.type == EntityType.settlement && c.parents.isNotEmpty) {
          final parent = parentOf(c.parents.first)!.$2.data;
          for (final f in const ['from', 'to', 'amount_minor', 'currency', 'settled_at']) {
            if (parent[f] != d[f]) {
              return const _Verdict('rejected', 'invalid:settlement_immutable');
            }
          }
          if (parent['voided'] == true && d['voided'] != true) {
            return const _Verdict('rejected', 'invalid:settlement_unvoid');
          }
        }
    }

    if (key == null) return const _Verdict('pending', 'unknown_key');
    final cacheKey = '${c.changeId}|$key';
    var ok = _sigCache[cacheKey];
    if (ok == null) {
      ok = await verifyEd25519(utf8.encode(c.changeId), unb64(c.signature), key);
      _sigCache[cacheKey] = ok;
    }
    if (!ok) return const _Verdict('rejected', 'invalid:signature');
    return _Verdict.applied;
  }

  void _applyMembership(GroupState s, EntityType type, String entityId,
      List<SyncChange> entityChanges, Map<String, List<SyncChange>> appliedByEntity) {
    if (type == EntityType.group) {
      final merged = mergeEntity(entityChanges);
      final creator = (merged.root.data['creator']! as Map).cast<String, Object?>();
      s.exists = true;
      s.creatorId = creator['user_id']! as String;
      s.type = merged.root.data['type']! as String;
      final creatorEntity = appliedByEntity['member:${memberEntityId(s.groupId, s.creatorId!)}'];
      if (creatorEntity == null) {
        s.members[s.creatorId!] = MemberState(
          userId: s.creatorId!,
          displayName: (creator['display_name'] as String?) ?? 'Creator',
          role: 'admin',
          status: 'active',
          joinedHlc: merged.root.hlc,
          ed25519Pub: creator['ed25519_pub'] as String?,
          x25519Pub: creator['x25519_pub'] as String?,
        );
      }
      return;
    }
    final merged = mergeEntity(entityChanges);
    final d = merged.data;
    final userId = d['user_id']! as String;
    final previous = s.members[userId];
    final removed = d['status'] == 'removed';
    s.members[userId] = MemberState(
      userId: userId,
      displayName: d['display_name']! as String,
      role: d['role']! as String,
      status: d['status']! as String,
      joinedHlc: previous?.joinedHlc ?? merged.root.hlc,
      removedHlc: removed ? merged.winner.hlc : null,
      ed25519Pub: (d['ed25519_pub'] as String?) ?? previous?.ed25519Pub,
      x25519Pub: (d['x25519_pub'] as String?) ?? previous?.x25519Pub,
      mergedInto: d['merged_into'] as String?,
    );
  }

  // ---------------------------------------------------------- materialise

  Future<void> _rewriteGroup(Transaction txn, String groupId, GroupState state,
      Map<String, List<SyncChange>> appliedByEntity) async {
    final groupChanges = appliedByEntity['group:$groupId'];
    if (groupChanges == null) {
      await txn.delete('groups', where: 'id = ?', whereArgs: [groupId]);
      await txn.delete('sync_conflicts', where: 'group_id = ?', whereArgs: [groupId]);
      return;
    }
    for (final m in state.members.values) {
      await _ensureUser(txn, m.userId, m.displayName, m.ed25519Pub, m.x25519Pub);
    }
    await _writeGroup(txn, mergeEntity(groupChanges));

    await txn.delete('group_members', where: 'group_id = ?', whereArgs: [groupId]);
    for (final m in state.members.values) {
      await txn.insert('group_members', {
        'id': memberEntityId(groupId, m.userId),
        'group_id': groupId,
        'user_id': m.userId,
        'role': m.role,
        'status': m.status,
        'joined_hlc': m.joinedHlc,
        'removed_hlc': m.removedHlc,
        'head_change_id': appliedByEntity['member:${memberEntityId(groupId, m.userId)}']
            ?.last
            .changeId,
        'updated_at': _now(),
      });
    }
    await _setMeta(txn, 'merged_into:$groupId',
        jsonEncode({for (final m in state.members.values) if (m.mergedInto != null) m.userId: m.mergedInto}));

    final receipts = {
      for (final r in await txn.query('expenses',
          columns: ['id', 'receipt_path'],
          where: 'group_id = ? AND receipt_path IS NOT NULL',
          whereArgs: [groupId]))
        r['id']! as String: r['receipt_path'] as String?,
    };
    await txn.delete('expenses', where: 'group_id = ?', whereArgs: [groupId]);
    await txn.delete('settlements', where: 'group_id = ?', whereArgs: [groupId]);

    for (final entry in appliedByEntity.entries) {
      final colon = entry.key.indexOf(':');
      final type = EntityType.values.byName(entry.key.substring(0, colon));
      final entityId = entry.key.substring(colon + 1);
      if (type != EntityType.expense && type != EntityType.settlement) continue;
      final merged = mergeEntity(entry.value);
      if (type == EntityType.expense) {
        await _writeExpense(txn, merged, groupId, receipts[entityId]);
      } else {
        await _writeSettlement(txn, merged, groupId);
      }
      await _syncConflict(txn, type, entityId, groupId, merged);
    }
    await _detectDuplicateSettlements(txn, groupId);
  }

  Future<void> _writeGroup(Transaction txn, MergeResult m) async {
    final d = m.data;
    final id = m.root.entityId;
    final values = {
      'name': d['name'],
      'type': m.root.data['type'],
      'default_currency': d['default_currency'],
      'created_by': m.root.authorUserId,
      'archived': d['archived'] == true ? 1 : 0,
      'head_change_id': m.winner.changeId,
      'created_at': Hlc.parse(m.root.hlc).millis,
      'updated_at': Hlc.parse(m.winner.hlc).millis,
      'deleted_at': d['deleted'] == true ? Hlc.parse(m.winner.hlc).millis : null,
    };
    final n = await txn.update('groups', values, where: 'id = ?', whereArgs: [id]);
    if (n == 0) {
      final consent = await _meta(txn, 'consent:$id');
      await txn.insert('groups', {
        'id': id,
        ...values,
        'local_status': consent ??
            (m.root.authorUserId == identity.userId ? 'active' : 'invited'),
      });
    }
  }

  Future<void> _writeExpense(
      Transaction txn, MergeResult m, String groupId, String? receiptPath) async {
    final d = m.data;
    final id = m.root.entityId;
    receiptPath ??= (await txn.query('expenses',
            columns: ['receipt_path'], where: 'id = ?', whereArgs: [id]))
        .firstOrNull?['receipt_path'] as String?;
    await txn.delete('expenses', where: 'id = ?', whereArgs: [id]);
    final inputs = [
      for (final p in d['participants']! as List)
        SplitInput.fromJson((p as Map).cast<String, Object?>()),
    ];
    final splits = SplitCalculator.allocate(
      total: d['amount_minor']! as int,
      type: splitTypeFromName(d['split_type']! as String),
      inputs: inputs,
    );
    final winnerMs = Hlc.parse(m.winner.hlc).millis;
    await txn.insert('expenses', {
      'id': id,
      'group_id': groupId,
      'description': d['description'],
      'amount_minor': d['amount_minor'],
      'currency': d['currency'],
      'payer_id': d['payer_id'],
      'split_type': d['split_type'],
      'expense_date': d['expense_date'],
      'category': d['category'],
      'notes': d['notes'],
      'receipt_path': receiptPath,
      'created_by': m.root.authorUserId,
      'conflicted': m.financialConflict ? 1 : 0,
      'head_change_id': m.winner.changeId,
      'created_at': Hlc.parse(m.root.hlc).millis,
      'updated_at': winnerMs,
      'deleted_at': d['deleted'] == true ? winnerMs : null,
    });
    for (final i in inputs) {
      await txn.insert('expense_participants',
          {'expense_id': id, 'user_id': i.userId, 'input_value': i.value});
    }
    for (final e in splits.entries) {
      await txn.insert('expense_splits', {'expense_id': id, 'user_id': e.key, 'owed_minor': e.value});
    }
  }

  Future<void> _writeSettlement(Transaction txn, MergeResult m, String groupId) async {
    final d = m.data;
    final id = m.root.entityId;
    final winnerMs = Hlc.parse(m.winner.hlc).millis;
    await txn.delete('settlements', where: 'id = ?', whereArgs: [id]);
    await txn.insert('settlements', {
      'id': id,
      'group_id': groupId,
      'from_user_id': d['from'],
      'to_user_id': d['to'],
      'amount_minor': d['amount_minor'],
      'currency': d['currency'],
      'settled_at': d['settled_at'],
      'method': d['method'],
      'note': d['note'],
      'created_by': m.root.authorUserId,
      'created_device_id': m.root.originDeviceId,
      'conflicted': m.financialConflict ? 1 : 0,
      'head_change_id': m.winner.changeId,
      'created_at': Hlc.parse(m.root.hlc).millis,
      'updated_at': winnerMs,
      'voided_at': d['voided'] == true ? winnerMs : null,
      'void_reason': d['void_reason'],
    });
  }

  Future<void> _ensureUser(
      Transaction txn, String id, String name, String? ed, String? x) async {
    final r = await txn.query('users', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) {
      await txn.insert('users', {
        'id': id,
        'display_name': name,
        'ed25519_pub': ed,
        'x25519_pub': x,
        'is_local': id == identity.userId ? 1 : 0,
        'created_at': _now(),
        'updated_at': _now(),
      });
      return;
    }
    final row = r.first;
    final updates = <String, Object?>{};
    if (row['is_local'] != 1 && row['display_name'] != name) updates['display_name'] = name;
    if (row['ed25519_pub'] == null && ed != null) updates['ed25519_pub'] = ed;
    if (row['x25519_pub'] == null && x != null) updates['x25519_pub'] = x;
    if (updates.isNotEmpty) {
      updates['updated_at'] = _now();
      await txn.update('users', updates, where: 'id = ?', whereArgs: [id]);
    }
  }

  // ------------------------------------------------------------ conflicts

  Future<void> _syncConflict(Transaction txn, EntityType type, String entityId,
      String groupId, MergeResult m) async {
    final existing = await txn.query('sync_conflicts',
        where: 'entity_type = ? AND entity_id = ? AND kind = ?',
        whereArgs: [type.name, entityId, 'concurrent_edit']);
    if (m.financialConflict) {
      final heads = jsonEncode(m.heads);
      if (existing.isEmpty) {
        await txn.insert('sync_conflicts', {
          'id': const Uuid().v4(),
          'entity_type': type.name,
          'entity_id': entityId,
          'group_id': groupId,
          'kind': 'concurrent_edit',
          'head_ids': heads,
          'detected_at': _now(),
        });
      } else if (existing.first['head_ids'] != heads || existing.first['resolved_at'] != null) {
        await txn.update('sync_conflicts',
            {'head_ids': heads, 'resolved_at': null, 'resolution': null, 'detected_at': _now()},
            where: 'id = ?', whereArgs: [existing.first['id']]);
      }
    } else if (existing.isNotEmpty && existing.first['resolved_at'] == null) {
      await txn.update('sync_conflicts', {'resolved_at': _now(), 'resolution': 'merged'},
          where: 'id = ?', whereArgs: [existing.first['id']]);
    }
  }

  Future<void> _detectDuplicateSettlements(Transaction txn, String groupId) async {
    final rows = await txn.query('settlements',
        where: 'group_id = ? AND voided_at IS NULL', whereArgs: [groupId], orderBy: 'id');
    final flagged = <String, String>{};
    for (var i = 0; i < rows.length; i++) {
      for (var j = i + 1; j < rows.length; j++) {
        final a = rows[i], b = rows[j];
        if (a['from_user_id'] == b['from_user_id'] &&
            a['to_user_id'] == b['to_user_id'] &&
            a['amount_minor'] == b['amount_minor'] &&
            a['currency'] == b['currency'] &&
            a['created_device_id'] != b['created_device_id'] &&
            ((a['settled_at']! as int) - (b['settled_at']! as int)).abs() <=
                duplicateSettlementWindow.inMilliseconds) {
          flagged[b['id']! as String] = a['id']! as String;
        }
      }
    }
    final existing = await txn.query('sync_conflicts',
        where: 'group_id = ? AND kind = ?', whereArgs: [groupId, 'possible_duplicate']);
    final byEntity = {for (final r in existing) r['entity_id']! as String: r};
    for (final e in flagged.entries) {
      final row = byEntity[e.key];
      final heads = jsonEncode([e.value, e.key]);
      if (row == null) {
        await txn.insert('sync_conflicts', {
          'id': const Uuid().v4(),
          'entity_type': 'settlement',
          'entity_id': e.key,
          'group_id': groupId,
          'kind': 'possible_duplicate',
          'head_ids': heads,
          'details': jsonEncode({'other_settlement_id': e.value}),
          'detected_at': _now(),
        });
      }
    }
    for (final r in existing) {
      if (!flagged.containsKey(r['entity_id']) && r['resolved_at'] == null) {
        await txn.update('sync_conflicts', {'resolved_at': _now(), 'resolution': 'voided'},
            where: 'id = ?', whereArgs: [r['id']]);
      }
    }
  }

  // ------------------------------------------------------------- activity

  Future<void> _logActivity(Transaction txn, SyncChange c, {required bool remote}) async {
    Future<String> name(String? id) async {
      if (id == null) return 'Someone';
      if (id == identity.userId) return 'You';
      final r = await txn.query('users', columns: ['display_name'], where: 'id = ?', whereArgs: [id]);
      return r.isEmpty ? 'Someone' : r.first['display_name']! as String;
    }

    final d = c.data;
    final actor = await name(c.authorUserId);
    final created = c.parents.isEmpty;
    String action;
    String summary;
    switch (c.type) {
      case EntityType.group:
        action = created ? 'created' : (d['archived'] == true ? 'archived' : 'updated');
        summary = '$actor ${created ? 'created' : 'updated'} the group "${d['name']}"';
      case EntityType.member:
        final who = await name(d['user_id'] as String?);
        action = d['status'] == 'removed' ? 'removed' : (created ? 'added' : 'updated');
        summary = switch (action) {
          'removed' => '$actor removed $who',
          'added' => '$actor added $who',
          _ => '$actor changed $who to ${d['role']}',
        };
      case EntityType.expense:
        final amount = formatMoney(d['amount_minor']! as int, d['currency']! as String);
        action = d['deleted'] == true ? 'deleted' : (created ? 'created' : 'updated');
        summary = '$actor $action "${d['description']}" ($amount)';
      case EntityType.settlement:
        final amount = formatMoney(d['amount_minor']! as int, d['currency']! as String);
        final from = await name(d['from'] as String?);
        final to = await name(d['to'] as String?);
        action = d['voided'] == true ? 'voided' : 'recorded';
        summary = d['voided'] == true
            ? '$actor voided a payment of $amount from $from to $to'
            : '$actor recorded that $from paid $to $amount';
    }
    await txn.insert(
      'activity_logs',
      {
        'id': const Uuid().v4(),
        'group_id': c.groupId,
        'entity_type': c.type.name,
        'entity_id': c.entityId,
        'action': action,
        'actor_id': c.authorUserId,
        'summary': summary,
        'change_id': c.changeId,
        'is_remote': remote ? 1 : 0,
        'created_at': Hlc.parse(c.hlc).millis,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // -------------------------------------------------------------- queries

  Future<List<String>> _heads(DatabaseExecutor ex, EntityType type, String entityId) async {
    final rows = await ex.query('sync_changes',
        columns: ['change_id', 'parents'],
        where: 'entity_type = ? AND entity_id = ? AND status = ?',
        whereArgs: [type.name, entityId, 'applied']);
    final referenced = <String>{
      for (final r in rows) ...(jsonDecode(r['parents']! as String) as List).cast<String>(),
    };
    return [
      for (final r in rows)
        if (!referenced.contains(r['change_id'])) r['change_id']! as String,
    ]..sort();
  }

  Future<List<String>> heads(EntityType type, String entityId, [DatabaseExecutor? ex]) =>
      _heads(ex ?? db, type, entityId);

  Future<List<SyncChange>> _appliedForEntity(
      DatabaseExecutor ex, EntityType type, String entityId) async {
    final rows = await ex.query('sync_changes',
        where: 'entity_type = ? AND entity_id = ? AND status = ?',
        whereArgs: [type.name, entityId, 'applied']);
    return rows.map(SyncChange.fromRow).toList();
  }

  /// Full revision history of an entity, oldest first.
  Future<List<SyncChange>> history(EntityType type, String entityId) async {
    final list = await _appliedForEntity(db, type, entityId);
    list.sort((a, b) => a.hlc.compareTo(b.hlc));
    return list;
  }

  Future<SyncChange?> change(String id) async {
    final r = await db.query('sync_changes', where: 'change_id = ?', whereArgs: [id]);
    return r.isEmpty ? null : SyncChange.fromRow(r.first);
  }

  Future<GroupState> _loadGroupState(DatabaseExecutor ex, String groupId) async {
    final s = GroupState(groupId);
    final g = await ex.query('groups', where: 'id = ?', whereArgs: [groupId]);
    if (g.isEmpty) return s;
    s.exists = true;
    s.creatorId = g.first['created_by']! as String;
    s.type = g.first['type']! as String;
    final rows = await ex.rawQuery('''
      SELECT m.user_id, m.role, m.status, m.joined_hlc, m.removed_hlc,
             u.display_name, u.ed25519_pub, u.x25519_pub
      FROM group_members m JOIN users u ON u.id = m.user_id
      WHERE m.group_id = ?''', [groupId]);
    final merged = jsonDecode(await _meta(ex, 'merged_into:$groupId') ?? '{}') as Map;
    for (final r in rows) {
      final id = r['user_id']! as String;
      s.members[id] = MemberState(
        userId: id,
        displayName: r['display_name']! as String,
        role: r['role']! as String,
        status: r['status']! as String,
        joinedHlc: r['joined_hlc']! as String,
        removedHlc: r['removed_hlc'] as String?,
        ed25519Pub: r['ed25519_pub'] as String?,
        x25519Pub: r['x25519_pub'] as String?,
        mergedInto: merged[id] as String?,
      );
    }
    return s;
  }

  Future<GroupState> groupState(String groupId, [DatabaseExecutor? ex]) =>
      _loadGroupState(ex ?? db, groupId);

  /// Keys verified directly through pairing (plus our own).
  Future<Map<String, String>> _pairedKeys(DatabaseExecutor ex) async {
    final rows = await ex.query('sync_devices',
        columns: ['user_id', 'ed25519_pub'], where: 'status = ?', whereArgs: ['paired']);
    return {
      for (final r in rows) r['user_id']! as String: r['ed25519_pub']! as String,
      identity.userId: identity.ed25519Pub,
    };
  }

  /// Highest stored origin sequence per origin device, for one group.
  Future<Map<String, int>> vectorFor(String groupId) async {
    final rows = await db.rawQuery(
        'SELECT origin_device_id, MAX(origin_seq) AS s FROM sync_changes '
        'WHERE group_id = ? GROUP BY origin_device_id',
        [groupId]);
    return {for (final r in rows) r['origin_device_id']! as String: r['s']! as int};
  }

  /// Changes of [groupId] the holder of [vector] is missing, in ascending
  /// (origin, seq) order so the receiver always stores a gap-free prefix.
  Future<List<SyncChange>> missingFor(String groupId, Map<String, int> vector) async {
    final rows = await db.query('sync_changes',
        where: "group_id = ? AND (status_reason IS NULL OR status_reason NOT LIKE 'invalid:%')",
        whereArgs: [groupId],
        orderBy: 'origin_device_id, origin_seq');
    return [
      for (final r in rows)
        if ((r['origin_seq']! as int) > (vector[r['origin_device_id']] ?? 0))
          SyncChange.fromRow(r),
    ];
  }

  Future<void> resetIdentity(LocalIdentity id) async {
    identity = id;
    await init();
  }
}

Future<String?> _meta(DatabaseExecutor ex, String key) async {
  final r = await ex.query('app_meta', where: 'key = ?', whereArgs: [key]);
  return r.isEmpty ? null : r.first['value'] as String?;
}

Future<void> _setMeta(DatabaseExecutor ex, String key, String? value) => ex.insert(
    'app_meta', {'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace);

Future<String?> readMeta(DatabaseExecutor ex, String key) => _meta(ex, key);
Future<void> writeMeta(DatabaseExecutor ex, String key, String? value) =>
    _setMeta(ex, key, value);
