import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../../sync/change_log.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'groups_screen.dart';

class GroupDetailScreen extends ConsumerWidget {
  const GroupDetailScreen({super.key, required this.groupId});
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(groupProvider(groupId));
    final me = ref.watch(meProvider);
    final members = ref.watch(membersProvider(groupId));
    final expenses = ref.watch(groupExpensesProvider(groupId));
    final settlements = ref.watch(groupSettlementsProvider(groupId));
    final balances = ref.watch(balancesProvider(groupId));
    final people = ref.watch(peopleProvider).value ?? const {};
    final conflicts = ref.watch(conflictsProvider(groupId)).value ?? const [];

    return AsyncView(
      value: group,
      builder: (g) {
        if (g == null) return const Scaffold(body: Center(child: Text('Group not found')));
        final memberList = members.value ?? const <Member>[];
        final amAdmin = memberList.any((m) => m.person.id == me && m.isAdmin);
        final amActive = memberList.any((m) => m.person.id == me && m.isActive);
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: Text(g.name),
              actions: [
                IconButton(
                  tooltip: 'Balances',
                  icon: const Icon(Icons.account_balance_wallet_outlined),
                  onPressed: () => context.push('/group/$groupId/balances'),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) => _menu(context, ref, g, v),
                  itemBuilder: (_) => [
                    if (amAdmin) const PopupMenuItem(value: 'edit', child: Text('Edit group')),
                    if (amAdmin)
                      PopupMenuItem(value: 'archive', child: Text(g.archived ? 'Unarchive' : 'Archive')),
                    const PopupMenuItem(value: 'activity', child: Text('Group activity')),
                    if (amActive && g.createdBy != me)
                      const PopupMenuItem(value: 'leave', child: Text('Leave group')),
                  ],
                ),
              ],
              bottom: const TabBar(tabs: [Tab(text: 'Expenses'), Tab(text: 'Members')]),
            ),
            floatingActionButton: amActive && !g.archived
                ? FloatingActionButton.extended(
                    onPressed: () => context.push('/expense/new?group=$groupId'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add expense'),
                  )
                : null,
            body: TabBarView(children: [
              ListView(padding: const EdgeInsets.only(bottom: 96), children: [
                if (g.archived)
                  const InfoBanner(icon: Icons.archive_outlined, text: 'This group is archived. History is kept.'),
                if (conflicts.isNotEmpty)
                  InfoBanner(
                    icon: Icons.warning_amber_rounded,
                    color: context.money.owe,
                    text: 'Some items in this group need a decision after a sync.',
                    action: TextButton(onPressed: () => context.push('/conflicts'), child: const Text('Review')),
                  ),
                if (balances.value case final b?)
                  Card(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        Expanded(child: BalanceText(byCurrency: b.netFor(me), style: Theme.of(context).textTheme.titleMedium)),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () => context.push('/settle?group=$groupId'),
                          child: const Text('Settle up'),
                        ),
                      ]),
                    ),
                  ),
                AsyncView(
                  value: expenses,
                  builder: (list) {
                    final items = <(int, Widget)>[
                      for (final e in list)
                        (e.expenseDate, ExpenseTile(
                          expense: e,
                          people: people,
                          me: me,
                          onTap: () => context.push('/expense/${e.id}'),
                        )),
                      for (final s in settlements.value ?? const <Settlement>[])
                        (s.settledAt, _SettlementTile(settlement: s, people: people, me: me)),
                    ]..sort((a, b) => b.$1.compareTo(a.$1));
                    if (items.isEmpty) {
                      return const EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'No expenses yet',
                        message: 'Add the first expense. Everyone in the group sees it after you sync.',
                      );
                    }
                    String? lastMonth;
                    final children = <Widget>[];
                    for (final (date, w) in items) {
                      final month = DateFormat.yMMMM().format(DateTime.fromMillisecondsSinceEpoch(date));
                      if (month != lastMonth) {
                        children.add(SectionHeader(month));
                        lastMonth = month;
                      }
                      children.add(w);
                    }
                    return Column(children: children);
                  },
                ),
              ]),
              _MembersTab(group: g, amAdmin: amAdmin),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, Group g, String v) async {
    final repo = ref.read(repoProvider);
    switch (v) {
      case 'edit':
        await showCreateGroupSheet(context, ref, editing: g);
      case 'archive':
        await repo.updateGroup(g.id, archived: !g.archived);
      case 'activity':
        if (context.mounted) {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _GroupActivity(groupId: g.id)));
        }
      case 'leave':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Leave group?'),
            content: const Text('Your past expenses and balances stay in the group history. '
                'You will stop receiving new changes after other members sync.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave')),
            ],
          ),
        );
        if (ok == true) await repo.removeMember(g.id, repo.me);
    }
  }
}

class _SettlementTile extends StatelessWidget {
  const _SettlementTile({required this.settlement, required this.people, required this.me});
  final Settlement settlement;
  final Map<String, Person> people;
  final String me;

