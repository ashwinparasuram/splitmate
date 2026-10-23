import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/canonical_json.dart';
import '../data/db/migrations.dart';
import '../identity/identity.dart';
import 'transport/frame_channel.dart';

const int kProtocolVersion = 1;
const List<int> kSupportedProtocols = [1];

enum HandshakeMode { pair, sync }

class HandshakeException implements Exception {
  HandshakeException(this.message);
  final String message;
  @override
  String toString() => 'Handshake failed: $message';
}

/// The authenticated identity of the device at the other end.
class PeerIdentity {
  const PeerIdentity({
    required this.userId,
    required this.deviceId,
    required this.displayName,
    required this.ed25519Pub,
    required this.x25519Pub,
    required this.schemaVersion,
  });
  final String userId;
  final String deviceId;
  final String displayName;
  final String ed25519Pub;
  final String x25519Pub;
  final int schemaVersion;
}

final _aead = AesGcm.with256bits();
final _x25519 = X25519();
final _sha256 = Sha256();
final _hmac = Hmac.sha256();
final _rng = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

/// Encrypted, authenticated, replay-protected record layer.
///
/// AES-256-GCM, nonce = 4-byte direction label + 64-bit counter. The
/// receiver accepts only the next expected counter, so replayed, dropped
/// or reordered records are detected.
class SecureChannel {
  SecureChannel._(this.raw, this._sendKey, this._recvKey, this._sendLabel, this._recvLabel);

  final FrameChannel raw;
  final SecretKey _sendKey;
  final SecretKey _recvKey;
  final List<int> _sendLabel;
  final List<int> _recvLabel;
  int _sendCounter = 0;
  int _recvCounter = 0;

  static List<int> _nonce(List<int> label, int counter) {
    final b = ByteData(12);
    for (var i = 0; i < 4; i++) {
      b.setUint8(i, label[i]);
    }
    b.setUint64(4, counter);
    return b.buffer.asUint8List();
  }

