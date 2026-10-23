import '../core/money.dart';

enum SplitType { equal, exact, percentage, shares }

SplitType splitTypeFromName(String name) =>
    SplitType.values.firstWhere((t) => t.name == name,
        orElse: () => throw ArgumentError.value(name, 'split_type'));

/// One participant's input to a split.
///
/// [value] means: ignored for equal; minor units for exact; basis points
/// (10000 = 100%) for percentage; a positive integer weight for shares.
class SplitInput {
  const SplitInput(this.userId, [this.value = 0]);
  final String userId;
  final int value;

  Map<String, Object?> toJson() => {'user_id': userId, 'value': value};

  static SplitInput fromJson(Map<String, Object?> j) =>
      SplitInput(j['user_id']! as String, (j['value'] as int?) ?? 0);

  @override
  bool operator ==(Object other) =>
      other is SplitInput && other.userId == userId && other.value == value;

  @override
  int get hashCode => Object.hash(userId, value);
}

class SplitValidationException implements Exception {
  SplitValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Deterministic split allocation. Every device must produce identical
/// results for identical inputs, so all tie-breaks use ascending user id.
class SplitCalculator {
  const SplitCalculator._();

  /// Returns owed minor units per user id. The values always sum to [total].
  static Map<String, int> allocate({
    required int total,
    required SplitType type,
    required List<SplitInput> inputs,
  }) {
    if (total <= 0) throw SplitValidationException('Amount must be greater than zero');
    if (inputs.isEmpty) throw SplitValidationException('Choose at least one participant');
    final ids = inputs.map((i) => i.userId).toSet();
    if (ids.length != inputs.length) {
      throw SplitValidationException('A participant is listed twice');
    }
    final sorted = [...inputs]..sort((a, b) => a.userId.compareTo(b.userId));
    for (final i in sorted) {
      if (i.value < 0) throw SplitValidationException('Split values cannot be negative');
    }

    final Map<String, int> result;
    switch (type) {
      case SplitType.equal:
        result = _equal(total, sorted);
      case SplitType.exact:
        final sum = sorted.fold<int>(0, (s, i) => s + i.value);
        if (sum != total) {
          throw SplitValidationException(
              'Exact amounts add up to $sum but the total is $total');
        }
        result = {for (final i in sorted) i.userId: i.value};
      case SplitType.percentage:
        final bp = sorted.fold<int>(0, (s, i) => s + i.value);
        if (bp != 10000) {
          throw SplitValidationException(
              'Percentages add up to ${formatBasisPoints(bp)}% instead of 100%');
        }
        result = _largestRemainder(total, sorted, 10000);
      case SplitType.shares:
        final weight = sorted.fold<int>(0, (s, i) => s + i.value);
        if (weight <= 0) throw SplitValidationException('Shares must add up to more than zero');
        result = _largestRemainder(total, sorted, weight);
    }
    assert(result.values.fold<int>(0, (a, b) => a + b) == total);
    return result;
  }

  static Map<String, int> _equal(int total, List<SplitInput> sorted) {
    final n = sorted.length;
    final base = total ~/ n;
    final remainder = total % n;
    return {
      for (var k = 0; k < n; k++) sorted[k].userId: base + (k < remainder ? 1 : 0),
    };
  }

  /// Hamilton / largest-remainder apportionment of [total] by integer weights.
  static Map<String, int> _largestRemainder(
      int total, List<SplitInput> sorted, int weightSum) {
    final floors = <String, int>{};
    final remainders = <(String, int)>[];
    var allocated = 0;
    for (final i in sorted) {
      final product = total * i.value;
      final f = product ~/ weightSum;
      floors[i.userId] = f;
      allocated += f;
      remainders.add((i.userId, product % weightSum));
    }
    var left = total - allocated;
    remainders.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    for (final r in remainders) {
      if (left == 0) break;
      // A zero-weight participant never receives leftover units.
      if (sorted.firstWhere((s) => s.userId == r.$1).value == 0) continue;
      floors[r.$1] = floors[r.$1]! + 1;
      left--;
    }
    return floors;
  }
}
