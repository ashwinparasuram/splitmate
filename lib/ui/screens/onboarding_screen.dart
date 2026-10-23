import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/services.dart';
import '../../identity/identity.dart';

/// First launch: explains how SplitMate works, then creates the local
/// identity (no online account). Also offers restore from a backup file.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onCreate, required this.store, required this.onRestored});
  final Future<void> Function(String name) onCreate;
  final IdentityStore store;
  final void Function(AppServices services) onRestored;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  final _name = TextEditingController();
  int _page = 0;
  bool _busy = false;
  String? _error;

  static const _intro = [
    (Icons.phone_iphone, 'Your data stays on your phone',
        'Expenses and balances are stored only on this device. There is no SplitMate server and no account to create.'),
    (Icons.qr_code_2, 'Share directly with friends',
        'Scan a QR code to connect phones. Groups you share sync directly between devices over Wi-Fi or a hotspot, encrypted end to end.'),
    (Icons.cloud_outlined, 'Backup is optional',
        'You can back up an encrypted copy to your own Google Drive or a file. Without a backup, losing this phone means losing data that no friend has synced.'),
  ];

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter your name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate(name);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not set up: $e';
      });
    }
  }

  Future<void> _restore() async {
    final file = await FilePicker.pickFile(dialogTitle: 'Choose a SplitMate backup (.smbk)');
    if (file == null || !mounted) return;
    final pass = await _askPassphrase();
    if (pass == null) return;
    setState(() => _busy = true);
    AppServices? services;
    try {
      final bytes = await file.readAsBytes();
      // A throwaway identity opens the empty database; the restore replaces
      // it with the backup's identity and saves that to secure storage.
      final temp = await LocalIdentity.generate('Restoring');
      services = await AppServices.open(temp, widget.store);
      final report = await services.backup.restore(bytes, pass);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Restored ${report.ingest.applied} records for ${report.header.displayName}.')));
      widget.onRestored(services);
    } catch (e) {
      await services?.deleteAllData();
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<String?> _askPassphrase() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recovery passphrase'),
        content: TextField(controller: c, obscureText: true, autofocus: true,
            decoration: const InputDecoration(labelText: 'Passphrase')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Restore')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _page == _intro.length;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                for (final (i, (icon, title, body)) in _intro.indexed)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      if (i == 0)
                        Image.asset('assets/branding/logo.png', width: 168, height: 168)
                      else
                        Container(
                          padding: const EdgeInsets.all(28),
                          decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer, shape: BoxShape.circle),
                          child: Icon(icon, size: 56, color: theme.colorScheme.onPrimaryContainer),
                        ),
                      const SizedBox(height: 32),
                      Text(title, style: theme.textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.w700),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      Text(body, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
                    ]),
                  ),
                ListView(padding: const EdgeInsets.all(32), children: [
                  const SizedBox(height: 40),
                  Text('What should friends call you?',
                      style: theme.textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text('Your name is shown to people you share groups with. A private key that '
                      'identifies this device is created and kept in secure storage.',
                      style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(labelText: 'Your name', errorText: _error),
                    onSubmitted: (_) => _create(),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _create,
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Get started'),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _busy ? null : _restore,
                    icon: const Icon(Icons.restore),
                    label: const Text('Restore from a backup file'),
                  ),
                  Text('To restore from Google Drive, get started first, then open Account → Backup.',
                      style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                ]),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Row(children: [
              for (var i = 0; i <= _intro.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(right: 6),
                  width: i == _page ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              const Spacer(),
              if (!last)
                FilledButton.tonal(
                  onPressed: () => _pages.nextPage(
                      duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                  child: const Text('Next'),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
