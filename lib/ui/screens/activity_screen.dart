import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../widgets/common.dart';

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(activityProvider(null));
    final groups = {for (final g in ref.watch(groupsProvider).value ?? const []) g.id: g.name};
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: AsyncView(
        value: activity,
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.history,
              title: 'Nothing here yet',
              message: 'Everything you and your friends add, change or settle shows up here.',
            );
          }
          String? lastDay;
          final children = <Widget>[];
          for (final a in list) {
            final day = DateFormat.yMMMEd().format(DateTime.fromMillisecondsSinceEpoch(a.createdAt));
            if (day != lastDay) {
              children.add(SectionHeader(day));
              lastDay = day;
            }
            final icon = switch (a.entityType) {
              'expense' => a.action == 'deleted' ? Icons.delete_outline : Icons.receipt_long_outlined,
              'settlement' => Icons.payments_outlined,
              'member' => Icons.person_outline,
              _ => Icons.groups_outlined,
            };
            children.add(ListTile(
              leading: CircleAvatar(child: Icon(icon, size: 20)),
              title: Text(a.summary),
              subtitle: Text([
                if (a.groupId != null && groups[a.groupId] != null) groups[a.groupId]!,
                DateFormat.jm().format(DateTime.fromMillisecondsSinceEpoch(a.createdAt)),
                if (a.isRemote) 'received via sync',
              ].join(' · ')),
              onTap: switch (a.entityType) {
                'expense' => () => context.push('/expense/${a.entityId}'),
                'group' => () => context.push('/group/${a.entityId}'),
                _ => a.groupId == null ? null : () => context.push('/group/${a.groupId}'),
              },
            ));
          }
          return ListView(children: children);
        },
      ),
    );
  }
}
