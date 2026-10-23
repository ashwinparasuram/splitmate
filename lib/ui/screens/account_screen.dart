import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../identity/identity.dart';
import '../widgets/common.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(servicesProvider);
    final id = services.log.identity;
    final sync = ref.watch(syncSummaryProvider).value;
    final conflicts = ref.watch(conflictsProvider(null)).value ?? const [];
    final fingerprint = id.ed25519Pub.substring(0, 16).toUpperCase().replaceAllMapped(
        RegExp(r'.{4}'), (m) => '${m.group(0)} ').trim();

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(children: [
        ListTile(
          leading: PersonAvatar(name: id.displayName, radius: 26),
          title: Text(id.displayName, style: Theme.of(context).textTheme.titleLarge),
          subtitle: Text('Device key $fingerprint'),
          trailing: IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _rename(context, ref, id),
          ),
        ),
        const SectionHeader('Sharing'),
        ListTile(
          leading: const Icon(Icons.qr_code_2),
          title: const Text('Connect a phone'),
          subtitle: const Text('Pair with a friend by QR code'),
          onTap: () => context.push('/pair'),
        ),
        ListTile(
          leading: const Icon(Icons.sync),
          title: const Text('Sync status'),
          subtitle: Text(sync == null
              ? ''
              : '${sync.devices} paired device(s) · ${sync.unsynced} change(s) not yet shared'),
          onTap: () => context.push('/sync'),
        ),
        ListTile(
          leading: const Icon(Icons.call_split),
          title: const Text('Conflicts'),
          subtitle: Text(conflicts.isEmpty ? 'None' : '${conflicts.length} need a decision'),
          onTap: () => context.push('/conflicts'),
        ),
        const SectionHeader('Data'),
        ListTile(
          leading: const Icon(Icons.cloud_upload_outlined),
          title: const Text('Backup & restore'),
          subtitle: const Text('Optional encrypted backup to Google Drive or a file'),
          onTap: () => context.push('/backup'),
        ),
        ListTile(
          leading: const Icon(Icons.shield_outlined),
          title: const Text('Privacy & security'),
          onTap: () => context.push('/privacy'),
        ),
        const SectionHeader('About'),
        ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/branding/logo.png', width: 36, height: 36),
          ),
          title: const Text('SplitMate 1.0.0'),
          subtitle: const Text('Offline-first. No servers, no accounts, no analytics.'),
        ),
      ]),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, LocalIdentity id) async {
    final c = TextEditingController(text: id.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final services = ref.read(servicesProvider);
    final updated = id.withDisplayName(name);
    await services.identityStore.save(updated);
    await services.log.resetIdentity(updated);
    await services.repo.ensureLocalUser();
    services.repo.notifyChanged();
  }
}
