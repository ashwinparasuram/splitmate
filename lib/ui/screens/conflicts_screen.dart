import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/hlc.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../sync/change.dart';
import '../widgets/common.dart';
import 'group_detail_screen.dart';

/// Lets the user decide concurrent financial edits and possible duplicates.
class ConflictsScreen extends ConsumerWidget {
  const ConflictsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(conflictsProvider(null));
    return Scaffold(
      appBar: AppBar(title: const Text('Conflicts')),
      body: AsyncView(
        value: conflicts,
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.verified_outlined,
                title: 'No conflicts',
                message: 'When two people change the same expense while offline, '
                    'SplitMate asks here instead of silently picking one.',
              )
            : ListView(padding: const EdgeInsets.all(12), children: [
                for (final c in list) _ConflictCard(conflict: c),
              ]),
      ),
    );
  }
}

class _ConflictCard extends ConsumerWidget {
  const _ConflictCard({required this.conflict});
  final ConflictInfo conflict;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(servicesProvider).log;
    final people = ref.watch(peopleProvider).value ?? const {};
    final me = ref.watch(meProvider);
    String n(String? id) => id == me ? 'You' : (people[id]?.name ?? 'Someone');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<List<SyncChange?>>(
          future: Future.wait(conflict.headIds.map(log.change)),
          builder: (context, snap) {
            final heads = snap.data?.whereType<SyncChange>().toList() ?? const [];
            if (conflict.kind == 'possible_duplicate') {
              return FutureBuilder<List<Settlement>>(
                future: ref.read(repoProvider).settlements(groupId: conflict.groupId),
                builder: (context, s) {
                  final pair = (s.data ?? const <Settlement>[])
                      .where((x) => conflict.headIds.contains(x.id))
                      .toList();
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Possible duplicate payment', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    const Text('Two phones recorded the same payment. Void one if it was recorded twice.'),
                    for (final p in pair)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${n(p.fromUserId)} paid ${n(p.toUserId)} '
                            '${formatMoney(p.amountMinor, p.currency)}'),
                        subtitle: Text('Recorded by ${n(p.createdBy)}${p.voided ? ' · voided' : ''}'),
                        trailing: p.voided
                            ? null
                            : TextButton(
                                onPressed: () => showVoidSettlementDialog(context, p),
                                child: const Text('Void')),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => ref.read(repoProvider).dismissConflict(conflict.id),
                        child: const Text('Both are real — keep both'),
                      ),
                    ),
                  ]);
                },
              );
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(conflict.entityType == 'expense' ? 'Expense edited on two devices' : 'Payment changed on two devices',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('Choose the correct version. Everyone gets your choice when they sync.'),
              const SizedBox(height: 8),
              for (final h in heads)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(h.data['deleted'] == true || h.data['voided'] == true
                            ? 'Deleted'
                            : '${h.data['description'] ?? 'Payment'} · '
                                '${formatMoney(h.data['amount_minor']! as int, h.data['currency']! as String)}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text('by ${n(h.authorUserId)} · ${timeAgo(Hlc.parse(h.hlc).millis)}',
                            style: Theme.of(context).textTheme.bodySmall),
                        if (h.data['payer_id'] != null)
                          Text('Paid by ${n(h.data['payer_id'] as String)}, '
                              '${(h.data['participants'] as List).length} people, ${h.data['split_type']}',
                              style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ),
                    FilledButton.tonal(
                      onPressed: () => ref.read(repoProvider).resolveConflict(
                          EntityType.values.byName(conflict.entityType), conflict.entityId, h.changeId),
                      child: const Text('Keep this'),
                    ),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }
}
