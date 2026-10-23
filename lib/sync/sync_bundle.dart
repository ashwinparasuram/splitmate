import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../identity/identity.dart';
import 'change.dart';
import 'change_log.dart';

const _magic = [0x53, 0x4d, 0x53, 0x59]; // "SMSY"
const int kBundleFormatVersion = 1;

class BundleException implements Exception {
  BundleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A sealed, signed batch of changes for one paired peer, exchanged as a
/// file over any channel when the devices cannot reach each other directly.
///
/// Layout: "SMSY" | u8 version | u32 header_len | header JSON |
///         u32 ct_len | AES-256-GCM ciphertext+tag | Ed25519 sig (64)
/// Key: HKDF-SHA256(X25519(ephemeral, recipient static), salt = SHA-256(header)).
class SyncBundle {
  static final _aead = AesGcm.with256bits();
  static final _x25519 = X25519();

  static Future<Uint8List> seal({
    required LocalIdentity sender,
    required String recipientUserId,
    required String recipientDeviceId,
    required String recipientX25519Pub,
    required List<SyncChange> changes,
    required Map<String, Map<String, int>> vectors,
    required int now,
  }) async {
    final eph = await _x25519.newKeyPair();
    final ephPub = await eph.extractPublicKey();
    final nonce = _aead.newNonce();
    final header = utf8.encode(jsonEncode({
      'v': kBundleFormatVersion,
      'from_user': sender.userId,
      'from_device': sender.deviceId,
      'to_user': recipientUserId,
      'to_device': recipientDeviceId,
      'eph': b64(ephPub.bytes),
      'nonce': b64(nonce),
      'created_at': now,
      'count': changes.length,
    }));
    final key = await _key(eph, recipientX25519Pub, header);
    final plain = gzip.encode(utf8.encode(jsonEncode({
      'changes': [for (final c in changes) c.toWire()],
      'vectors': vectors,
    })));
    final box = await _aead.encrypt(plain, secretKey: key, nonce: nonce, aad: header);
    final body = BytesBuilder()
      ..add(_magic)
      ..addByte(kBundleFormatVersion)
      ..add(_u32(header.length))
      ..add(header)
      ..add(_u32(box.cipherText.length + 16))
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    final signed = body.takeBytes();
    final sig = await sender.sign(signed);
    return Uint8List.fromList([...signed, ...sig]);
  }

  static Future<SecretKey> _key(SimpleKeyPair mine, String theirPubB64, List<int> header) async {
    final shared = await _x25519.sharedSecretKey(
        keyPair: mine,
        remotePublicKey: SimplePublicKey(unb64(theirPubB64), type: KeyPairType.x25519));
    final salt = (await Sha256().hash(header)).bytes;
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, nonce: salt, info: utf8.encode('splitmate/v1 bundle'));
  }

  static List<int> _u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

