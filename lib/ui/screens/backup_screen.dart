import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/services.dart';
import '../../backup/backup_format.dart';
import '../../backup/backup_service.dart';
import '../../backup/backup_storage.dart';
import '../../backup/drive_backup_storage.dart';
import '../../sync/change_log.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _autoKey = 'backup.auto_drive';
const _passKey = 'backup.passphrase';
const autoBackupInterval = Duration(hours: 24);

/// Runs an opt-in scheduled Drive backup when the app opens, if the last
/// one is older than [autoBackupInterval]. Silent; never prompts.
Future<void> maybeAutoBackup(AppServices s) async {
  try {
    if (await readMeta(s.log.db, _autoKey) != '1') return;
    final last = await s.backup.lastBackupAt();
    if (last != null && s.log.now() - last < autoBackupInterval.inMilliseconds) return;
    final pass = await s.secrets.read(_passKey);
    if (pass == null) return;
    final drive = await DriveBackupStorage.restore();
    if (drive == null) return;
    await s.backup.backupTo(drive, pass);
  } catch (_) {
    // Offline or token expired: try again next launch. Local data is unaffected.
  }
}

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  DriveBackupStorage? _drive;
  List<RemoteBackup>? _backups;
  int? _lastBackup;
  bool _auto = false;
  bool _busy = false;
  String? _status;
  String? _error;

  AppServices get _s => ref.read(servicesProvider);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _lastBackup = await _s.backup.lastBackupAt();
    _auto = await readMeta(_s.log.db, _autoKey) == '1';
    final drive = await DriveBackupStorage.restore();
    if (!mounted) return;
    setState(() => _drive = drive);
    if (drive != null) await _refresh();
  }

  Future<T?> _run<T>(String status, Future<T> Function() op) async {
    setState(() {
      _busy = true;
      _status = status;
      _error = null;
    });
    try {
      return await op();
    } on BackupStorageException catch (e) {
      setState(() => _error = e.message);
    } on BackupFormatException catch (e) {
      setState(() => _error = e.message);
    } on RestoreConflictException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
    return null;
  }

  Future<void> _refresh() async {
    final d = _drive;
    if (d == null) return;
    final list = await _run('Loading backups', d.list);
    if (list != null && mounted) setState(() => _backups = list);
  }

  Future<void> _connect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect Google Drive?'),
        content: const Text(
            'SplitMate asks only for its own hidden app folder in your Drive. It cannot see your other files. '
            'Nothing is uploaded until you tap "Back up now" or turn on automatic backups. '
            'Backups are encrypted with your passphrase before they leave the phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Connect')),
        ],
      ),
    );
    if (ok != true) return;
    final d = await _run('Connecting', DriveBackupStorage.connect);
    if (d != null) {
      setState(() => _drive = d);
      await _refresh();
    }
  }

  Future<void> _disconnect() async {
    await _run('Disconnecting', DriveBackupStorage.disconnect);
    await writeMeta(_s.log.db, _autoKey, '0');
    await _s.secrets.delete(_passKey);
    setState(() {
      _drive = null;
      _backups = null;
      _auto = false;
    });
  }

  Future<String?> _askPassphrase({required bool confirm}) async {
    final a = TextEditingController();
    final b = TextEditingController();
    String? err;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(confirm ? 'Choose a recovery passphrase' : 'Enter recovery passphrase'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (confirm)
              const Text('The backup is encrypted with this passphrase. Nobody — including SplitMate — '
                  'can recover it if you forget it. Write it down somewhere safe.',
                  style: TextStyle(fontSize: 13)),
            TextField(controller: a, obscureText: true, autofocus: true,
                decoration: const InputDecoration(labelText: 'Passphrase')),
            if (confirm)
              TextField(controller: b, obscureText: true,
                  decoration: InputDecoration(labelText: 'Repeat passphrase', errorText: err)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (confirm && a.text != b.text) return setState(() => err = 'Passphrases differ');
                if (confirm && a.text.length < 8) return setState(() => err = 'Use at least 8 characters');
                Navigator.pop(ctx, a.text);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _backupNow(BackupStorage storage) async {
    final pass = await _askPassphrase(confirm: true);
    if (pass == null) return;
    final r = await _run('Encrypting and uploading', () => _s.backup.backupTo(storage, pass));
    if (r != null) {
      _lastBackup = await _s.backup.lastBackupAt();
      if (mounted) showSnack(context, 'Backup saved to ${storage.label}');
      await _refresh();
    }
  }

  Future<void> _exportToFile() async {
    final pass = await _askPassphrase(confirm: true);
    if (pass == null) return;
    await _run('Encrypting', () async {
      final dir = Directory(p.join((await getTemporaryDirectory()).path, 'backups'));
      final remote = await _s.backup.backupTo(LocalFolderBackupStorage(dir), pass);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(remote.id, mimeType: 'application/octet-stream')],
        text: 'SplitMate encrypted backup',
      ));
      _lastBackup = await _s.backup.lastBackupAt();
    });
  }

  Future<void> _restoreBytes(Future<List<int>> Function() load, String source) async {
    final fresh = await _s.backup.isFreshDevice();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(fresh
            ? 'Your identity, groups and expenses from the backup will be restored onto this phone.'
            : 'The backup is merged with what is on this phone. Nothing here is deleted or overwritten; '
                'records missing on this phone are added back. Edits made on both sides may show as conflicts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    final pass = await _askPassphrase(confirm: false);
    if (pass == null) return;
    final report = await _run('Downloading and verifying', () async {
      final bytes = await load();
      return _s.backup.restore(Uint8List.fromList(bytes), pass, source: source);
    });
    if (report != null && mounted) {
      showSnack(context,
          'Restored: ${report.ingest.applied} new record(s), ${report.ingest.duplicates} already present.');
    }
  }

  Future<void> _delete(RemoteBackup b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this backup?'),
        content: Text('${b.name} will be permanently removed from Google Drive.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run('Deleting', () => _drive!.delete(b));
    await _refresh();
  }

  Future<void> _toggleAuto(bool on) async {
    if (on) {
      final pass = await _askPassphrase(confirm: true);
      if (pass == null) return;
      await _s.secrets.write(_passKey, pass);
    } else {
      await _s.secrets.delete(_passKey);
    }
    await writeMeta(_s.log.db, _autoKey, on ? '1' : '0');
    setState(() => _auto = on);
  }

  @override
  Widget build(BuildContext context) {
    final drive = _drive;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (_busy) const LinearProgressIndicator(),
        if (_status != null) InfoBanner(icon: Icons.hourglass_top, text: _status!),
        if (_error != null) InfoBanner(icon: Icons.error_outline, color: context.money.owe, text: _error!),
        const InfoBanner(
          icon: Icons.phone_iphone,
          text: 'Your live data is on this phone. Backups are optional, encrypted copies used only for recovery — '
              'never for syncing with friends.',
        ),
        ListTile(
          leading: const Icon(Icons.schedule),
          title: const Text('Last backup'),
          subtitle: Text(_lastBackup == null
              ? 'Never'
              : DateFormat.yMMMd().add_jm().format(DateTime.fromMillisecondsSinceEpoch(_lastBackup!))),
        ),
        const SectionHeader('Google Drive (optional)'),
        if (drive == null)
          ListTile(
            leading: const Icon(Icons.add_to_drive),
            title: const Text('Connect Google account'),
            subtitle: const Text('Uses a private app folder only'),
            onTap: _busy ? null : _connect,
          )
        else ...[
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(drive.account.email),
            trailing: TextButton(onPressed: _busy ? null : _disconnect, child: const Text('Disconnect')),
          ),
          ListTile(
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Back up now'),
            onTap: _busy ? null : () => _backupNow(drive),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.autorenew),
            title: const Text('Automatic daily backup'),
            subtitle: const Text('When the app opens and the last backup is over a day old. '
                'Stores your passphrase in this phone\'s secure storage.'),
            value: _auto,
            onChanged: _busy ? null : _toggleAuto,
          ),
          SectionHeader('Backups in Drive',
              trailing: IconButton(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh))),
          if (_backups == null)
            const Padding(padding: EdgeInsets.all(20), child: Text('Not loaded'))
          else if (_backups!.isEmpty)
            const Padding(padding: EdgeInsets.all(20), child: Text('No backups yet'))
          else
            for (final b in _backups!)
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(DateFormat.yMMMd().add_jm().format(b.createdAt.toLocal())),
                subtitle: Text('${(b.sizeBytes / 1024).toStringAsFixed(1)} KB · encrypted'),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) => v == 'restore'
                      ? _restoreBytes(() => drive.download(b), 'Google Drive')
                      : _delete(b),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'restore', child: Text('Restore')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
        ],
        const SectionHeader('File'),
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: const Text('Export encrypted backup file'),
          subtitle: const Text('Save or send it anywhere you like'),
          onTap: _busy ? null : _exportToFile,
        ),
        ListTile(
          leading: const Icon(Icons.restore),
          title: const Text('Restore from a file'),
          onTap: _busy
              ? null
              : () async {
                  final f = await FilePicker.pickFile(dialogTitle: 'Choose a .smbk backup');
                  if (f != null) await _restoreBytes(f.readAsBytes, 'file');
                },
        ),
        const SectionHeader('If you lose this phone'),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            '1. Install SplitMate on the new phone.\n'
            '2. On the welcome screen choose "Restore from a backup file", or get started and then open '
            'Account → Backup to restore from Google Drive.\n'
            '3. Enter your recovery passphrase. Your identity is restored, so friends\' phones keep '
            'recognising you.\n'
            '4. Sync with a friend to receive anything added after the backup.\n\n'
            'Without a backup, ask a friend who shares your groups to sync — you will get the shared '
            'groups back, but under a new identity they must re-invite.',
          ),
        ),
      ]),
    );
  }
}
