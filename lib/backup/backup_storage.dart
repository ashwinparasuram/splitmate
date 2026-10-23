import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

enum BackupStorageError { unavailable, authExpired, accessRevoked, uploadFailed, downloadFailed, notFound }

class BackupStorageException implements Exception {
  BackupStorageException(this.kind, this.message);
  final BackupStorageError kind;
  final String message;
  @override
  String toString() => message;
}

class RemoteBackup {
  const RemoteBackup({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.createdAt,
  });
  final String id;
  final String name;
  final int sizeBytes;
  final DateTime createdAt;
}

/// Where encrypted backups are kept. Implementations: Google Drive
/// (appDataFolder) and a local folder (manual export / tests).
abstract class BackupStorage {
  String get label;
  Future<List<RemoteBackup>> list();
  Future<RemoteBackup> upload(String name, Uint8List bytes);
  Future<Uint8List> download(RemoteBackup backup);
  Future<void> delete(RemoteBackup backup);
}

class LocalFolderBackupStorage implements BackupStorage {
  LocalFolderBackupStorage(this.directory);
  final Directory directory;

  @override
  String get label => 'This device';

  @override
  Future<List<RemoteBackup>> list() async {
    if (!await directory.exists()) return [];
    final files = await directory
        .list()
        .where((e) => e is File && e.path.endsWith('.smbk'))
        .cast<File>()
        .toList();
    final out = <RemoteBackup>[];
    for (final f in files) {
      final stat = await f.stat();
      out.add(RemoteBackup(
          id: f.path, name: p.basename(f.path), sizeBytes: stat.size, createdAt: stat.modified));
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  @override
  Future<RemoteBackup> upload(String name, Uint8List bytes) async {
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, name));
    // Write-then-rename so a crash never leaves a half-written backup.
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return RemoteBackup(id: file.path, name: name, sizeBytes: bytes.length, createdAt: DateTime.now());
  }

  @override
  Future<Uint8List> download(RemoteBackup backup) async {
    final f = File(backup.id);
    if (!await f.exists()) {
      throw BackupStorageException(BackupStorageError.notFound, 'Backup file not found');
    }
    return f.readAsBytes();
  }

  @override
  Future<void> delete(RemoteBackup backup) async {
    final f = File(backup.id);
    if (await f.exists()) await f.delete();
  }
}