  /// Verifies and decrypts. [senderKeyFor] returns the pinned Ed25519 key of
  /// a paired device, or null if the sender is not paired.
  static Future<({String fromUser, String fromDevice, List<SyncChange> changes, int malformed})> open({
    required Uint8List bytes,
    required LocalIdentity me,
    required Future<String?> Function(String deviceId) senderKeyFor,
  }) async {
    try {
      if (bytes.length < 9 + 64 || !_startsWith(bytes, _magic)) {
        throw BundleException('This is not a SplitMate sync file');
      }
      if (bytes[4] != kBundleFormatVersion) {
        throw BundleException('This sync file needs a newer version of SplitMate');
      }
      final bd = ByteData.sublistView(bytes);
      final hlen = bd.getUint32(5);
      final header = bytes.sublist(9, 9 + hlen);
      final clen = bd.getUint32(9 + hlen);
      final ctStart = 13 + hlen;
      if (ctStart + clen + 64 != bytes.length) throw BundleException('The sync file is truncated');
      final h = jsonDecode(utf8.decode(header)) as Map;
      if (h['to_user'] != me.userId) {
        throw BundleException('This sync file was made for someone else');
      }
      final fromDevice = h['from_device'] as String;
      final key = await senderKeyFor(fromDevice);
      if (key == null) throw BundleException('The sender is not a paired device');
      final signed = bytes.sublist(0, ctStart + clen);
      final sig = bytes.sublist(ctStart + clen);
      if (!await verifyEd25519(signed, sig, key)) {
        throw BundleException('The sync file signature is invalid');
      }
      final aesKey = await _key(me.agreementKeyPair, h['eph'] as String, header);
      final ct = bytes.sublist(ctStart, ctStart + clen - 16);
      final mac = bytes.sublist(ctStart + clen - 16, ctStart + clen);
      final plain = await _aead.decrypt(
          SecretBox(ct, nonce: unb64(h['nonce'] as String), mac: Mac(mac)),
          secretKey: aesKey,
          aad: header);
      final payload = jsonDecode(utf8.decode(gzip.decode(plain))) as Map;
      final changes = <SyncChange>[];
      var malformed = 0;
      for (final raw in (payload['changes'] as List)) {
        try {
          changes.add(SyncChange.fromWire(raw));
        } on FormatException {
          malformed++;
        }
      }
      return (
        fromUser: h['from_user'] as String,
        fromDevice: fromDevice,
        changes: changes,
        malformed: malformed,
      );
    } on BundleException {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw BundleException('The sync file could not be decrypted');
    } catch (e) {
      throw BundleException('The sync file is damaged');
    }
  }

  static bool _startsWith(List<int> b, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (b[i] != prefix[i]) return false;
    }
    return true;
  }
}

/// Builds and imports bundles against the local ledger.
class BundleService {
  BundleService(this.log);
  final ChangeLog log;

  Future<Uint8List> exportFor(String peerDeviceId, {bool full = false}) async {
    final db = log.db;
    final rows = await db.query('sync_devices',
        where: 'device_id = ? AND status = ?', whereArgs: [peerDeviceId, 'paired']);
    if (rows.isEmpty) throw BundleException('That device is not paired');
    final peer = rows.first;
    final peerUser = peer['user_id']! as String;
    final known = full ? const <String, Object?>{} : (jsonDecode(peer['peer_vector']! as String) as Map).cast<String, Object?>();
    final groups = await db.rawQuery('''
      SELECT g.id FROM groups g JOIN group_members m ON m.group_id = g.id
      WHERE m.user_id = ? AND m.status = 'active' AND g.local_status <> 'declined'
      ORDER BY g.id''', [peerUser]);
    final changes = <SyncChange>[];
    final vectors = <String, Map<String, int>>{};
    for (final g in groups) {
      final id = g['id']! as String;
      final v = (known[id] as Map?)?.map((k, val) => MapEntry(k as String, val as int)) ?? const {};
      changes.addAll(await log.missingFor(id, v));
      vectors[id] = await log.vectorFor(id);
    }
    return SyncBundle.seal(
      sender: log.identity,
      recipientUserId: peerUser,
      recipientDeviceId: peerDeviceId,
      recipientX25519Pub: peer['x25519_pub']! as String,
      changes: changes,
      vectors: vectors,
      now: log.now(),
    );
  }

  Future<IngestReport> import(Uint8List bytes) async {
    final db = log.db;
    final opened = await SyncBundle.open(
      bytes: bytes,
      me: log.identity,
      senderKeyFor: (deviceId) async {
        final r = await db.query('sync_devices',
            columns: ['ed25519_pub'], where: 'device_id = ? AND status = ?', whereArgs: [deviceId, 'paired']);
        return r.isEmpty ? null : r.first['ed25519_pub']! as String;
      },
    );
    final declined = {
      for (final r in await db.query('groups', columns: ['id'], where: "local_status = 'declined'"))
        r['id']! as String,
    };
    final accepted = opened.changes.where((c) => !declined.contains(c.groupId)).toList();
    final report = await log.ingest(accepted);
    report.rejected += opened.malformed;
    await db.update('sync_devices', {'last_sync_at': log.now()},
        where: 'device_id = ?', whereArgs: [opened.fromDevice]);
    return report;
  }
}
