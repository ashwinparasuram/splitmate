import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../domain/balance_calculator.dart';
import '../domain/models.dart';
import '../domain/split_calculator.dart';
import '../sync/change.dart';
import '../sync/change_log.dart';
import '../sync/group_state.dart';

/// Commands and queries over the local ledger. Every command is one SQLite
/// transaction that appends signed changes through [ChangeLog].
class LedgerRepository {
  LedgerRepository(this.log);

  final ChangeLog log;
  Database get db => log.db;
  String get me => log.identity.userId;

  final _changes = StreamController<void>.broadcast();

  /// Fires after any local or remote modification.
  Stream<void> get changes => _changes.stream;
  void notifyChanged() => _changes.add(null);

  Future<T> _write<T>(Future<T> Function(Transaction txn) action) async {
    final r = await log.transaction(action);
    notifyChanged();
    return r;
  }

  // ------------------------------------------------------------- profile

  Future<void> ensureLocalUser() async {
    final id = log.identity;
    final now = log.now();
    final existing = await db.query('users', where: 'id = ?', whereArgs: [id.userId]);
    if (existing.isEmpty) {
      await db.insert('users', {
        'id': id.userId,
        'display_name': id.displayName,
        'ed25519_pub': id.ed25519Pub,
        'x25519_pub': id.x25519Pub,
        'is_local': 1,
        'created_at': now,
        'updated_at': now,
      });
    } else {
      await db.update(
          'users',
          {
            'display_name': id.displayName,
            'ed25519_pub': id.ed25519Pub,
            'x25519_pub': id.x25519Pub,
            'is_local': 1,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [id.userId]);
    }
  }

  Map<String, Object?> _creatorData() => {
        'user_id': me,
        'display_name': log.identity.displayName,
        'ed25519_pub': log.identity.ed25519Pub,
        'x25519_pub': log.identity.x25519Pub,
      };

  // -------------------------------------------------------------- groups

  Future<String> createGroup(String name, String currency, {String type = 'group'}) =>
      _write((txn) async {
        final id = const Uuid().v4();
        await writeMeta(txn, 'consent:$id', 'active');
        await log.append(txn,
            type: EntityType.group,
            entityId: id,
            groupId: id,
            data: {
              'name': name.trim(),
              'type': type,
              'default_currency': currency,
              'archived': false,
              'creator': _creatorData(),
            });
        return id;
      });

  Future<void> updateGroup(String groupId, {String? name, String? currency, bool? archived}) =>
      _write((txn) async {
        final g = (await txn.query('groups', where: 'id = ?', whereArgs: [groupId])).first;
        final root = await _rootData(txn, EntityType.group, groupId);
        await log.append(txn,
            type: EntityType.group,
            entityId: groupId,
            groupId: groupId,
            data: {
              'name': name?.trim() ?? g['name'],
              'type': g['type'],
              'default_currency': currency ?? g['default_currency'],
              'archived': archived ?? g['archived'] == 1,
              'creator': root['creator'],
            });
      });

  Future<Map<String, Object?>> _rootData(
      DatabaseExecutor ex, EntityType type, String entityId) async {
    final r = await ex.query('sync_changes',
        where: "entity_type = ? AND entity_id = ? AND parents = '[]' AND status = 'applied'",
        whereArgs: [type.name, entityId],
        orderBy: 'hlc',
        limit: 1);
    return SyncChange.fromRow(r.first).data;
  }

  /// Answers an invitation to a group someone else shared with us.
  Future<void> setGroupConsent(String groupId, bool accept) => _write((txn) async {
        final status = accept ? 'active' : 'declined';
        await writeMeta(txn, 'consent:$groupId', status);
        await txn.update('groups', {'local_status': status}, where: 'id = ?', whereArgs: [groupId]);
      });

  /// Adds someone who has not connected a device yet.
  Future<String> addPlaceholderMember(String groupId, String displayName) =>
      _write((txn) async {
        final userId = const Uuid().v4();
        await _putMember(txn, groupId,
            userId: userId, name: displayName.trim(), role: 'member', status: 'active');
        await _addFriend(txn, userId);
        return userId;
      });

  /// Adds (or updates) a member whose keys were verified during pairing.
  Future<void> addVerifiedMember(
    String groupId, {
    required String userId,
    required String displayName,
    required String ed25519Pub,
    required String x25519Pub,
    String role = 'member',
  }) =>
      _write((txn) => _addVerifiedMember(txn, groupId,
          userId: userId,
          displayName: displayName,
          ed25519Pub: ed25519Pub,
          x25519Pub: x25519Pub,
          role: role));

  Future<void> _addVerifiedMember(
    Transaction txn,
    String groupId, {
    required String userId,
    required String displayName,
    required String ed25519Pub,
    required String x25519Pub,
    String role = 'member',
  }) async {
    final state = await log.groupState(groupId, txn);
    final current = state[userId];
    if (current != null &&
        current.isActive &&
        current.ed25519Pub == ed25519Pub &&
        current.x25519Pub == x25519Pub) {
      return;
    }
    await _putMember(txn, groupId,
        userId: userId,
        name: displayName,
        role: current?.role ?? role,
        status: 'active',
        ed25519Pub: ed25519Pub,
        x25519Pub: x25519Pub);
    await _addFriend(txn, userId);
  }

  /// Links a placeholder (added before they had the app) to their real
  /// identity. Old expenses keep the placeholder id; balances alias it.
  Future<void> linkPlaceholder(String groupId, String placeholderId, String realUserId) =>
      _write((txn) async {
        final s = await log.groupState(groupId, txn);
        final p = s[placeholderId]!;
        await _putMember(txn, groupId,
            userId: placeholderId,
            name: p.displayName,
            role: p.role,
            status: 'removed',
            mergedInto: realUserId);
      });

  Future<void> setMemberRole(String groupId, String userId, String role) =>
      _write((txn) async {
        final m = (await log.groupState(groupId, txn))[userId]!;
        await _putMember(txn, groupId,
            userId: userId,
            name: m.displayName,
            role: role,
            status: m.status,
            ed25519Pub: m.ed25519Pub,
            x25519Pub: m.x25519Pub,
            mergedInto: m.mergedInto);
      });

  /// Marks a member removed. Their expenses and balances stay intact.
  Future<void> removeMember(String groupId, String userId) => _write((txn) async {
        final m = (await log.groupState(groupId, txn))[userId]!;
        await _putMember(txn, groupId,
            userId: userId,
            name: m.displayName,
            role: m.role,
            status: 'removed',
            ed25519Pub: m.ed25519Pub,
            x25519Pub: m.x25519Pub,
            mergedInto: m.mergedInto);
      });

  Future<void> _putMember(
    Transaction txn,
    String groupId, {
    required String userId,
    required String name,
    required String role,
    required String status,
    String? ed25519Pub,
    String? x25519Pub,
    String? mergedInto,
  }) async {
    await log.append(txn,
        type: EntityType.member,
        entityId: memberEntityId(groupId, userId),
        groupId: groupId,
        data: {
          'user_id': userId,
          'display_name': name,
          'role': role,
          'status': status,
          if (ed25519Pub != null) 'ed25519_pub': ed25519Pub,
          if (x25519Pub != null) 'x25519_pub': x25519Pub,
          if (mergedInto != null) 'merged_into': mergedInto,
        });
  }

  Future<void> _addFriend(DatabaseExecutor ex, String userId) async {
    if (userId == me) return;
    await ex.insert(
        'friends', {'user_id': userId, 'created_at': log.now(), 'updated_at': log.now()},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await ex.update('friends', {'deleted_at': null},
        where: 'user_id = ? AND deleted_at IS NOT NULL', whereArgs: [userId]);
  }

  /// A friend outside any group: creates a hidden two-person group.
  Future<String> addFriend(String displayName, String currency) async {
    final groupId = await createGroup(displayName.trim(), currency, type: 'direct');
    await addPlaceholderMember(groupId, displayName);
    return groupId;
  }

  Future<String?> directGroupWith(String userId) async {
    final r = await db.rawQuery('''
      SELECT g.id FROM groups g
      JOIN group_members m ON m.group_id = g.id AND m.user_id = ? AND m.status = 'active'
      WHERE g.type = 'direct' AND g.deleted_at IS NULL
      ORDER BY g.created_at LIMIT 1''', [userId]);
    return r.isEmpty ? null : r.first['id']! as String;
  }

  Future<String> ensureDirectGroup(String userId, String currency) async {
    final existing = await directGroupWith(userId);
    if (existing != null) return existing;
    final person = await this.person(userId);
    final groupId = await createGroup(person?.name ?? 'Friend', currency, type: 'direct');
    final keys = await db.query('users', where: 'id = ?', whereArgs: [userId]);
    final row = keys.first;
    if (row['ed25519_pub'] != null) {
      await addVerifiedMember(groupId,
          userId: userId,
          displayName: row['display_name']! as String,
          ed25519Pub: row['ed25519_pub']! as String,
          x25519Pub: row['x25519_pub']! as String);
    } else {
      await _write((txn) => _putMember(txn, groupId,
          userId: userId, name: row['display_name']! as String, role: 'member', status: 'active'));
    }
    return groupId;
  }

  // ------------------------------------------------------------ expenses

  Future<String> addExpense(ExpenseDraft draft, {String? id}) => _write((txn) async {
        final expenseId = id ?? const Uuid().v4();
        final exists = await txn.query('expenses', where: 'id = ?', whereArgs: [expenseId]);
        if (exists.isNotEmpty) return expenseId; // double-tap on Save
        await log.append(txn,
            type: EntityType.expense,
            entityId: expenseId,
            groupId: draft.groupId,
            data: draft.toData());
        return expenseId;
      });

  Future<void> editExpense(String expenseId, ExpenseDraft draft) => _write((txn) async {
        await log.append(txn,
            type: EntityType.expense,
            entityId: expenseId,
            groupId: draft.groupId,
            data: draft.toData());
      });

  Future<void> deleteExpense(String expenseId) => _write((txn) async {
        final e = await _expense(txn, expenseId);
        await log.append(txn,
            type: EntityType.expense,
            entityId: expenseId,
            groupId: e!.groupId,
            data: _draftOf(e).toData(deleted: true));
      });

  Future<void> restoreExpense(String expenseId) => _write((txn) async {
        final e = await _expense(txn, expenseId);
        await log.append(txn,
            type: EntityType.expense,
            entityId: expenseId,
            groupId: e!.groupId,
            data: _draftOf(e).toData());
      });

  Future<void> setReceipt(String expenseId, String? path) async {
    await db.update('expenses', {'receipt_path': path}, where: 'id = ?', whereArgs: [expenseId]);
    notifyChanged();
  }

  ExpenseDraft _draftOf(Expense e) => ExpenseDraft(
        groupId: e.groupId,
        description: e.description,
        amountMinor: e.amountMinor,
        currency: e.currency,
        payerId: e.payerId,
        splitType: e.splitType,
        participants: e.participants,
        expenseDate: e.expenseDate,
        category: e.category,
        notes: e.notes,
      );

  // --------------------------------------------------------- settlements

  /// Records that [fromUserId] paid [toUserId] outside the app. Idempotent by
  /// [id]: the settle-up screen generates it once, so retries and double
  /// taps never create a second settlement.
  Future<String> recordSettlement({
    required String id,
    required String groupId,
    required String fromUserId,
    required String toUserId,
    required int amountMinor,
    required String currency,
    String method = 'cash',
    String? note,
    int? settledAt,
  }) =>
      _write((txn) async {
        final exists = await txn.query('sync_changes',
            where: 'entity_type = ? AND entity_id = ?', whereArgs: ['settlement', id]);
        if (exists.isNotEmpty) return id;
        await log.append(txn,
            type: EntityType.settlement,
            entityId: id,
            groupId: groupId,
            data: {
              'from': fromUserId,
              'to': toUserId,
              'amount_minor': amountMinor,
              'currency': currency,
              'settled_at': settledAt ?? log.now(),
              'method': method,
              if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
              'voided': false,
            });
        return id;
      });

  Future<void> voidSettlement(String settlementId, String reason) => _write((txn) async {
        final r = await txn.query('settlements', where: 'id = ?', whereArgs: [settlementId]);
        final s = Settlement.fromRow(r.first);
        if (s.voided) return;
        await log.append(txn,
            type: EntityType.settlement,
            entityId: settlementId,
            groupId: s.groupId,
            data: {
              'from': s.fromUserId,
              'to': s.toUserId,
              'amount_minor': s.amountMinor,
              'currency': s.currency,
              'settled_at': s.settledAt,
              'method': s.method,
              if (s.note != null) 'note': s.note,
              'voided': true,
              'void_reason': reason.trim().isEmpty ? 'Voided' : reason.trim(),
            });
      });

  // ----------------------------------------------------------- conflicts

  /// Resolves a concurrent edit by re-asserting [chosenChangeId]'s snapshot
  /// (or [data]) on top of every current head.
  Future<void> resolveConflict(
      EntityType type, String entityId, String chosenChangeId, {Map<String, Object?>? data}) =>
      _write((txn) async {
        final chosen = SyncChange.fromRow((await txn.query('sync_changes',
                where: 'change_id = ?', whereArgs: [chosenChangeId]))
            .first);
        final heads = await log.heads(type, entityId, txn);
        var payload = data ?? chosen.data;
        if (type == EntityType.settlement) {
          // A settlement merge may only choose voided state; never resurrect.
          final anyVoided = await txn.query('settlements',
              where: 'id = ? AND voided_at IS NOT NULL', whereArgs: [entityId]);
          if (anyVoided.isNotEmpty && payload['voided'] != true) {
            payload = {...payload, 'voided': true, 'void_reason': 'Resolved conflict'};
          }
        }
        await log.append(txn,
            type: type, entityId: entityId, groupId: chosen.groupId, data: payload, parents: heads);
      });

  Future<void> dismissConflict(String conflictId) async {
    await db.update('sync_conflicts', {'resolved_at': log.now(), 'resolution': 'kept_both'},
        where: 'id = ?', whereArgs: [conflictId]);
    notifyChanged();
  }

  Future<List<ConflictInfo>> openConflicts({String? groupId}) async {
    final rows = await db.query('sync_conflicts',
        where: 'resolved_at IS NULL${groupId == null ? '' : ' AND group_id = ?'}',
        whereArgs: groupId == null ? null : [groupId],
        orderBy: 'detected_at DESC');
    return [
      for (final r in rows)
        ConflictInfo(
          id: r['id']! as String,
          entityType: r['entity_type']! as String,
          entityId: r['entity_id']! as String,
          groupId: r['group_id']! as String,
          kind: r['kind']! as String,
          headIds: (jsonDecode(r['head_ids']! as String) as List).cast<String>(),
          detectedAt: r['detected_at']! as int,
        ),
    ];
  }

  // ------------------------------------------------------------- queries

  Future<Person?> person(String id) async {
    final r = await db.query('users', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Person.fromRow(r.first);
  }

  Future<Map<String, Person>> people() async {
    final r = await db.query('users');
    return {for (final row in r) row['id']! as String: Person.fromRow(row)};
  }

  Future<List<Group>> groups({bool includeArchived = true, bool includeDirect = false}) async {
    final rows = await db.query('groups',
        where: [
          'deleted_at IS NULL',
          "local_status <> 'declined'",
          if (!includeArchived) 'archived = 0',
          if (!includeDirect) "type = 'group'",
        ].join(' AND '),
        orderBy: 'updated_at DESC');
    return rows.map(Group.fromRow).toList();
  }

  Future<Group?> group(String id) async {
    final r = await db.query('groups', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Group.fromRow(r.first);
  }

  Future<List<Member>> members(String groupId) async {
    final rows = await db.rawQuery('''
      SELECT u.*, m.role, m.status FROM group_members m
      JOIN users u ON u.id = m.user_id
      WHERE m.group_id = ? ORDER BY m.status, u.display_name COLLATE NOCASE''', [groupId]);
    return [
      for (final r in rows)
        Member(person: Person.fromRow(r), role: r['role']! as String, status: r['status']! as String),
    ];
  }

  Future<Expense?> _expense(DatabaseExecutor ex, String id) async {
    final r = await ex.query('expenses', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) return null;
    final parts = await ex.query('expense_participants', where: 'expense_id = ?', whereArgs: [id]);
    final splits = await ex.query('expense_splits', where: 'expense_id = ?', whereArgs: [id]);
    return Expense.fromRow(r.first,
        participants: [
          for (final p in parts) SplitInput(p['user_id']! as String, p['input_value']! as int),
        ],
        splits: {for (final s in splits) s['user_id']! as String: s['owed_minor']! as int});
  }

  Future<Expense?> expense(String id) => _expense(db, id);

  Future<List<Expense>> expenses({String? groupId, bool includeDeleted = false, int? limit}) async {
    final where = [
      if (groupId != null) 'e.group_id = ?',
      if (!includeDeleted) 'e.deleted_at IS NULL',
      "g.local_status <> 'declined'",
    ];
    final rows = await db.rawQuery('''
      SELECT e.* FROM expenses e JOIN groups g ON g.id = e.group_id
      WHERE ${where.join(' AND ')}
      ORDER BY e.expense_date DESC, e.created_at DESC
      ${limit != null ? 'LIMIT $limit' : ''}''', [if (groupId != null) groupId]);
    if (rows.isEmpty) return [];
    final ids = rows.map((r) => r['id']).toList();
    final marks = List.filled(ids.length, '?').join(',');
    final splits = await db.rawQuery(
        'SELECT * FROM expense_splits WHERE expense_id IN ($marks)', ids);
    final parts = await db.rawQuery(
        'SELECT * FROM expense_participants WHERE expense_id IN ($marks)', ids);
    final splitMap = <String, Map<String, int>>{};
    for (final s in splits) {
      splitMap.putIfAbsent(s['expense_id']! as String, () => {})[s['user_id']! as String] =
          s['owed_minor']! as int;
    }
    final partMap = <String, List<SplitInput>>{};
    for (final p in parts) {
      partMap.putIfAbsent(p['expense_id']! as String, () => []).add(
          SplitInput(p['user_id']! as String, p['input_value']! as int));
    }
    return [
      for (final r in rows)
        Expense.fromRow(r,
            participants: partMap[r['id']] ?? const [], splits: splitMap[r['id']] ?? const {}),
    ];
  }

  Future<List<Settlement>> settlements({String? groupId, bool includeVoided = true}) async {
    final rows = await db.query('settlements',
        where: [
          if (groupId != null) 'group_id = ?',
          if (!includeVoided) 'voided_at IS NULL',
        ].join(' AND ').let((w) => w.isEmpty ? null : w),
        whereArgs: groupId == null ? null : [groupId],
        orderBy: 'settled_at DESC');
    return rows.map(Settlement.fromRow).toList();
  }

  Future<Map<String, String>> _aliases() async {
    final rows = await db.query('app_meta', where: "key LIKE 'merged_into:%'");
    final out = <String, String>{};
    for (final r in rows) {
      (jsonDecode(r['value']! as String) as Map)
          .forEach((k, v) => out[k as String] = v as String);
    }
    return out;
  }

  /// Balances derived from accepted, non-deleted expenses and non-voided
  /// settlements. Groups the user declined are excluded.
  Future<Balances> balances({String? groupId}) async {
    final aliases = await _aliases();
    String a(String id) {
      var cur = id;
      for (var i = 0; i < 8 && aliases.containsKey(cur); i++) {
        cur = aliases[cur]!;
      }
      return cur;
    }

    final expenses = await this.expenses(groupId: groupId);
    final settlements = await this.settlements(groupId: groupId, includeVoided: false);
    final active = {
      for (final g in await db.query('groups',
          columns: ['id'], where: "local_status <> 'declined' AND deleted_at IS NULL"))
        g['id']! as String,
    };
    return Balances.compute(
      [
        for (final e in expenses)
          if (active.contains(e.groupId))
            LedgerExpense(
              payerId: a(e.payerId),
              currency: e.currency,
              groupId: e.groupId,
              splits: {
                for (final s in e.splits.entries) a(s.key): s.value,
              },
            ),
      ],
      [
        for (final s in settlements)
          if (active.contains(s.groupId))
            LedgerSettlement(
              fromUserId: a(s.fromUserId),
              toUserId: a(s.toUserId),
              amountMinor: s.amountMinor,
              currency: s.currency,
              groupId: s.groupId,
            ),
      ],
    );
  }

  Future<List<ActivityEntry>> activity({String? groupId, int limit = 200}) async {
    final rows = await db.query('activity_logs',
        where: groupId == null ? null : 'group_id = ?',
        whereArgs: groupId == null ? null : [groupId],
        orderBy: 'created_at DESC',
        limit: limit);
    return rows.map(ActivityEntry.fromRow).toList();
  }

  Future<List<Person>> friends() async {
    final rows = await db.rawQuery('''
      SELECT u.* FROM friends f JOIN users u ON u.id = f.user_id
      WHERE f.deleted_at IS NULL ORDER BY u.display_name COLLATE NOCASE''');
    return rows.map(Person.fromRow).toList();
  }

  /// Local changes no paired peer is known to hold yet.
  Future<int> unsyncedLocalChanges() async {
    final peers = await db.query('sync_devices', columns: ['peer_vector']);
    final vectors = [
      for (final p in peers) (jsonDecode(p['peer_vector']! as String) as Map).cast<String, Object?>(),
    ];
    final rows = await db.query('sync_changes',
        columns: ['group_id', 'origin_seq'],
        where: 'is_local = 1 AND origin_device_id = ?',
        whereArgs: [log.identity.deviceId]);
    var count = 0;
    for (final r in rows) {
      final g = r['group_id']! as String;
      final seq = r['origin_seq']! as int;
      final held = vectors.any((v) {
        final gv = v[g];
        return gv is Map && ((gv[log.identity.deviceId] as int?) ?? 0) >= seq;
      });
      if (!held) count++;
    }
    return count;
  }

  Future<int> pendingRemoteChanges() async {
    final r = await db.rawQuery("SELECT COUNT(*) AS n FROM sync_changes WHERE status = 'pending'");
    return r.first['n']! as int;
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
