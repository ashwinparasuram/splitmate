import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../data/ledger_repository.dart';
import '../identity/identity.dart';
import 'change_log.dart';
import 'secure_channel.dart';
import 'transport/endpoints.dart';
import 'transport/frame_channel.dart';

const _pairPrefix = 'splitmate:pair:v1:';
const _connectPrefix = 'splitmate:connect:v1:';
const invitationLifetime = Duration(minutes: 10);

class PairingException implements Exception {
  PairingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A short-lived pairing invitation, shown as a QR code.
///
/// It names the inviter's public keys (so the scanner can pin them) and
/// carries a one-time secret proving the scanner actually saw the code.
/// It is *not* proof of identity on its own: both users still compare the
/// SAS and approve.
class Invitation {
  Invitation({
    required this.id,
    required this.secret,
    required this.userId,
    required this.deviceId,
    required this.displayName,
    required this.ed25519Pub,
    required this.x25519Pub,
    required this.expiresAt,
    required this.endpoints,
    this.groupId,
    this.groupName,
  });

  final String id;
  final List<int> secret;
  final String userId;
  final String deviceId;
  final String displayName;
  final String ed25519Pub;
  final String x25519Pub;
  final int expiresAt;
  final List<String> endpoints;
  final String? groupId;
  final String? groupName;

  bool isExpired(int now) => now > expiresAt;

  String encode() => _pairPrefix +
      b64(utf8.encode(jsonEncode({
        'i': id,
        's': b64(secret),
        'u': userId,
        'd': deviceId,
        'n': displayName,
        'e': ed25519Pub,
        'x': x25519Pub,
        'exp': expiresAt,
        'ep': endpoints,
        if (groupId != null) 'g': groupId,
        if (groupName != null) 'gn': groupName,
      })));

  static Invitation decode(String text) {
    if (!text.startsWith(_pairPrefix)) throw PairingException('Not a SplitMate pairing code');
    try {
      final m = jsonDecode(utf8.decode(unb64(text.substring(_pairPrefix.length)))) as Map;
      return Invitation(
        id: m['i'] as String,
        secret: unb64(m['s'] as String),
        userId: m['u'] as String,
        deviceId: m['d'] as String,
        displayName: m['n'] as String,
        ed25519Pub: m['e'] as String,
        x25519Pub: m['x'] as String,
        expiresAt: m['exp'] as int,
        endpoints: (m['ep'] as List).cast<String>(),
        groupId: m['g'] as String?,
        groupName: m['gn'] as String?,
      );
    } catch (_) {
      throw PairingException('The pairing code is damaged');
    }
  }
}

/// QR for re-connecting already paired devices (no secret, keys pinned).
class ConnectCode {
  ConnectCode(this.deviceId, this.endpoints);
  final String deviceId;
  final List<String> endpoints;

  String encode() =>
      _connectPrefix + b64(utf8.encode(jsonEncode({'d': deviceId, 'ep': endpoints})));

  static ConnectCode? tryDecode(String text) {
    if (!text.startsWith(_connectPrefix)) return null;
    try {
      final m = jsonDecode(utf8.decode(unb64(text.substring(_connectPrefix.length)))) as Map;
      return ConnectCode(m['d'] as String, (m['ep'] as List).cast<String>());
    } catch (_) {
      return null;
    }
  }
}

/// Creates invitations, validates them for incoming handshakes, and records
/// paired devices once both users approve.
class PairingService {
  PairingService(this.repo);
  final LedgerRepository repo;

  ChangeLog get log => repo.log;
  Database get db => repo.db;

  /// Secrets live only in memory while the QR is on screen.
  final Map<String, (List<int>, Invitation)> _open = {};

  Future<Invitation> createInvitation({
    required List<String> endpoints,
    String? groupId,
    String? placeholderUserId,
  }) async {
    final id = const Uuid().v4();
    final secret = randomBytes(32);
    final me = log.identity;
    final group = groupId == null ? null : await repo.group(groupId);
    final inv = Invitation(
      id: id,
      secret: secret,
      userId: me.userId,
      deviceId: me.deviceId,
      displayName: me.displayName,
      ed25519Pub: me.ed25519Pub,
      x25519Pub: me.x25519Pub,
      expiresAt: log.now() + invitationLifetime.inMilliseconds,
      endpoints: endpoints,
      groupId: groupId,
      groupName: group?.name,
    );
    await db.insert('group_invitations', {
      'id': id,
      'group_id': groupId,
      'token_hash': crypto.sha256.convert(secret).toString(),
      'created_by': me.userId,
      'placeholder_user_id': placeholderUserId,
      'status': 'open',
      'expires_at': inv.expiresAt,
      'created_at': log.now(),
    });
    _open[id] = (secret, inv);
    return inv;
  }

  Future<void> revokeInvitation(String id) async {
    _open.remove(id);
    await db.update('group_invitations', {'status': 'revoked'},
        where: 'id = ? AND status = ?', whereArgs: [id, 'open']);
  }

  /// Secret for an open, unexpired invitation (used by the responder).
  Future<List<int>?> secretFor(String inviteId) async {
    final entry = _open[inviteId];
    if (entry == null) return null;
    final rows = await db.query('group_invitations',
        where: 'id = ? AND status = ?', whereArgs: [inviteId, 'open']);
    if (rows.isEmpty) return null;
    if ((rows.first['expires_at']! as int) < log.now()) {
      await db.update('group_invitations', {'status': 'expired'},
          where: 'id = ?', whereArgs: [inviteId]);
      _open.remove(inviteId);
      return null;
    }
    final hash = crypto.sha256.convert(entry.$1).toString();
    return hash == rows.first['token_hash'] ? entry.$1 : null;
  }