  @override
  Widget build(BuildContext context) {
    final s = settlement;
    String n(String id) => id == me ? 'You' : (people[id]?.name ?? 'Someone');
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: context.money.owed.withValues(alpha: 0.12),
        child: Icon(Icons.payments_outlined, color: context.money.owed),
      ),
      title: Text('${n(s.fromUserId)} paid ${n(s.toUserId)}',
          style: s.voided ? const TextStyle(decoration: TextDecoration.lineThrough) : null),
      subtitle: Text(s.voided
          ? 'Voided: ${s.voidReason ?? ''}'
          : 'Recorded payment · ${DateFormat.MMMd().format(DateTime.fromMillisecondsSinceEpoch(s.settledAt))}'),
      trailing: Text(formatMoney(s.amountMinor, s.currency),
          style: TextStyle(fontWeight: FontWeight.w700, color: s.voided ? context.money.settled : null)),
      onLongPress: s.voided
          ? null
          : () => showVoidSettlementDialog(context, s),
    );
  }
}

Future<void> showVoidSettlementDialog(BuildContext context, Settlement s) async {
  final reason = TextEditingController();
  final container = ProviderScope.containerOf(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Void this payment?'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Voiding keeps an auditable record. To correct the amount, void it and record a new payment.'),
        const SizedBox(height: 12),
        TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Void')),
      ],
    ),
  );
  if (ok == true) await container.read(repoProvider).voidSettlement(s.id, reason.text);
}

class _MembersTab extends ConsumerWidget {
  const _MembersTab({required this.group, required this.amAdmin});
  final Group group;
  final bool amAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final members = ref.watch(membersProvider(group.id));
    final balances = ref.watch(balancesProvider(group.id)).value;
    return AsyncView(
      value: members,
      builder: (list) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (amAdmin) ...[
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.qr_code)),
            title: const Text('Invite with a QR code'),
            subtitle: const Text('They scan it with SplitMate; you both confirm a 6-digit code.'),
            onTap: () => context.push('/pair?group=${group.id}'),
          ),
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_add_alt)),
            title: const Text('Add someone without the app'),
            subtitle: const Text('Track their share now and link their phone later.'),
            onTap: () => _addPlaceholder(context, ref),
          ),
          const Divider(),
        ],
        for (final m in list)
          ListTile(
            leading: PersonAvatar(name: m.person.name, imagePath: m.person.avatarPath),
            title: Text(m.person.id == me ? '${m.person.name} (you)' : m.person.name,
                style: m.isActive ? null : const TextStyle(decoration: TextDecoration.lineThrough)),
            subtitle: Text([
              if (m.isAdmin) 'Admin',
              if (!m.isActive) 'Removed (history kept)',
              if (m.isActive && !m.person.hasKeys) 'Not connected yet',
            ].join(' · ')),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (balances != null)
                BalanceText(
                  byCurrency: balances.netFor(m.person.id),
                  prefixOwed: 'gets back',
                  prefixOwe: 'owes',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (amAdmin && m.person.id != me)
                PopupMenuButton<String>(
                  onSelected: (v) => _memberAction(context, ref, m, v),
                  itemBuilder: (_) => [
                    if (m.isActive)
                      PopupMenuItem(
                          value: 'link',
                          // A keyed member who lost their phone gets a new identity;
                          // linking carries their old balances over to it.
                          child: Text(m.person.hasKeys ? 'Replace with a new phone' : 'Connect their phone')),
                    if (m.isActive)
                      PopupMenuItem(value: 'role', child: Text(m.isAdmin ? 'Remove admin' : 'Make admin')),
                    if (m.isActive) const PopupMenuItem(value: 'remove', child: Text('Remove from group')),
                  ],
                ),
            ]),
          ),
      ]),
    );
  }

  Future<void> _addPlaceholder(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add person'),
        content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await ref.read(repoProvider).addPlaceholderMember(group.id, name);
  }

  Future<void> _memberAction(BuildContext context, WidgetRef ref, Member m, String action) async {
    final repo = ref.read(repoProvider);
    try {
      switch (action) {
        case 'link':
          context.push('/pair?group=${group.id}&placeholder=${m.person.id}');
        case 'role':
          await repo.setMemberRole(group.id, m.person.id, m.isAdmin ? 'member' : 'admin');
        case 'remove':
          final b = await repo.balances(groupId: group.id);
          final owes = b.netFor(m.person.id);
          if (!context.mounted) return;
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('Remove ${m.person.name}?'),
              content: Text(owes.isEmpty
                  ? 'Their past expenses stay in the group history.'
                  : '${m.person.name} still has an open balance '
                      '(${owes.entries.map((e) => formatMoney(e.value, e.key)).join(', ')}). '
                      'It stays visible after removal so it can still be settled.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
              ],
            ),
          );
          if (ok == true) await repo.removeMember(group.id, m.person.id);
      }
    } on AuthorizationException catch (e) {
      if (context.mounted) showSnack(context, e.toString());
    }
  }
}

class _GroupActivity extends ConsumerWidget {
  const _GroupActivity({required this.groupId});
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('Group activity')),
        body: AsyncView(
          value: ref.watch(activityProvider(groupId)),
          builder: (list) => ListView(children: [
            for (final a in list)
              ListTile(
                leading: Icon(a.isRemote ? Icons.sync_alt : Icons.edit_note),
                title: Text(a.summary),
                subtitle: Text(timeAgo(a.createdAt)),
              ),
          ]),
        ),
      );
}
