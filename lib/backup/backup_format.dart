import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import '../identity/identity.dart';
import '../sync/secure_channel.dart' show randomBytes;

const _magic = [0x53, 0x4d, 0x42, 0x4b]; // "SMBK"
const int kBackupFormatVersion = 1;

class BackupFormatException implements Exception {
  BackupFormatException(this.message, {this.wrongKeyOrCorrupt = false});
  final String message;
  final bool wrongKeyOrCorrupt;
  @override
  String toString() => message;
}

/// Argon2id cost. Defaults follow the OWASP minimum (19 MiB, 2 passes).
class KdfParams {
  const KdfParams({this.memoryKiB = 19456, this.iterations = 2, this.parallelism = 1});
  final int memoryKiB;
  final int iterations;
  final int parallelism;

  /// Cheap parameters for unit tests only.
  static const testing = KdfParams(memoryKiB: 64, iterations: 1);
}

class BackupHeader {
  BackupHeader(this.json, this.bytes);
  final Map<String, Object?> json;
  final Uint8List bytes;

  int get formatVersion => json['format_version']! as int;
  int get schemaVersion => json['schema_version']! as int;
  int get createdAt => json['created_at']! as int;
  String get userId => json['user_id']! as String;
  String get displayName => (json['display_name'] as String?) ?? '';
  String get payloadSha256 => json['payload_sha256']! as String;
}

/// Encrypted backup container. See docs/DESIGN.md §10.
///
/// "SMBK" | u8 format | u32 header_len | header JSON | AES-256-GCM(gzip(JSON))
/// The header is authenticated as AAD, so it cannot be altered either.
class BackupCodec {
  static final _aead = AesGcm.with256bits();

  static Future<SecretKey> deriveKey(String passphrase, List<int> salt, KdfParams p) =>
      Argon2id(
        parallelism: p.parallelism,
        memory: p.memoryKiB,
        iterations: p.iterations,
        hashLength: 32,
      ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);

  static Future<Uint8List> encode({
    required Map<String, Object?> payload,
    required String passphrase,
    required Map<String, Object?> headerFields,
    KdfParams kdf = const KdfParams(),
  }) async {
    if (passphrase.length < 8) {
      throw BackupFormatException('Use a recovery passphrase of at least 8 characters');
    }
    final plain = gzip.encode(utf8.encode(jsonEncode(payload)));
    final salt = randomBytes(16);
    final nonce = _aead.newNonce();
    final header = utf8.encode(jsonEncode({
      ...headerFields,
      'format_version': kBackupFormatVersion,
      'kdf': {
        'alg': 'argon2id',
        'm': kdf.memoryKiB,
        't': kdf.iterations,
        'p': kdf.parallelism,
        'salt': b64(salt),
      },
      'cipher': 'aes-256-gcm',
      'nonce': b64(nonce),
      'payload_sha256': crypto.sha256.convert(plain).toString(),
      'payload_length': plain.length,
    }));
    final key = await deriveKey(passphrase, salt, kdf);
    final box = await _aead.encrypt(plain, secretKey: key, nonce: nonce, aad: header);
    return (BytesBuilder()
          ..add(_magic)
          ..addByte(kBackupFormatVersion)
          ..add((ByteData(4)..setUint32(0, header.length)).buffer.asUint8List())
          ..add(header)
          ..add(box.cipherText)
          ..add(box.mac.bytes))
        .takeBytes();
  }

  /// Reads the unencrypted (but authenticated) header without the passphrase.
  static BackupHeader readHeader(Uint8List bytes) {
    if (bytes.length < 9 || !List.generate(4, (i) => bytes[i] == _magic[i]).every((x) => x)) {
      throw BackupFormatException('This is not a SplitMate backup');
    }
    if (bytes[4] > kBackupFormatVersion) {
      throw BackupFormatException('This backup needs a newer version of SplitMate');
    }
    final len = ByteData.sublistView(bytes, 5, 9).getUint32(0);
    if (9 + len + 16 > bytes.length) throw BackupFormatException('The backup file is truncated');
    final hb = Uint8List.sublistView(bytes, 9, 9 + len);
    try {
      final json = (jsonDecode(utf8.decode(hb)) as Map).cast<String, Object?>();
      return BackupHeader(json, Uint8List.fromList(hb));
    } catch (_) {
      throw BackupFormatException('The backup header is damaged');
    }
  }

  static Future<Map<String, Object?>> decode(Uint8List bytes, String passphrase) async {
    final header = readHeader(bytes);
    final h = header.json;
    final kdf = (h['kdf'] as Map?)?.cast<String, Object?>();
    if (kdf == null || kdf['alg'] != 'argon2id' || h['cipher'] != 'aes-256-gcm') {
      throw BackupFormatException('Unsupported backup encryption');
    }
    final m = kdf['m'] as int, t = kdf['t'] as int, p = kdf['p'] as int;
    if (m > 1 << 20 || t > 10 || p > 8) throw BackupFormatException('Unreasonable KDF parameters');
    final key = await deriveKey(
        passphrase, unb64(kdf['salt']! as String), KdfParams(memoryKiB: m, iterations: t, parallelism: p));
    final start = 9 + header.bytes.length;
    final ct = bytes.sublist(start, bytes.length - 16);
    final mac = bytes.sublist(bytes.length - 16);
    List<int> plain;
    try {
      plain = await _aead.decrypt(SecretBox(ct, nonce: unb64(h['nonce']! as String), mac: Mac(mac)),
          secretKey: key, aad: header.bytes);
    } on SecretBoxAuthenticationError {
      throw BackupFormatException('Wrong passphrase, or the backup is corrupted',
          wrongKeyOrCorrupt: true);
    }
    if (plain.length != h['payload_length'] ||
        crypto.sha256.convert(plain).toString() != h['payload_sha256']) {
      throw BackupFormatException('Backup checksum mismatch', wrongKeyOrCorrupt: true);
    }
    try {
      return (jsonDecode(utf8.decode(gzip.decode(plain))) as Map).cast<String, Object?>();
    } catch (_) {
      throw BackupFormatException('The backup contents are damaged');
    }
  }
}
