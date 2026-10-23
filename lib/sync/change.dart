import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../core/canonical_json.dart';
import '../core/hlc.dart';
import '../identity/identity.dart';

const int kChangeFormatVersion = 1;
const int kMaxPayloadBytes = 64 * 1024;

enum EntityType { group, member, expense, settlement }

/// A signed, content-addressed change record. See docs/DESIGN.md §6.
class SyncChange {
  SyncChange({
    required this.formatVersion,
    required this.type,
    required this.entityId,
    required this.groupId,
    required List<String> parents,
    required this.authorUserId,
    required this.originDeviceId,
    required this.originSeq,
    required this.hlc,
    required this.data,
    required this.changeId,
    required this.signature,
  }) : parents = (List.of(parents)..sort());

  final int formatVersion;
  final EntityType type;
  final String entityId;
  final String groupId;
  final List<String> parents;
  final String authorUserId;
  final String originDeviceId;
  final int originSeq;
  final String hlc;
  final Map<String, Object?> data;
  final String changeId;
  final String signature;

  static Map<String, Object?> unsignedBody({
    required int formatVersion,
    required EntityType type,
    required String entityId,
    required String groupId,
    required List<String> parents,
    required String authorUserId,
    required String originDeviceId,
    required int originSeq,
    required String hlc,
    required Map<String, Object?> data,
  }) =>
      {
        'v': formatVersion,
        'type': type.name,
        'entity': entityId,
        'group': groupId,
        'parents': List.of(parents)..sort(),
        'author': authorUserId,
        'device': originDeviceId,
        'seq': originSeq,
        'hlc': hlc,
        'data': data,
      };

  Map<String, Object?> get body => unsignedBody(
        formatVersion: formatVersion,
        type: type,
        entityId: entityId,
        groupId: groupId,
        parents: parents,
        authorUserId: authorUserId,
        originDeviceId: originDeviceId,
        originSeq: originSeq,
        hlc: hlc,
        data: data,
      );

  static String computeId(Map<String, Object?> body) =>
      crypto.sha256.convert(canonicalBytes(body)).toString();

  static Future<SyncChange> create({
    required LocalIdentity author,
    required EntityType type,
    required String entityId,
    required String groupId,
    required List<String> parents,
    required int seq,
    required Hlc hlc,
    required Map<String, Object?> data,
  }) async {
    final body = unsignedBody(
      formatVersion: kChangeFormatVersion,
      type: type,
      entityId: entityId,
      groupId: groupId,
      parents: parents,
      authorUserId: author.userId,
      originDeviceId: author.deviceId,
      originSeq: seq,
      hlc: hlc.toString(),
      data: data,
    );
    final id = computeId(body);
    final sig = await author.sign(utf8.encode(id));
    return SyncChange(
      formatVersion: kChangeFormatVersion,
      type: type,
      entityId: entityId,
      groupId: groupId,
      parents: parents,
      authorUserId: author.userId,
      originDeviceId: author.deviceId,
      originSeq: seq,
      hlc: hlc.toString(),
      data: data,
      changeId: id,
      signature: b64(sig),
    );
  }

  /// Wire form: the body plus id and signature.
  Map<String, Object?> toWire() => {...body, 'id': changeId, 'sig': signature};

  /// Parses an untrusted wire map. Structural validation only; the hash,
  /// signature and authorisation are checked by the change log.
  static SyncChange fromWire(Object? raw) {
    if (raw is! Map) throw const FormatException('change must be an object');
    final m = raw.cast<String, Object?>();
    T req<T>(String k) {
      final v = m[k];
      if (v is! T) throw FormatException('change.$k has wrong type');
      return v;
    }

    final typeName = req<String>('type');
    final type = EntityType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) throw FormatException('unknown entity type $typeName');
    final parents = req<List>('parents');
    if (parents.length > 64 || parents.any((p) => p is! String)) {
      throw const FormatException('change.parents invalid');
    }
    final data = req<Map>('data').cast<String, Object?>();
    if (canonicalJson(data).length > kMaxPayloadBytes) {
      throw const FormatException('change payload too large');
    }
    final hlc = req<String>('hlc');
    if (!Hlc.isValid(hlc)) throw const FormatException('change.hlc invalid');
    final seq = req<int>('seq');
    if (seq < 1) throw const FormatException('change.seq invalid');
    for (final k in ['entity', 'group', 'author', 'device']) {
      if (!_uuid.hasMatch(req<String>(k))) throw FormatException('change.$k is not a UUID');
    }
    return SyncChange(
      formatVersion: req<int>('v'),
      type: type,
      entityId: req<String>('entity'),
      groupId: req<String>('group'),
      parents: parents.cast<String>(),
      authorUserId: req<String>('author'),
      originDeviceId: req<String>('device'),
      originSeq: seq,
      hlc: hlc,
      data: data,
      changeId: req<String>('id'),
      signature: req<String>('sig'),
    );
  }

  static final _uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// Row for `sync_changes` (without status columns).
  Map<String, Object?> toRow() => {
        'change_id': changeId,
        'format_version': formatVersion,
        'entity_type': type.name,
        'entity_id': entityId,
        'group_id': groupId,
        'parents': jsonEncode(parents),
        'author_user_id': authorUserId,
        'origin_device_id': originDeviceId,
        'origin_seq': originSeq,
        'hlc': hlc,
        'payload': canonicalJson(data),
        'signature': signature,
      };

  static SyncChange fromRow(Map<String, Object?> r) => SyncChange(
        formatVersion: r['format_version']! as int,
        type: EntityType.values.byName(r['entity_type']! as String),
        entityId: r['entity_id']! as String,
        groupId: r['group_id']! as String,
        parents: (jsonDecode(r['parents']! as String) as List).cast<String>(),
        authorUserId: r['author_user_id']! as String,
        originDeviceId: r['origin_device_id']! as String,
        originSeq: r['origin_seq']! as int,
        hlc: r['hlc']! as String,
        data: (jsonDecode(r['payload']! as String) as Map).cast<String, Object?>(),
        changeId: r['change_id']! as String,
        signature: r['signature']! as String,
      );
}
