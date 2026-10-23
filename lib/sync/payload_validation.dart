import '../core/money.dart';
import '../domain/split_calculator.dart';
import 'change.dart';

/// Content-level validation of a change payload. A failure here depends only
/// on the change itself, so it is permanent ("invalid:").
String? validatePayload(EntityType type, Map<String, Object?> d) {
  String? str(String k, {int min = 0, int max = 200, bool optional = false}) {
    final v = d[k];
    if (v == null && optional) return null;
    if (v is! String) return '$k must be text';
    if (v.length < min || v.length > max) return '$k has invalid length';
    return null;
  }

  String? boolean(String k) => d[k] is bool ? null : '$k must be true/false';

  String? currency(String k) {
    final v = d[k];
    return v is String && Currency.isSupported(v) ? null : 'unsupported currency';
  }

  String? positiveMoney(String k) {
    final v = d[k];
    return v is int && v > 0 && v < 1000000000000000 ? null : '$k must be positive';
  }

  switch (type) {
    case EntityType.group:
      final creator = d['creator'];
      if (creator is! Map || creator['user_id'] is! String || creator['ed25519_pub'] is! String) {
        return 'group.creator missing';
      }
      return str('name', min: 1, max: 80) ??
          (const ['group', 'direct'].contains(d['type']) ? null : 'bad group type') ??
          currency('default_currency') ??
          boolean('archived');
    case EntityType.member:
      return str('user_id', min: 36, max: 36) ??
          str('display_name', min: 1, max: 80) ??
          (const ['admin', 'member'].contains(d['role']) ? null : 'bad role') ??
          (const ['active', 'removed'].contains(d['status']) ? null : 'bad status') ??
          str('ed25519_pub', optional: true) ??
          str('x25519_pub', optional: true) ??
          str('merged_into', min: 36, max: 36, optional: true);
    case EntityType.expense:
      final err = str('description', min: 1, max: 120) ??
          positiveMoney('amount_minor') ??
          currency('currency') ??
          str('payer_id', min: 36, max: 36) ??
          str('category', min: 1, max: 40) ??
          str('notes', max: 1000, optional: true) ??
          (d['expense_date'] is int ? null : 'expense_date missing') ??
          boolean('deleted');
      if (err != null) return err;
      final type = SplitType.values.where((t) => t.name == d['split_type']).firstOrNull;
      if (type == null) return 'bad split_type';
      final raw = d['participants'];
      if (raw is! List || raw.isEmpty || raw.length > 100) return 'bad participants';
      final inputs = <SplitInput>[];
      for (final p in raw) {
        if (p is! Map || p['user_id'] is! String || p['value'] is! int) {
          return 'bad participant';
        }
        inputs.add(SplitInput(p['user_id'] as String, p['value'] as int));
      }
      try {
        SplitCalculator.allocate(
            total: d['amount_minor']! as int, type: type, inputs: inputs);
      } on SplitValidationException catch (e) {
        return e.message;
      }
      return null;
    case EntityType.settlement:
      final err = str('from', min: 36, max: 36) ??
          str('to', min: 36, max: 36) ??
          positiveMoney('amount_minor') ??
          currency('currency') ??
          (d['settled_at'] is int ? null : 'settled_at missing') ??
          str('method', min: 1, max: 30) ??
          str('note', max: 500, optional: true) ??
          boolean('voided') ??
          str('void_reason', max: 300, optional: true);
      if (err != null) return err;
      if (d['from'] == d['to']) return 'cannot settle with yourself';
      return null;
  }
}
