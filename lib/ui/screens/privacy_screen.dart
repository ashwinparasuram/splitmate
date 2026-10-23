import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../main.dart' show resetAppProvider;
import '../theme.dart';
import '../widgets/common.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(pairedDevicesProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & security')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        const SectionHeader('What is shared'),
        const _Fact(icon: Icons.groups_outlined, title: 'Only shared groups',
            body: 'A friend\'s phone receives a group only if they are an active member of it. '
                'Your other groups, friends and settings are never sent.'),
        const _Fact(icon: Icons.badge_outlined, title: 'Inside a shared group',
            body: 'Members see the group name, member names, every expense (description, amount, '
                'split, notes, category, date) and recorded payments. Receipt photos stay on your phone.'),
        const _Fact(icon: Icons.lock_outline, title: 'Encrypted and authenticated',
            body: 'Phones verify each other\'s keys (QR code plus a 6-digit code you compare) and '
                'every sync is encrypted end to end. Each change is signed, so a phone that relays '
                'it cannot alter it.'),
        const _Fact(icon: Icons.public, title: 'Internet connections',
            body: 'To sync across networks, connection codes include this phone’s network addresses, '
                'and while the Connect or Sync screen is open your router may be asked to open a port. '
                'No relay server is used. Turn it off in Sync if you only sync on the same Wi-Fi.'),
        const _Fact(icon: Icons.cloud_off_outlined, title: 'No servers, no analytics',
            body: 'SplitMate has no backend, no crash reporting and no analytics. Google Drive is '
                'used only if you turn on backups, and only for encrypted files.'),
        const SectionHeader('On this phone'),
        const _Fact(icon: Icons.key_outlined, title: 'Private keys',
            body: 'Stored in the Android Keystore or iOS Keychain, never in the database.'),
        const _Fact(icon: Icons.storage_outlined, title: 'Database',
            body: 'Stored in the app\'s private storage, protected by your phone\'s disk encryption. '
                'Use a screen lock: anyone who can unlock your phone can open the app.'),
        SectionHeader('Paired devices (${devices.length})'),
        for (final d in devices)
          ListTile(
            leading: Icon(d['status'] == 'revoked' ? Icons.block : Icons.smartphone),
            title: Text(d['display_name']! as String),
            subtitle: Text(d['status'] == 'revoked' ? 'Revoked' : 'Can sync shared groups'),
            trailing: d['status'] == 'revoked'
                ? null
                : TextButton(
                    onPressed: () => ref.read(servicesProvider).pairing.revokeDevice(d['device_id']! as String),
                    child: const Text('Revoke')),
          ),
        const SectionHeader('Delete'),
        ListTile(
          leading: Icon(Icons.delete_forever, color: context.money.owe),
          title: Text('Delete all data on this phone', style: TextStyle(color: context.money.owe)),
          subtitle: const Text('Removes the database, receipts and keys. Friends keep their own copies '
              'of shared groups. Backups in Drive are not deleted.'),
          onTap: () => _deleteAll(context, ref),
        ),
      ]),
    );
  }

  Future<void> _deleteAll(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete everything?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('This cannot be undone. Type DELETE to confirm.'),
          TextField(controller: c, autofocus: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim() == 'DELETE'), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (context.mounted) context.go('/home');
    await ref.read(resetAppProvider)();
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(body),
        isThreeLine: true,
      );
}