  static Future<Uint8List> _seal(
      SecretKey key, List<int> label, int counter, List<int> plaintext) async {
    final header = (ByteData(8)..setUint64(0, counter)).buffer.asUint8List();
    final box = await _aead.encrypt(plaintext,
        secretKey: key, nonce: _nonce(label, counter), aad: header);
    return Uint8List.fromList([...header, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<List<int>> _open(
      SecretKey key, List<int> label, int expected, Uint8List frame) async {
    if (frame.length < 8 + 16) throw HandshakeException('record too short');
    final counter = ByteData.sublistView(frame, 0, 8).getUint64(0);
    if (counter != expected) {
      throw HandshakeException('unexpected record counter (replay or loss)');
    }
    try {
      return await _aead.decrypt(
        SecretBox(frame.sublist(8, frame.length - 16),
            nonce: _nonce(label, counter), mac: Mac(frame.sublist(frame.length - 16))),
        secretKey: key,
        aad: frame.sublist(0, 8),
      );
    } on SecretBoxAuthenticationError {
      throw HandshakeException('record failed authentication');
    }
  }

  Future<void> sendJson(Map<String, Object?> message) async {
    final frame = await _seal(_sendKey, _sendLabel, _sendCounter++, utf8.encode(jsonEncode(message)));
    await raw.send(frame);
  }

  Future<Map<String, Object?>> receiveJson({Duration timeout = const Duration(seconds: 30)}) async {
    final frame = await raw.receive(timeout: timeout);
    final plain = await _open(_recvKey, _recvLabel, _recvCounter, frame);
    _recvCounter++;
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map) throw HandshakeException('message is not an object');
    return decoded.cast<String, Object?>();
  }

  Future<void> close() => raw.close();
}

class HandshakeResult {
  HandshakeResult(this.channel, this.peer, this.sas, this.transcriptHash,
      {required this.mode, this.inviteId});
  final SecureChannel channel;
  final HandshakeMode mode;

  /// For a responder in pair mode: the invitation the peer proved.
  final String? inviteId;
  final PeerIdentity peer;

  /// 6-digit short authentication string both users compare when pairing.
  final String sas;
  final List<int> transcriptHash;
}

class _Keys {
  _Keys(this.hsI2R, this.hsR2I, this.appI2R, this.appR2I, this.sas);
  final SecretKey hsI2R, hsR2I, appI2R, appR2I;
  final String sas;
}

const _labelI2R = [0x49, 0x32, 0x52, 0x00];
const _labelR2I = [0x52, 0x32, 0x49, 0x00];
const _labelHsI2R = [0x68, 0x49, 0x32, 0x52];
const _labelHsR2I = [0x68, 0x52, 0x32, 0x49];

Future<_Keys> _derive(SecretKey shared, List<int> th) async {
  final hkdf = Hkdf(hmac: _hmac, outputLength: 32);
  Future<SecretKey> k(String label) =>
      hkdf.deriveKey(secretKey: shared, nonce: th, info: utf8.encode('splitmate/v1 $label'));
  final sasBytes = await (await k('sas')).extractBytes();
  final sasNum = ByteData.sublistView(Uint8List.fromList(sasBytes), 0, 4).getUint32(0) % 1000000;
  return _Keys(await k('hs i2r'), await k('hs r2i'), await k('app i2r'), await k('app r2i'),
      sasNum.toString().padLeft(6, '0'));
}

Map<String, Object?> _authBody(LocalIdentity me) => {
      't': 'auth',
      'user_id': me.userId,
      'device_id': me.deviceId,
      'display_name': me.displayName,
      'ed_pub': me.ed25519Pub,
      'x_pub': me.x25519Pub,
      'schema': kSchemaVersion,
    };

Future<PeerIdentity> _verifyAuth(Map<String, Object?> m, String role, List<int> th) async {
  if (m['t'] != 'auth') throw HandshakeException('expected auth, got ${m['t']}');
  for (final k in ['user_id', 'device_id', 'display_name', 'ed_pub', 'x_pub', 'sig']) {
    if (m[k] is! String) throw HandshakeException('auth.$k missing');
  }
  final ok = await verifyEd25519(
      [...utf8.encode(role), ...th], unb64(m['sig']! as String), m['ed_pub']! as String);
  if (!ok) throw HandshakeException('peer failed to prove its identity key');
  return PeerIdentity(
    userId: m['user_id']! as String,
    deviceId: m['device_id']! as String,
    displayName: m['display_name']! as String,
    ed25519Pub: m['ed_pub']! as String,
    x25519Pub: m['x_pub']! as String,
    schemaVersion: (m['schema'] as int?) ?? 1,
  );
}

/// SIGMA-I style mutual authentication over ephemeral X25519.
/// See docs/DESIGN.md §9. All primitives come from package:cryptography.
class Handshake {
  /// Runs the connecting side. [expectedPeerKey] pins the responder: from
  /// the scanned QR when pairing, from `sync_devices` when syncing.
  static Future<HandshakeResult> initiate({
    required FrameChannel raw,
    required LocalIdentity me,
    required HandshakeMode mode,
    required String expectedPeerKey,
    String? inviteId,
    List<int>? inviteSecret,
  }) async {
    try {
      final eph = await _x25519.newKeyPair();
      final ephPub = await eph.extractPublicKey();
      final hello1 = canonicalBytes({
        't': 'hello',
        'protocols': kSupportedProtocols,
        'mode': mode.name,
        'eph': b64(ephPub.bytes),
        'nonce': b64(randomBytes(16)),
        if (inviteId != null) 'invite_id': inviteId,
      });
      await raw.send(Uint8List.fromList(hello1));
      final hello2 = await raw.receive();
      final h2 = jsonDecode(utf8.decode(hello2));
      if (h2 is! Map) throw HandshakeException('bad hello');
      if (h2['t'] == 'error') throw HandshakeException('peer refused: ${h2['message']}');
      if (h2['t'] != 'hello' || !kSupportedProtocols.contains(h2['protocol'])) {
        throw HandshakeException('no common protocol version');
      }
      final th = (await _sha256.hash([...hello1, ...hello2])).bytes;
      final shared = await _x25519.sharedSecretKey(
          keyPair: eph,
          remotePublicKey: SimplePublicKey(unb64(h2['eph']! as String), type: KeyPairType.x25519));
      final keys = await _derive(shared, th);

      final authFrame = await raw.receive();
      final peerAuth = jsonDecode(utf8.decode(
          await SecureChannel._open(keys.hsR2I, _labelHsR2I, 0, authFrame))) as Map;
      final peer = await _verifyAuth(peerAuth.cast(), 'R', th);
      if (peer.ed25519Pub != expectedPeerKey) {
        throw HandshakeException('peer key does not match the expected device');
      }

      final body = _authBody(me);
      body['sig'] = b64(await me.sign([...utf8.encode('I'), ...th]));
      if (inviteSecret != null) {
        body['invite_proof'] = b64((await _hmac.calculateMac(th, secretKey: SecretKey(inviteSecret))).bytes);
      }
      await raw.send(await SecureChannel._seal(keys.hsI2R, _labelHsI2R, 0, utf8.encode(jsonEncode(body))));

      final channel = SecureChannel._(raw, keys.appI2R, keys.appR2I, _labelI2R, _labelR2I);
      final verdict = await channel.receiveJson();
      if (verdict['t'] != 'ready') {
        throw HandshakeException('peer refused: ${verdict['message'] ?? verdict['t']}');
      }
      return HandshakeResult(channel, peer, keys.sas, th, mode: mode);
    } on HandshakeException {
      await raw.close();
      rethrow;
    } on TransportException catch (e) {
      await raw.close();
      throw HandshakeException(e.message);
    } catch (e) {
      await raw.close();
      throw HandshakeException('malformed handshake ($e)');
    }
  }

  /// Runs the listening side.
  ///
  /// [inviteSecretFor] resolves a pairing invitation id to its secret (or
  /// null if unknown/expired). [isKnownPeer] checks a sync-mode peer
  /// against `sync_devices`.
  static Future<HandshakeResult> respond({
    required FrameChannel raw,
    required LocalIdentity me,
    required Future<List<int>?> Function(String inviteId) inviteSecretFor,
    required Future<bool> Function(PeerIdentity peer) isKnownPeer,
    required Set<HandshakeMode> allowedModes,
  }) async {
    Future<Never> refuse(String why) async {
      try {
        await raw.send(Uint8List.fromList(utf8.encode(jsonEncode({'t': 'error', 'message': why}))));
      } catch (_) {}
      await raw.close();
      throw HandshakeException(why);
    }

    try {
      final hello1 = await raw.receive();
      final h1 = jsonDecode(utf8.decode(hello1));
      if (h1 is! Map || h1['t'] != 'hello') return await refuse('bad hello');
      final protocols = (h1['protocols'] as List?)?.whereType<int>().toSet() ?? {};
      final common = kSupportedProtocols.where(protocols.contains).toList();
      if (common.isEmpty) return await refuse('no common protocol version');
      final mode = HandshakeMode.values.where((m) => m.name == h1['mode']).firstOrNull;
      if (mode == null || !allowedModes.contains(mode)) return await refuse('mode not allowed');
      List<int>? inviteSecret;
      if (mode == HandshakeMode.pair) {
        final id = h1['invite_id'];
        if (id is! String) return await refuse('missing invitation');
        inviteSecret = await inviteSecretFor(id);
        if (inviteSecret == null) return await refuse('invitation expired or unknown');
      }

      final eph = await _x25519.newKeyPair();
      final ephPub = await eph.extractPublicKey();
      final hello2 = canonicalBytes({
        't': 'hello',
        'protocol': common.reduce(max),
        'eph': b64(ephPub.bytes),
        'nonce': b64(randomBytes(16)),
      });
      await raw.send(Uint8List.fromList(hello2));
      final th = (await _sha256.hash([...hello1, ...hello2])).bytes;
      final shared = await _x25519.sharedSecretKey(
          keyPair: eph,
          remotePublicKey: SimplePublicKey(unb64(h1['eph']! as String), type: KeyPairType.x25519));
      final keys = await _derive(shared, th);

      final body = _authBody(me);
      body['sig'] = b64(await me.sign([...utf8.encode('R'), ...th]));
      await raw.send(await SecureChannel._seal(keys.hsR2I, _labelHsR2I, 0, utf8.encode(jsonEncode(body))));

      final authFrame = await raw.receive();
      final peerAuth = (jsonDecode(utf8.decode(
              await SecureChannel._open(keys.hsI2R, _labelHsI2R, 0, authFrame))) as Map)
          .cast<String, Object?>();
      final peer = await _verifyAuth(peerAuth, 'I', th);

      final channel = SecureChannel._(raw, keys.appR2I, keys.appI2R, _labelR2I, _labelI2R);
      String? problem;
      if (mode == HandshakeMode.pair) {
        final proof = peerAuth['invite_proof'];
        final expected = (await _hmac.calculateMac(th, secretKey: SecretKey(inviteSecret!))).bytes;
        if (proof is! String || !_constantTimeEquals(unb64(proof), expected)) {
          problem = 'invitation proof is invalid';
        }
      } else if (!await isKnownPeer(peer)) {
        problem = 'device is not paired';
      }
      if (problem != null) {
        await channel.sendJson({'t': 'error', 'message': problem});
        await raw.close();
        throw HandshakeException(problem);
      }
      await channel.sendJson({'t': 'ready'});
      return HandshakeResult(channel, peer, keys.sas, th,
          mode: mode, inviteId: mode == HandshakeMode.pair ? h1['invite_id'] as String : null);
    } on HandshakeException {
      await raw.close();
      rethrow;
    } on TransportException catch (e) {
      await raw.close();
      throw HandshakeException(e.message);
    } catch (e) {
      await raw.close();
      throw HandshakeException('malformed handshake ($e)');
    }
  }
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