  /// A peer is known if its identity key was paired before. A different
  /// device id with the same key is the same person after a backup restore,
  /// so it is recorded as an additional device rather than refused.
  Future<bool> isKnownPeer(PeerIdentity peer) async {
    final r = await db.query('sync_devices',
        where: 'user_id = ? AND ed25519_pub = ? AND status = ?',
        whereArgs: [peer.userId, peer.ed25519Pub, 'paired']);
    if (r.isEmpty) return false;
    if (!r.any((row) => row['device_id'] == peer.deviceId)) {
      final revoked = await db.query('sync_devices',
          where: 'device_id = ? AND status = ?', whereArgs: [peer.deviceId, 'revoked']);
      if (revoked.isNotEmpty) return false;
      await db.insert('sync_devices', {
        ...r.first,
        'device_id': peer.deviceId,
        'display_name': peer.displayName,
        'paired_at': log.now(),
        'last_sync_at': null,
        'peer_vector': '{}',
      });
    }
    return true;
  }

  Future<String?> pinnedKeyFor(String deviceId) async {
    final r = await db.query('sync_devices',
        columns: ['ed25519_pub'], where: 'device_id = ? AND status = ?', whereArgs: [deviceId, 'paired']);
    return r.isEmpty ? null : r.first['ed25519_pub']! as String;
  }

  /// After the handshake in pair mode: exchange explicit approvals, then
  /// record the peer. [localApproval] completes when the local user taps
  /// Approve or Reject after comparing the SAS.
  Future<PeerIdentity> confirm({
    required HandshakeResult hs,
    required Future<bool> localApproval,
    String? inviteId,
    Invitation? scannedInvitation,
    String? endpoint,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final ch = hs.channel;
    final ok = await localApproval;
    await ch.sendJson({'t': 'approve', 'ok': ok});
    if (!ok) {
      await ch.close();
      throw PairingException('You declined the connection');
    }
    final reply = await ch.receiveJson(timeout: timeout);
    if (reply['t'] != 'approve' || reply['ok'] != true) {
      await ch.close();
      throw PairingException('${hs.peer.displayName} declined the connection');
    }

    final peer = hs.peer;
    await _recordPeer(peer, endpoint: endpoint);

    if (inviteId != null) {
      // We are the inviter: add the verified person to the invited group.
      final inv = (await db.query('group_invitations', where: 'id = ?', whereArgs: [inviteId])).first;
      final groupId = inv['group_id'] as String?;
      final placeholder = inv['placeholder_user_id'] as String?;
      if (groupId != null) {
        await repo.addVerifiedMember(groupId,
            userId: peer.userId,
            displayName: peer.displayName,
            ed25519Pub: peer.ed25519Pub,
            x25519Pub: peer.x25519Pub);
        if (placeholder != null && placeholder != peer.userId) {
          await repo.linkPlaceholder(groupId, placeholder, peer.userId);
        }
      }
      await db.update('group_invitations', {'status': 'used', 'used_by_user_id': peer.userId},
          where: 'id = ?', whereArgs: [inviteId]);
      _open.remove(inviteId);
    }
    if (scannedInvitation?.groupId != null) {
      // We scanned an invitation to a named group: that is our consent.
      await writeMeta(db, 'consent:${scannedInvitation!.groupId}', 'active');
      await db.update('groups', {'local_status': 'active'},
          where: 'id = ?', whereArgs: [scannedInvitation.groupId]);
    }
    repo.notifyChanged();
    return peer;
  }

  Future<void> _recordPeer(PeerIdentity peer, {String? endpoint}) async {
    final now = log.now();
    await db.transaction((txn) async {
      final existing = await txn.query('users', where: 'id = ?', whereArgs: [peer.userId]);
      if (existing.isEmpty) {
        await txn.insert('users', {
          'id': peer.userId,
          'display_name': peer.displayName,
          'ed25519_pub': peer.ed25519Pub,
          'x25519_pub': peer.x25519Pub,
          'is_local': 0,
          'created_at': now,
          'updated_at': now,
        });
      } else if (existing.first['ed25519_pub'] != null &&
          existing.first['ed25519_pub'] != peer.ed25519Pub) {
        throw PairingException(
            '${peer.displayName} already has a different key on this device. '
            'If they reinstalled the app, remove the old device first.');
      } else {
        await txn.update('users',
            {'ed25519_pub': peer.ed25519Pub, 'x25519_pub': peer.x25519Pub, 'updated_at': now},
            where: 'id = ?', whereArgs: [peer.userId]);
      }
      await txn.insert(
          'sync_devices',
          {
            'device_id': peer.deviceId,
            'user_id': peer.userId,
            'ed25519_pub': peer.ed25519Pub,
            'x25519_pub': peer.x25519Pub,
            'display_name': peer.displayName,
            'status': 'paired',
            'paired_at': now,
            'last_endpoint': endpoint,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('friends', {'user_id': peer.userId, 'created_at': now, 'updated_at': now},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    });
  }

  Future<void> revokeDevice(String deviceId) async {
    await db.update('sync_devices', {'status': 'revoked'}, where: 'device_id = ?', whereArgs: [deviceId]);
    repo.notifyChanged();
  }

  /// Connects to whichever endpoint answers first (LAN, IPv6 or a router
  /// port mapping). There is no relay: if none is reachable, the user is
  /// pointed at the sync-file fallback.
  static Future<(FrameChannel, String)> dial(List<String> endpoints) async {
    try {
      return await dialAny(endpoints);
    } on TransportException {
      throw PairingException(
          'Could not reach the other phone. Over the internet this needs IPv6 or a router that '
          'allows automatic port opening (UPnP/NAT-PMP) on the phone showing the code; many '
          'mobile networks block it. Try both phones on one Wi-Fi or hotspot, or send a sync file.');
    }
  }
}
