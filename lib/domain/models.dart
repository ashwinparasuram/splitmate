import '../domain/split_calculator.dart';

class Person {
  const Person({
    required this.id,
    required this.name,
    this.isLocal = false,
    this.hasKeys = false,
    this.avatarPath,
  });
  final String id;
  final String name;
  final bool isLocal;

  /// True once this person's device has been paired, directly or via an admin.
  final bool hasKeys;
  final String? avatarPath;

  static Person fromRow(Map<String, Object?> r) => Person(
        id: r['id']! as String,
        name: r['display_name']! as String,
        isLocal: r['is_local'] == 1,
        hasKeys: r['ed25519_pub'] != null,
        avatarPath: r['avatar_path'] as String?,
      );
}

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.type,
    required this.defaultCurrency,
    required this.createdBy,
    required this.archived,
    required this.localStatus,
    required this.updatedAt,
  });
  final String id;
  final String name;
  final String type;
  final String defaultCurrency;
  final String createdBy;
  final bool archived;
  final String localStatus;
  final int updatedAt;

  bool get isDirect => type == 'direct';

  static Group fromRow(Map<String, Object?> r) => Group(
        id: r['id']! as String,
        name: r['name']! as String,
        type: r['type']! as String,
        defaultCurrency: r['default_currency']! as String,
        createdBy: r['created_by']! as String,
        archived: r['archived'] == 1,
        localStatus: r['local_status']! as String,
        updatedAt: r['updated_at']! as int,
      );
}

class Member {
  const Member({required this.person, required this.role, required this.status});
  final Person person;
  final String role;
  final String status;
  bool get isAdmin => role == 'admin' && isActive;
  bool get isActive => status == 'active';
}

class Expense {
  const Expense({
    required this.id,
    required this.groupId,
    required this.description,
    required this.amountMinor,
    required this.currency,
    required this.payerId,
    required this.splitType,
    required this.expenseDate,
    required this.category,
    required this.notes,
    required this.receiptPath,
    required this.createdBy,
    required this.conflicted,
    required this.createdAt,
    required this.updatedAt,
    required this.deleted,
    this.participants = const [],
    this.splits = const {},
  });

  final String id;
  final String groupId;
  final String description;
  final int amountMinor;
  final String currency;
  final String payerId;
  final SplitType splitType;
  final int expenseDate;
  final String category;
  final String? notes;
  final String? receiptPath;
  final String createdBy;
  final bool conflicted;
  final int createdAt;
  final int updatedAt;
  final bool deleted;
  final List<SplitInput> participants;
  final Map<String, int> splits;

  static Expense fromRow(Map<String, Object?> r,
          {List<SplitInput> participants = const [], Map<String, int> splits = const {}}) =>
      Expense(
        id: r['id']! as String,
        groupId: r['group_id']! as String,
        description: r['description']! as String,
        amountMinor: r['amount_minor']! as int,
        currency: r['currency']! as String,
        payerId: r['payer_id']! as String,
        splitType: splitTypeFromName(r['split_type']! as String),
        expenseDate: r['expense_date']! as int,
        category: r['category']! as String,
        notes: r['notes'] as String?,
        receiptPath: r['receipt_path'] as String?,
        createdBy: r['created_by']! as String,
        conflicted: r['conflicted'] == 1,
        createdAt: r['created_at']! as int,
        updatedAt: r['updated_at']! as int,
        deleted: r['deleted_at'] != null,
        participants: participants,
        splits: splits,
      );
}

class Settlement {
  const Settlement({
    required this.id,
    required this.groupId,
    required this.fromUserId,
    required this.toUserId,
    required this.amountMinor,
    required this.currency,
    required this.settledAt,
    required this.method,
    required this.note,
    required this.createdBy,
    required this.voided,
    required this.voidReason,
  });
  final String id;
  final String groupId;
  final String fromUserId;
  final String toUserId;
  final int amountMinor;
  final String currency;
  final int settledAt;
  final String method;
  final String? note;
  final String createdBy;
  final bool voided;
  final String? voidReason;

  static Settlement fromRow(Map<String, Object?> r) => Settlement(
        id: r['id']! as String,
        groupId: r['group_id']! as String,
        fromUserId: r['from_user_id']! as String,
        toUserId: r['to_user_id']! as String,
        amountMinor: r['amount_minor']! as int,
        currency: r['currency']! as String,
        settledAt: r['settled_at']! as int,
        method: r['method']! as String,
        note: r['note'] as String?,
        createdBy: r['created_by']! as String,
        voided: r['voided_at'] != null,
        voidReason: r['void_reason'] as String?,
      );
}

class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.groupId,
    required this.entityType,
    required this.entityId,
    required this.action,
    required this.summary,
    required this.isRemote,
    required this.createdAt,
  });
  final String id;
  final String? groupId;
  final String entityType;
  final String entityId;
  final String action;
  final String summary;
  final bool isRemote;
  final int createdAt;

  static ActivityEntry fromRow(Map<String, Object?> r) => ActivityEntry(
        id: r['id']! as String,
        groupId: r['group_id'] as String?,
        entityType: r['entity_type']! as String,
        entityId: r['entity_id']! as String,
        action: r['action']! as String,
        summary: r['summary']! as String,
        isRemote: r['is_remote'] == 1,
        createdAt: r['created_at']! as int,
      );
}

class ConflictInfo {
  const ConflictInfo({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.groupId,
    required this.kind,
    required this.headIds,
    required this.detectedAt,
  });
  final String id;
  final String entityType;
  final String entityId;
  final String groupId;
  final String kind;
  final List<String> headIds;
  final int detectedAt;
}

/// What the user entered on the expense form.
class ExpenseDraft {
  const ExpenseDraft({
    required this.groupId,
    required this.description,
    required this.amountMinor,
    required this.currency,
    required this.payerId,
    required this.splitType,
    required this.participants,
    required this.expenseDate,
    this.category = 'general',
    this.notes,
  });
  final String groupId;
  final String description;
  final int amountMinor;
  final String currency;
  final String payerId;
  final SplitType splitType;
  final List<SplitInput> participants;
  final int expenseDate;
  final String category;
  final String? notes;

  Map<String, Object?> toData({bool deleted = false}) {
    final sorted = [...participants]..sort((a, b) => a.userId.compareTo(b.userId));
    return {
      'description': description.trim(),
      'amount_minor': amountMinor,
      'currency': currency,
      'payer_id': payerId,
      'split_type': splitType.name,
      'participants': [for (final p in sorted) p.toJson()],
      'expense_date': expenseDate,
      'category': category,
      if (notes != null && notes!.trim().isNotEmpty) 'notes': notes!.trim(),
      'deleted': deleted,
    };
  }
}

const expenseCategories = <String, String>{
  'general': 'General',
  'food': 'Food & drink',
  'groceries': 'Groceries',
  'transport': 'Transport',
  'travel': 'Travel',
  'lodging': 'Lodging',
  'rent': 'Rent',
  'utilities': 'Utilities',
  'entertainment': 'Entertainment',
  'shopping': 'Shopping',
  'health': 'Health',
  'other': 'Other',
};
