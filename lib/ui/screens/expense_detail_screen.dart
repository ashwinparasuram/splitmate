import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/hlc.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../sync/change.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _historyProvider = FutureProvider.family<List<SyncChange>, String>((ref, id) {
  ref.watch(ledgerTickProvider);
  return ref.watch(servicesProvider).log.history(EntityType.expense, id);
});

class ExpenseDetailScreen extends ConsumerWidget {
  const ExpenseDetailScreen({super.key, required this.expenseId});
  final String expenseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expense = ref.watch(expenseProvider(expenseId));
    final people = ref.watch(peopleProvider).value ?? const {};
    final me = ref.watch(meProvider);
    final history = ref.watch(_historyProvider(expenseId));
    String n(String id) => id == me ? 'You' : (people[id]?.name ?? 'Someone');

    return AsyncView(
      value: expense,
      builder: (e) {
        if (e == null) return const Scaffold(body: Center(child: Text('Expense not found')));
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Expense'),
            actions: [
              if (!e.deleted)
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => context.push('/expense/${e.id}/edit'),
                ),
              IconButton(
                tooltip: e.deleted ? 'Restore' : 'Delete',
                icon: Icon(e.deleted ? Icons.restore_from_trash : Icons.delete_outline),
                onPressed: () => _toggleDelete(context, ref, e),
              ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            if (e.conflicted)
              InfoBanner(
                icon: Icons.warning_amber_rounded,
                color: context.money.owe,
                text: 'This expense was changed on two devices at the same time. '
                    'Balances use one version until someone chooses.',
                action: TextButton(onPressed: () => context.push('/conflicts'), child: const Text('Resolve')),
              ),
            if (e.deleted)
              const InfoBanner(icon: Icons.delete_outline, text: 'This expense was deleted and no longer counts.'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(16)),
                  child: Icon(categoryIcon(e.category), color: theme.colorScheme.onPrimaryContainer, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.description, style: theme.textTheme.titleLarge),
                    Text(formatMoney(e.amountMinor, e.currency),
                        style: theme.textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.w800)),
                    Text('${expenseCategories[e.category] ?? e.category} · '
                        '${DateFormat.yMMMMd().format(DateTime.fromMillisecondsSinceEpoch(e.expenseDate))}',
                        style: theme.textTheme.bodySmall),
                  ]),
                ),
              ]),
            ),
            const SectionHeader('Split'),
            ListTile(
              leading: PersonAvatar(name: n(e.payerId)),
              title: Text('${n(e.payerId)} paid ${formatMoney(e.amountMinor, e.currency)}'),
              subtitle: Text('Split ${switch (e.splitType.name) {
                'equal' => 'equally',
                'exact' => 'by exact amounts',
                'percentage' => 'by percentage',
                _ => 'by shares',
              }}'),
            ),
            for (final entry in (e.splits.entries.toList()..sort((a, b) => n(a.key).compareTo(n(b.key)))))
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                title: Text(entry.key == e.payerId
                    ? '${n(entry.key)} ${entry.key == me ? 'pay' : 'pays'} their own share'
                    : '${n(entry.key)} ${entry.key == me ? 'owe' : 'owes'} ${n(e.payerId)}'),
                trailing: Text(formatMoney(entry.value, e.currency),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            if (e.notes != null) ...[
              const SectionHeader('Notes'),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Text(e.notes!)),
            ],
            if (e.receiptPath != null && File(e.receiptPath!).existsSync()) ...[
              const SectionHeader('Receipt'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(File(e.receiptPath!), fit: BoxFit.cover),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Text('Receipts stay on this device and are not shared during sync.',
                    style: TextStyle(fontSize: 12)),
              ),
            ],
            const SectionHeader('History'),
            AsyncView(
              value: history,
              builder: (list) => Column(children: [
                for (final (i, c) in list.indexed.toList().reversed)
                  ListTile(
                    dense: true,
                    leading: Icon(i == 0
                        ? Icons.add_circle_outline
                        : (c.data['deleted'] == true ? Icons.delete_outline : Icons.edit_outlined)),
                    title: Text('${n(c.authorUserId)} ${i == 0 ? 'added' : (c.data['deleted'] == true ? 'deleted' : 'edited')} · '
                        '${formatMoney(c.data['amount_minor']! as int, c.data['currency']! as String)}'),
                    subtitle: Text(DateFormat.yMMMd().add_jm().format(
                        DateTime.fromMillisecondsSinceEpoch(Hlc.parse(c.hlc).millis))),
                  ),
              ]),
            ),
          ]),
        );
      },
    );
  }

  Future<void> _toggleDelete(BuildContext context, WidgetRef ref, Expense e) async {
    final repo = ref.read(repoProvider);
    if (e.deleted) {
      await repo.restoreExpense(e.id);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete expense?'),
        content: const Text('It stops counting toward balances for everyone after they sync. '
            'The history is kept and it can be restored.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await repo.deleteExpense(e.id);
  }
}
