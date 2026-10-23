import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../widgets/common.dart';

/// Per-member balances and the suggested "simplified" settlements.
class BalancesScreen extends ConsumerWidget {
  const BalancesScreen({super.key, required this.groupId});
  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = ref.watch(balancesProvider(groupId));
    final members = ref.watch(membersProvider(groupId)).value ?? const [];
    final people = ref.watch(peopleProvider).value ?? const {};
    final me = ref.watch(meProvider);
    String n(String id) => id == me ? 'You' : (people[id]?.name ?? 'Someone');

    return Scaffold(
      appBar: AppBar(title: const Text('Balances')),
      body: AsyncView(
        value: balances,
        builder: (b) {
          final transfers = b.suggestedTransfers();
          return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
            const InfoBanner(
              icon: Icons.info_outline,
              text: 'Balances are calculated on this phone from the expenses and payments it has. '
                  'Sync with others to include their latest changes.',
            ),
            const SectionHeader('Everyone'),
            for (final m in members)
              ListTile(
                leading: PersonAvatar(name: m.person.name),
                title: Text(n(m.person.id)),
                subtitle: m.isActive ? null : const Text('Removed'),
                trailing: BalanceText(
                  byCurrency: b.netFor(m.person.id),
                  prefixOwed: 'gets back',
                  prefixOwe: 'owes',
                ),
              ),
            const SectionHeader('Suggested payments'),
            if (transfers.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text('Everyone is settled up.'))
            else
              for (final t in transfers)
                ListTile(
                  leading: const Icon(Icons.arrow_forward),
                  title: Text('${n(t.fromUserId)} → ${n(t.toUserId)}'),
                  subtitle: Text(formatMoney(t.amountMinor, t.currency)),
                  trailing: FilledButton.tonal(
                    onPressed: () => context.push(
                        '/settle?group=$groupId&from=${t.fromUserId}&to=${t.toUserId}'
                        '&amount=${t.amountMinor}&currency=${t.currency}'),
                    child: const Text('Record'),
                  ),
                ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                'Suggestions minimise the number of payments, so someone may be asked to pay a person '
                'they never shared an expense with. Each currency is settled separately.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
