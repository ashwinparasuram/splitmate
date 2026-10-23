import '../core/canonical_json.dart';
import 'change.dart';

/// Fields merged as one unit, where concurrent different values are a
/// conflict needing a human decision (docs/DESIGN.md §7).
const Map<EntityType, List<String>> financialFields = {
  EntityType.expense: [
    'amount_minor',
    'currency',
    'payer_id',
    'split_type',
    'participants',
    'deleted',
  ],
  EntityType.settlement: ['from', 'to', 'amount_minor', 'currency', 'voided'],
  EntityType.group: [],
  EntityType.member: [],
};

class MergeResult {
  MergeResult({
    required this.data,
    required this.heads,
    required this.winner,
    required this.root,
    required this.financialConflict,
  });

  /// The materialised snapshot.
  final Map<String, Object?> data;

  /// Current head change ids, sorted.
  final List<String> heads;

  /// The deterministic winning head (highest hlc, then id).
  final SyncChange winner;

  /// The earliest change (creation), used for created_by / created_at.
  final SyncChange root;

  /// True when concurrent heads disagree on the financial component.
  final bool financialConflict;
}

int _order(SyncChange a, SyncChange b) {
  final c = a.hlc.compareTo(b.hlc);
  return c != 0 ? c : a.changeId.compareTo(b.changeId);
}

/// Deterministically merges all accepted changes of one entity.
///
/// The output depends only on the *set* of changes, never on arrival order,
/// which is what lets every device converge to identical balances.
MergeResult mergeEntity(List<SyncChange> changes) {
  if (changes.isEmpty) throw ArgumentError('no changes');
  final byId = {for (final c in changes) c.changeId: c};
  final referenced = <String>{for (final c in changes) ...c.parents};
  final heads = changes.where((c) => !referenced.contains(c.changeId)).toList()
    ..sort(_order);
  final sorted = [...changes]..sort(_order);
  final root = sorted.firstWhere((c) => c.parents.isEmpty, orElse: () => sorted.first);
  final winner = heads.last;

  if (heads.length == 1) {
    return MergeResult(
      data: Map.of(winner.data),
      heads: [winner.changeId],
      winner: winner,
      root: root,
      financialConflict: false,
    );
  }

  // Latest common ancestor of all heads.
  Set<String> ancestors(String id) {
    final seen = <String>{};
    final stack = [id];
    while (stack.isNotEmpty) {
      final cur = stack.removeLast();
      if (!seen.add(cur)) continue;
      final c = byId[cur];
      if (c != null) stack.addAll(c.parents);
    }
    return seen;
  }

  Set<String>? common;
  for (final h in heads) {
    final a = ancestors(h.changeId);
    common = common == null ? a : common.intersection(a);
  }
  final commonChanges = common!.map((id) => byId[id]).whereType<SyncChange>().toList()
    ..sort(_order);
  final base = commonChanges.isEmpty ? const <String, Object?>{} : commonChanges.last.data;

  final type = winner.type;
  final financial = financialFields[type]!;
  final keys = <String>{
    ...base.keys,
    for (final h in heads) ...h.data.keys,
  }..removeAll(financial);

  final out = <String, Object?>{};
  var conflict = false;

  // Picks the merged value of one component and reports disagreement.
  (Object?, bool) pick(Object? Function(Map<String, Object?>) read) {
    final baseValue = read(base);
    final changed = heads.where((h) => !jsonEquals(read(h.data), baseValue)).toList();
    if (changed.isEmpty) return (baseValue, false);
    final distinct = <String>{for (final h in changed) canonicalJson(read(h.data))};
    // `changed` is sorted ascending, so last is the deterministic winner.
    return (read(changed.last.data), distinct.length > 1);
  }

  if (financial.isNotEmpty) {
    final (value, disagree) =
        pick((d) => {for (final f in financial) f: d[f]});
    (value! as Map<String, Object?>).forEach((k, v) {
      if (v != null) out[k] = v;
    });
    conflict = disagree;
  }
  for (final k in keys) {
    final (value, _) = pick((d) => d[k]);
    if (value != null) out[k] = value;
  }

  return MergeResult(
    data: out,
    heads: heads.map((h) => h.changeId).toList()..sort(),
    winner: winner,
    root: root,
    financialConflict: conflict,
  );
}
