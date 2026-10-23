import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'groups_screen.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final balances = ref.watch(balancesProvider(null));
    final people = ref.watch(peopleProvider);
    final recent = ref.watch(recentExpensesProvider);
    final groups = ref.watch(groupsProvider);
    final sync = ref.watch(syncSummaryProvider);
    final conflicts = ref.watch(conflictsProvider(null));
    final name = people.value?[me]?.name ?? '';

    return Scaffold(
      appBar: AppBar(
        title: Text(name.isEmpty ? 'SplitMate' : 'Hi, ${name.split(' ').first}'),
        actions: [
          IconButton(
            tooltip: 'Sync with a friend',
            icon: const Icon(Icons.sync),
            onPressed: () => context.push('/sync'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/expense/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add expense'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(ledgerTickProvider),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            AsyncView(
              value: balances,
              builder: (b) {
                final t = b.totalsFor(me);
                final net = b.netFor(me);
                return _SummaryCard(owedToMe: t.owedToMe, iOwe: t.iOwe, net: net);
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(children: [
                Expanded(
                  child: _QuickAction(
                      icon: Icons.group_add, label: 'New group', onTap: () => showCreateGroupSheet(context, ref)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _QuickAction(
                      icon: Icons.handshake_outlined, label: 'Settle up', onTap: () => context.push('/settle')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _QuickAction(
                      icon: Icons.qr_code_scanner, label: 'Connect', onTap: () => context.push('/pair?scan=1')),
                ),
              ]),
            ),
            if (sync.value case final s?)
              _SyncStrip(unsynced: s.unsynced, pending: s.pending, devices: s.devices, lastSync: s.lastSync),
            if ((conflicts.value ?? const []).isNotEmpty)
              InfoBanner(
                icon: Icons.warning_amber_rounded,
                color: context.money.owe,
                text: '${conflicts.value!.length} item(s) were edited on two devices at once and need a decision.',
                action: TextButton(onPressed: () => context.push('/conflicts'), child: const Text('Review')),
              ),
            SectionHeader('Groups',
                trailing: TextButton(onPressed: () => context.go('/groups'), child: const Text('See all'))),
            AsyncView(
              value: groups,
              builder: (list) {
                final active = list.where((g) => !g.archived).take(4).toList();
                if (active.isEmpty) {
                  return EmptyState(
                    icon: Icons.groups_outlined,
                    title: 'No groups yet',
                    message: 'Create a group for your flat, a trip or a dinner club. It works fully offline.',
                    action: FilledButton.icon(
                      onPressed: () => showCreateGroupSheet(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('Create a group'),
                    ),
                  );
                }
                return Column(children: [for (final g in active) GroupTile(group: g)]);
              },
            ),
            const SectionHeader('Recent expenses'),
            AsyncView(
              value: recent,
              builder: (list) => list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Expenses you add appear here.', textAlign: TextAlign.center),
                    )
                  : Column(children: [
                      for (final e in list)
                        ExpenseTile(
                          expense: e,
                          people: people.value ?? const {},
                          me: me,
                          onTap: () => context.push('/expense/${e.id}'),
                        ),
                    ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.owedToMe, required this.iOwe, required this.net});
  final Map<String, int> owedToMe;
  final Map<String, int> iOwe;
  final Map<String, int> net;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currencies = {...owedToMe.keys, ...iOwe.keys}.toList()..sort();
    String fmt(Map<String, int> m) => m.isEmpty
        ? '—'
        : (m.keys.toList()..sort()).map((c) => formatMoney(m[c]!, c)).join('\n');
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary, Color.lerp(scheme.primary, scheme.tertiary, 0.6)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: scheme.onPrimary),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Net balance', style: TextStyle(color: scheme.onPrimary.withValues(alpha: 0.8))),
          const SizedBox(height: 4),
          if (net.isEmpty)
            const Text('All settled up', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))
          else
            for (final c in (net.keys.toList()..sort()))
              Text('${net[c]! >= 0 ? '+' : '−'}${formatMoney(net[c]!.abs(), c)}',
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _Stat(label: 'You are owed', value: fmt(owedToMe))),
            Container(width: 1, height: 36, color: scheme.onPrimary.withValues(alpha: 0.25)),
            const SizedBox(width: 16),
            Expanded(child: _Stat(label: 'You owe', value: fmt(iOwe))),
          ]),
          if (currencies.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text('Currencies are shown separately; SplitMate never converts them.',
                  style: TextStyle(fontSize: 12, color: scheme.onPrimary.withValues(alpha: 0.8))),
            ),
        ]),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: DefaultTextStyle.of(context).style.color!.withValues(alpha: 0.8))),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ]);
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 6),
              Text(label, style: Theme.of(context).textTheme.labelLarge),
            ]),
          ),
        ),
      );
}

class _SyncStrip extends StatelessWidget {
  const _SyncStrip({required this.unsynced, required this.pending, required this.devices, required this.lastSync});
  final int unsynced;
  final int pending;
  final int devices;
  final int? lastSync;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = devices == 0
        ? (Icons.phone_android, 'Only on this device. Connect a friend to share groups.')
        : unsynced > 0
            ? (Icons.cloud_off, '$unsynced local change${unsynced == 1 ? '' : 's'} not yet shared with any device.')
            : (Icons.check_circle_outline,
                'All changes shared${lastSync == null ? '' : ' · last sync ${timeAgo(lastSync!)}'}.');
    return InfoBanner(
      icon: icon,
      text: pending > 0 ? '$text $pending received change(s) are waiting for related data.' : text,
      action: TextButton(onPressed: () => context.push('/sync'), child: const Text('Sync')),
    );
  }
}
