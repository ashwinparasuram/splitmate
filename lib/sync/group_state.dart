import 'package:uuid/uuid.dart';

/// Namespace for deterministic member entity ids, so two admins adding the
/// same person concurrently converge on a single member entity.
const _memberNamespace = '6f1c2a7e-3b9d-5c4e-8a0f-2d7b9e1c4a55';

String memberEntityId(String groupId, String userId) =>
    const Uuid().v5(_memberNamespace, '$groupId:$userId');

class MemberState {
  MemberState({
    required this.userId,
    required this.displayName,
    required this.role,
    required this.status,
    required this.joinedHlc,
    this.removedHlc,
    this.ed25519Pub,
    this.x25519Pub,
    this.mergedInto,
  });

  final String userId;
  final String displayName;
  final String role;
  final String status;
  final String joinedHlc;
  final String? removedHlc;
  final String? ed25519Pub;
  final String? x25519Pub;
  final String? mergedInto;

  bool get isActive => status == 'active';
  bool get isAdmin => isActive && role == 'admin';
}

/// Membership and keys of one group at some point in the HLC timeline.
class GroupState {
  GroupState(this.groupId);
  final String groupId;
  bool exists = false;
  String? creatorId;
  String? type;
  final Map<String, MemberState> members = {};

  MemberState? operator [](String userId) => members[userId];
}
