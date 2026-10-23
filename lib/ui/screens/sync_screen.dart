import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/sync_controller.dart';
import '../../sync/pairing.dart';
import '../../sync/sync_bundle.dart';
import '../theme.dart';
import '../widgets/code_share.dart';
import '../widgets/common.dart';

/// Paired devices, pending changes, and the ways to sync with them.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  late final SyncController _sync = ref.read(servicesProvider).sync;
  bool _hosting = false;
  bool _internet = true;

  @override
  void initState() {
    super.initState();
    _sync.addListener(_rebuild);
    _sync.internetAllowed().then((v) {
      if (mounted) setState(() => _internet = v);
    });
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _sync.removeListener(_rebuild);
    if (_hosting) unawaited(_sync.stopHosting());
    super.dispose();
  }

  Future<void> _toggleHosting() async {
    if (_hosting) {
      await _sync.stopHosting();
    } else {
      await _sync.startHosting();
    }
    setState(() => _hosting = !_hosting);
  }

  Future<void> _exportFile(Map<String, Object?> device) async {
    try {
      final bytes = await ref.read(servicesProvider).bundles.exportFor(device['device_id']! as String);
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path,
          'splitmate-for-${(device['display_name']! as String).replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}.smsync'));
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/octet-stream')],
        text: 'SplitMate sync file. Open it in SplitMate → Sync → Import file. '
            'Only ${device['display_name']}\'s phone can read it.',
      ));
    } on BundleException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  Future<void> _importFile() async {
    final file = await FilePicker.pickFile(dialogTitle: 'Choose a SplitMate sync file (.smsync)');
    if (file == null) return;
    try {
      final report = await ref.read(servicesProvider).bundles.import(await file.readAsBytes());
      ref.read(repoProvider).notifyChanged();
      if (mounted) {
        showSnack(context, 'Imported ${report.applied} change(s)'
            '${report.duplicates > 0 ? ', ${report.duplicates} already here' : ''}'
            '${report.pending > 0 ? ', ${report.pending} waiting for related data' : ''}.');
      }
    } on BundleException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(syncSummaryProvider).value;
    final devices = ref.watch(pairedDevicesProvider).value ?? const [];
    final state = _sync.value;
    final me = ref.read(servicesProvider).log.identity;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (state.busy) const LinearProgressIndicator(),
        if (state.busy && state.phase != null) InfoBanner(icon: Icons.sync, text: state.phase!),
        if (state.lastError != null)
          InfoBanner(icon: Icons.error_outline, color: context.money.owe, text: state.lastError!),
        if (state.lastMessage != null)
          InfoBanner(icon: Icons.check_circle_outline, color: context.money.owed, text: state.lastMessage!),
        if (summary != null)
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(summary.unsynced == 0 ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                      color: summary.unsynced == 0 ? context.money.owed : context.money.owe),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                        summary.unsynced == 0
                            ? 'Every change made here has reached at least one other device.'
                            : '${summary.unsynced} change(s) exist only on this phone.',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                ]),
                if (summary.pending > 0) ...[
                  const SizedBox(height: 8),
                  Text('${summary.pending} received change(s) are waiting for related changes from '
                      'another member. They apply automatically after the next sync.'),
                ],
                if (summary.lastSync != null) ...[
                  const SizedBox(height: 8),
                  Text('Last sync ${timeAgo(summary.lastSync!)}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ]),
            ),
          ),
        const SectionHeader('Sync directly'),
        SwitchListTile(
          title: const Text('Let paired phones connect'),
          subtitle: Text(_hosting
              ? switch (state.reach) {
                  Reachability.checking => 'Ready on this network · checking the internet…',
                  Reachability.internet => 'Reachable here and over the internet (${state.reachDetail})',
                  Reachability.lanOnly => 'Reachable on this network only',
                  Reachability.off => state.endpoints.isEmpty ? 'No network connection' : 'Listening',
                }
              : 'Turn on, then scan or send this code to the other phone'),
          value: _hosting,
          onChanged: (_) => _toggleHosting(),
        ),
        SwitchListTile(
          title: const Text('Allow connections over the internet'),
          subtitle: const Text('Advertises this phone’s public IPv6 address and asks your router to open '
              'a port (UPnP / NAT-PMP) while this screen is open. No relay server is used; '
              'connections are still encrypted and limited to paired phones.'),
          value: _internet,
          onChanged: (v) async {
            setState(() => _internet = v);
            await _sync.setInternetAllowed(v);
          },
        ),
        if (_hosting && state.endpoints.isNotEmpty) ...[
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: QrImageView(
                  data: ConnectCode(me.deviceId, state.endpoints).encode(), size: 200, backgroundColor: Colors.white),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => shareCode(ConnectCode(me.deviceId, state.endpoints).encode(),
                      message: 'Sync with me on SplitMate: open Sync → Scan a paired phone’s sync code → '
                          'Upload QR image (or Paste code) while my Sync screen is open.'),
                  icon: const Icon(Icons.share),
                  label: const Text('Share sync code'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => copyCode(context, ConnectCode(me.deviceId, state.endpoints).encode()),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
              ),
            ]),
          ),
        ],
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: const Text('Scan, upload or paste a paired phone’s sync code'),
          onTap: () => context.push('/pair?scan=1'),
        ),
        ListTile(
          leading: const Icon(Icons.person_add_alt),
          title: const Text('Pair a new phone'),
          onTap: () => context.push('/pair'),
        ),
        const SectionHeader('When a direct connection fails'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Some networks (many mobile carriers, guest Wi-Fi, routers without UPnP) block incoming '
            'connections, and SplitMate has no relay server. Try with the other phone showing the code, '
            'or send an encrypted sync file via any messaging app.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.file_open_outlined),
          title: const Text('Import a sync file'),
          onTap: _importFile,
        ),
        SectionHeader('Paired devices (${devices.length})'),
        if (devices.isEmpty)
          const Padding(padding: EdgeInsets.all(20), child: Text('No paired devices yet.')),
        for (final d in devices)
          ListTile(
            leading: PersonAvatar(name: d['display_name']! as String),
            title: Text(d['display_name']! as String),
            subtitle: Text(d['status'] == 'revoked'
                ? 'Revoked'
                : d['last_sync_at'] == null
                    ? 'Never synced'
                    : 'Last sync ${timeAgo(d['last_sync_at']! as int)}'),
            trailing: d['status'] == 'revoked'
                ? null
                : PopupMenuButton<String>(
                    onSelected: (v) async {
                      switch (v) {
                        case 'sync':
                          final ep = d['last_endpoint'] as String?;
                          if (ep == null) {
                            showSnack(context, 'Scan their sync code first.');
                          } else {
                            await _sync.syncWith(d['device_id']! as String, [ep]);
                          }
                        case 'file':
                          await _exportFile(d);
                        case 'revoke':
                          await ref.read(servicesProvider).pairing.revokeDevice(d['device_id']! as String);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'sync', child: Text('Sync now (last address)')),
                      const PopupMenuItem(value: 'file', child: Text('Send a sync file')),
                      const PopupMenuItem(value: 'revoke', child: Text('Stop syncing with this device')),
                    ],
                  ),
          ),
      ]),
    );
  }
}
