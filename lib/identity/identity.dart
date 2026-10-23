import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

/// Abstraction over platform secure storage so tests can run on the host.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class InMemorySecretStore implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

final _ed25519 = Ed25519();
final _x25519 = X25519();

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64(String s) {
  final pad = (4 - s.length % 4) % 4;
  return Uint8List.fromList(base64Url.decode(s + '=' * pad));
}

/// The local user's identity and key material.
class LocalIdentity {
  LocalIdentity._({
    required this.userId,
    required this.deviceId,
    required this.displayName,
    required SimpleKeyPair signing,
    required SimpleKeyPair agreement,
    required this.ed25519Pub,
    required this.x25519Pub,
  })  : _signing = signing,
        _agreement = agreement;

  final String userId;
  final String deviceId;
  final String displayName;
  final SimpleKeyPair _signing;
  final SimpleKeyPair _agreement;

  /// Base64url (unpadded) public keys.
  final String ed25519Pub;
  final String x25519Pub;

  SimpleKeyPair get agreementKeyPair => _agreement;

  static Future<LocalIdentity> generate(String displayName,
      {String? userId, String? deviceId}) async {
    final signing = await _ed25519.newKeyPair();
    final agreement = await _x25519.newKeyPair();
    return _from(
      userId: userId ?? const Uuid().v4(),
      deviceId: deviceId ?? const Uuid().v4(),
      displayName: displayName,
      signing: signing,
      agreement: agreement,
    );
  }

  static Future<LocalIdentity> fromSeeds({
    required String userId,
    required String deviceId,
    required String displayName,
    required List<int> signingSeed,
    required List<int> agreementSeed,
  }) async {
    return _from(
      userId: userId,
      deviceId: deviceId,
      displayName: displayName,
      signing: await _ed25519.newKeyPairFromSeed(signingSeed),
      agreement: await _x25519.newKeyPairFromSeed(agreementSeed),
    );
  }

  static Future<LocalIdentity> _from({
    required String userId,
    required String deviceId,
    required String displayName,
    required SimpleKeyPair signing,
    required SimpleKeyPair agreement,
  }) async {
    final edPub = await signing.extractPublicKey();
    final xPub = await agreement.extractPublicKey();
    return LocalIdentity._(
      userId: userId,
      deviceId: deviceId,
      displayName: displayName,
      signing: signing,
      agreement: agreement,
      ed25519Pub: b64(edPub.bytes),
      x25519Pub: b64(xPub.bytes),
    );
  }

  LocalIdentity withDisplayName(String name) => LocalIdentity._(
        userId: userId,
        deviceId: deviceId,
        displayName: name,
        signing: _signing,
        agreement: _agreement,
        ed25519Pub: ed25519Pub,
        x25519Pub: x25519Pub,
      );

  Future<List<int>> sign(List<int> message) async =>
      (await _ed25519.sign(message, keyPair: _signing)).bytes;

  Future<({List<int> signing, List<int> agreement})> exportSeeds() async => (
        signing: await _signing.extractPrivateKeyBytes(),
        agreement: await _agreement.extractPrivateKeyBytes(),
      );
}

Future<bool> verifyEd25519(
    List<int> message, List<int> signature, String publicKeyB64) async {
  try {
    final pub = SimplePublicKey(unb64(publicKeyB64), type: KeyPairType.ed25519);
    return await _ed25519.verify(message,
        signature: Signature(signature, publicKey: pub));
  } catch (_) {
    return false;
  }
}

/// Persists the identity's private keys in [SecretStore]; never in SQLite.
class IdentityStore {
  IdentityStore(this._store);
  final SecretStore _store;

  static const _kUser = 'identity.user_id';
  static const _kDevice = 'identity.device_id';
  static const _kName = 'identity.display_name';
  static const _kSign = 'identity.ed25519_seed';
  static const _kAgree = 'identity.x25519_seed';

  Future<LocalIdentity?> load() async {
    final user = await _store.read(_kUser);
    final device = await _store.read(_kDevice);
    final sign = await _store.read(_kSign);
    final agree = await _store.read(_kAgree);
    if (user == null || device == null || sign == null || agree == null) return null;
    return LocalIdentity.fromSeeds(
      userId: user,
      deviceId: device,
      displayName: await _store.read(_kName) ?? 'Me',
      signingSeed: unb64(sign),
      agreementSeed: unb64(agree),
    );
  }

  Future<void> save(LocalIdentity id) async {
    final seeds = await id.exportSeeds();
    await _store.write(_kSign, b64(seeds.signing));
    await _store.write(_kAgree, b64(seeds.agreement));
    await _store.write(_kName, id.displayName);
    await _store.write(_kDevice, id.deviceId);
    // Written last: its presence marks a complete identity.
    await _store.write(_kUser, id.userId);
  }

  Future<void> clear() async {
    for (final k in [_kUser, _kDevice, _kName, _kSign, _kAgree]) {
      await _store.delete(k);
    }
  }
}
