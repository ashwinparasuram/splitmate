import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

import 'backup_storage.dart';

/// Only the app's private Drive folder: SplitMate cannot see any other file.
const driveScopes = [drive.DriveApi.driveAppdataScope];

/// Optional Google Drive backup destination (appDataFolder).
///
/// Drive only ever receives already-encrypted `.smbk` files and is never
/// used for live data or sync.
class DriveBackupStorage implements BackupStorage {
  DriveBackupStorage(this.account);
  final GoogleSignInAccount account;

  @override
  String get label => 'Google Drive (${account.email})';

  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize();
    _initialized = true;
  }

  /// Interactive: asks the user to pick an account and grant the scope.
  static Future<DriveBackupStorage> connect() async {
    await ensureInitialized();
    try {
      final account = await GoogleSignIn.instance.authenticate(scopeHint: driveScopes);
      await account.authorizationClient.authorizeScopes(driveScopes);
      return DriveBackupStorage(account);
    } on GoogleSignInException catch (e) {
      throw BackupStorageException(
          e.code == GoogleSignInExceptionCode.canceled
              ? BackupStorageError.accessRevoked
              : BackupStorageError.unavailable,
          e.code == GoogleSignInExceptionCode.canceled
              ? 'Google sign-in was cancelled'
              : 'Google sign-in failed: ${e.description ?? e.code.name}');
    }
  }

  /// Silent reconnect at startup; null if user interaction is needed.
  static Future<DriveBackupStorage?> restore() async {
    try {
      await ensureInitialized();
      final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
      return account == null ? null : DriveBackupStorage(account);
    } catch (_) {
      return null;
    }
  }

  static Future<void> disconnect() async {
    await ensureInitialized();
    await GoogleSignIn.instance.disconnect();
  }

  Future<drive.DriveApi> _api({bool interactive = false}) async {
    var headers = await account.authorizationClient.authorizationHeaders(driveScopes);
    if (headers == null && interactive) {
      headers = await account.authorizationClient
          .authorizationHeaders(driveScopes, promptIfNecessary: true);
    }
    if (headers == null) {
      throw BackupStorageException(BackupStorageError.authExpired,
          'Google Drive access expired. Reconnect your Google account.');
    }
    return drive.DriveApi(_HeaderClient(headers));
  }

  Future<T> _guard<T>(BackupStorageError onFail, Future<T> Function(drive.DriveApi api) op) async {
    try {
      return await op(await _api(interactive: true));
    } on BackupStorageException {
      rethrow;
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 401) {
        throw BackupStorageException(
            BackupStorageError.authExpired, 'Google Drive access expired. Reconnect your account.');
      }
      if (e.status == 403) {
        throw BackupStorageException(
            BackupStorageError.accessRevoked, 'Google Drive access was revoked or is not allowed.');
      }
      if (e.status == 404) throw BackupStorageException(BackupStorageError.notFound, 'Backup not found');
      throw BackupStorageException(onFail, 'Google Drive error ${e.status}: ${e.message}');
    } on SocketException {
      throw BackupStorageException(
          BackupStorageError.unavailable, 'No internet connection. Your data is safe on this device.');
    } on TimeoutException {
      throw BackupStorageException(BackupStorageError.unavailable, 'Google Drive did not respond.');
    } on http.ClientException catch (e) {
      throw BackupStorageException(BackupStorageError.unavailable, 'Network error: ${e.message}');
    }
  }

  @override
  Future<List<RemoteBackup>> list() => _guard(BackupStorageError.unavailable, (api) async {
        final res = await api.files.list(
          spaces: 'appDataFolder',
          q: "name contains '.smbk' and trashed = false",
          $fields: 'files(id,name,size,createdTime)',
          orderBy: 'createdTime desc',
          pageSize: 100,
        );
        return [
          for (final f in res.files ?? const <drive.File>[])
            RemoteBackup(
              id: f.id!,
              name: f.name ?? 'backup.smbk',
              sizeBytes: int.tryParse(f.size ?? '') ?? 0,
              createdAt: f.createdTime ?? DateTime.fromMillisecondsSinceEpoch(0),
            ),
        ];
      });

  @override
  Future<RemoteBackup> upload(String name, Uint8List bytes) =>
      _guard(BackupStorageError.uploadFailed, (api) async {
        final file = await api.files.create(
          drive.File(name: name, parents: ['appDataFolder'], mimeType: 'application/octet-stream'),
          uploadMedia: drive.Media(Stream.value(bytes), bytes.length),
          $fields: 'id,name,size,createdTime',
        );
        if ((int.tryParse(file.size ?? '') ?? bytes.length) != bytes.length) {
          throw BackupStorageException(BackupStorageError.uploadFailed, 'Upload was incomplete');
        }
        return RemoteBackup(
            id: file.id!, name: name, sizeBytes: bytes.length, createdAt: file.createdTime ?? DateTime.now());
      });

  @override
  Future<Uint8List> download(RemoteBackup backup) =>
      _guard(BackupStorageError.downloadFailed, (api) async {
        final media = await api.files.get(backup.id,
            downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
        final builder = BytesBuilder(copy: false);
        await for (final chunk in media.stream) {
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        if (backup.sizeBytes > 0 && bytes.length != backup.sizeBytes) {
          throw BackupStorageException(
              BackupStorageError.downloadFailed, 'Download was interrupted. Try again.');
        }
        return bytes;
      });

  @override
  Future<void> delete(RemoteBackup backup) =>
      _guard(BackupStorageError.unavailable, (api) => api.files.delete(backup.id));
}

class _HeaderClient extends http.BaseClient {
  _HeaderClient(this._headers);
  final Map<String, String> _headers;
  final _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request).timeout(const Duration(minutes: 2));
  }
}
