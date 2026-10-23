import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../widgets/common.dart';

class FriendsScreen extends ConsumerWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(friendsProvider);
    final balances = ref.watch(balancesProvider(null)).value;
    final me = ref.watch(meProvider);
    final counter = balances?.counterpartiesOf(me) ?? const <String, Map<String, int>>{};

    return Scaffold(
      appBar: AppBar(title: const Text('Friends'), actions: [
        IconButton(
          tooltip: 'Connect a friend\'s phone',
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: () => context.push('/pair?scan=1'),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addFriend(context, ref),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add friend'),
      ),
      body: AsyncView(
        value: friends,
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.people_outline,
              title: 'No friends yet',
              message: 'Add a friend to split costs one-to-one, or connect phones with a QR code '
                  'so your shared expenses sync.',
              action: FilledButton.icon(
                onPressed: () => context.push('/pair'),
                icon: const Icon(Icons.qr_code),
                label: const Text('Show my QR code'),
              ),
            );
          }
          final sorted = [...list]..sort((a, b) {
              final ab = (counter[a.id] ?? const {}).values.fold<int>(0, (s, v) => s + v.abs());
              final bb = (counter[b.id] ?? const {}).values.fold<int>(0, (s, v) => s + v.abs());
              return bb.compareTo(ab);
            });
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            for (final f in sorted)
              ListTile(
                leading: PersonAvatar(name: f.name, imagePath: f.avatarPath),
                title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(f.hasKeys ? 'Connected' : 'Not connected — shown only on your phone'),
                trailing: BalanceText(
                  byCurrency: counter[f.id] ?? const {},
                  prefixOwed: 'owes you',
                  prefixOwe: 'you owe',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onTap: () => _friendSheet(context, ref, f, counter[f.id] ?? const {}),
              ),
          ]);
        },
      ),
    );
  }

  Future<void> _addFriend(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add friend'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: c,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          const Text('They appear only on your phone until you connect your phones with a QR code.',
              style: TextStyle(fontSize: 13)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final groupId = await ref.read(repoProvider).addFriend(name, 'INR');
    if (context.mounted) context.push('/group/$groupId');
  }

  Future<void> _friendSheet(BuildContext context, WidgetRef ref, Person f, Map<String, int> bal) async {
    final repo = ref.read(repoProvider);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          PersonAvatar(name: f.name, radius: 32),
          const SizedBox(height: 8),
          Text(f.name, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 4),
          if (bal.isEmpty)
            const Text('Settled up')
          else
            for (final e in bal.entries)
              Text(e.value > 0
                  ? '${f.name} owes you ${formatMoney(e.value, e.key)}'
                  : 'You owe ${f.name} ${formatMoney(-e.value, e.key)}'),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Add an expense with them'),
            onTap: () async {
              final g = await repo.ensureDirectGroup(f.id, 'INR');
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) context.push('/expense/new?group=$g');
            },
          ),
          ListTile(
            leading: const Icon(Icons.handshake_outlined),
            title: const Text('Settle up'),
            onTap: () async {
              final g = await repo.ensureDirectGroup(f.id, 'INR');
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) context.push('/settle?group=$g');
            },
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('One-to-one expenses'),
            onTap: () async {
              final g = await repo.ensureDirectGroup(f.id, 'INR');
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) context.push('/group/$g');
            },
          ),
          if (!f.hasKeys)
            ListTile(
              leading: const Icon(Icons.qr_code),
              title: const Text('Connect their phone'),
              subtitle: const Text('Shares your one-to-one expenses with them'),
              onTap: () async {
                final g = await repo.ensureDirectGroup(f.id, 'INR');
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) context.push('/pair?group=$g&placeholder=${f.id}');
              },
            ),
        ]),
      ),
    );
  }
}
