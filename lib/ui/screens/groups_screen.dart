import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../domain/models.dart';
import '../widgets/common.dart';

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({super.key});

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Groups'), actions: [
        IconButton(
          tooltip: 'Join with a QR code',
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: () => context.push('/pair?scan=1'),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showCreateGroupSheet(context, ref),
        icon: const Icon(Icons.group_add),
        label: const Text('New group'),
      ),
      body: AsyncView(
        value: groups,
        builder: (list) {
          final invited = list.where((g) => g.localStatus == 'invited').toList();
          final active = list.where((g) => g.localStatus == 'active' && !g.archived).toList();
          final archived = list.where((g) => g.localStatus == 'active' && g.archived).toList();
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.groups_outlined,
              title: 'No groups yet',
              message: 'Create a group, or scan a friend\'s QR code to join one they shared with you.',
              action: FilledButton.icon(
                onPressed: () => showCreateGroupSheet(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Create a group'),
              ),
            );
          }
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            if (invited.isNotEmpty) ...[
              const SectionHeader('Invitations'),
              for (final g in invited) _InvitationTile(group: g),
            ],
            const SectionHeader('Your groups'),
            if (active.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Text('No active groups.')),
            for (final g in active) GroupTile(group: g),
            if (archived.isNotEmpty)
              SectionHeader('Archived (${archived.length})',
                  trailing: TextButton(
                      onPressed: () => setState(() => _showArchived = !_showArchived),
                      child: Text(_showArchived ? 'Hide' : 'Show'))),
            if (_showArchived) for (final g in archived) GroupTile(group: g),
          ]);
        },
      ),
    );
  }
}

class _InvitationTile extends ConsumerWidget {
  const _InvitationTile({required this.group});
  final Group group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider).value ?? const {};
    final by = people[group.createdBy]?.name ?? 'Someone';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          PersonAvatar(name: group.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(group.name, style: Theme.of(context).textTheme.titleMedium),
              Text('$by shared this group with you', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          TextButton(
              onPressed: () => ref.read(repoProvider).setGroupConsent(group.id, false),
              child: const Text('Decline')),
          FilledButton(
              onPressed: () => ref.read(repoProvider).setGroupConsent(group.id, true),
              child: const Text('Accept')),
        ]),
      ),
    );
  }
}

class GroupTile extends ConsumerWidget {
  const GroupTile({super.key, required this.group});
  final Group group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final bal = ref.watch(balancesProvider(group.id));
    return ListTile(
      onTap: () => context.push('/group/${group.id}'),
      leading: PersonAvatar(name: group.name, radius: 22),
      title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(group.archived ? 'Archived' : group.defaultCurrency),
      trailing: bal.when(
        data: (b) => BalanceText(byCurrency: b.netFor(me), style: Theme.of(context).textTheme.bodySmall),
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
      ),
    );
  }
}

Future<void> showCreateGroupSheet(BuildContext context, WidgetRef ref, {Group? editing}) async {
  final name = TextEditingController(text: editing?.name);
  var currency = editing?.defaultCurrency ?? 'INR';
  final created = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(editing == null ? 'New group' : 'Edit group', style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Group name', hintText: 'Goa trip, Flat 4B…'),
          ),
          DropdownButtonFormField<String>(
            initialValue: currency,
            decoration: const InputDecoration(labelText: 'Default currency'),
            items: [
              for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text('${c.code} · ${c.name}')),
            ],
            onChanged: (v) => setState(() => currency = v!),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              if (name.text.trim().isEmpty) return;
              final repo = ref.read(repoProvider);
              if (editing == null) {
                final id = await repo.createGroup(name.text, currency);
                if (ctx.mounted) Navigator.pop(ctx, id);
              } else {
                await repo.updateGroup(editing.id, name: name.text, currency: currency);
                if (ctx.mounted) Navigator.pop(ctx);
              }
            },
            child: Text(editing == null ? 'Create group' : 'Save'),
          ),
        ]),
      ),
    ),
  );
  if (created != null && context.mounted) context.push('/group/$created');
}
