/// Balances derived purely from accepted expenses and settlements.
///
/// Nothing here is ever synchronised: every device recomputes balances from
/// the materialised records, so cached totals can never disagree with them.
class LedgerExpense {
  const LedgerExpense({
    required this.payerId,
    required this.currency,
    required this.splits,
    this.groupId = '',
  });
  final String payerId;
  final String currency;
  final String groupId;

  /// Owed minor units per participant (including the payer's own share).
  final Map<String, int> splits;
}

class LedgerSettlement {
  const LedgerSettlement({
    required this.fromUserId,
    required this.toUserId,
    required this.amountMinor,
    required this.currency,
    this.groupId = '',
  });

  /// The person who paid money (the debtor).
  final String fromUserId;
  final String toUserId;
  final int amountMinor;
  final String currency;
  final String groupId;
}

class Transfer {
  const Transfer(this.fromUserId, this.toUserId, this.amountMinor, this.currency);
  final String fromUserId;
  final String toUserId;
  final int amountMinor;
  final String currency;

  @override
  bool operator ==(Object other) =>
      other is Transfer &&
      other.fromUserId == fromUserId &&
      other.toUserId == toUserId &&
      other.amountMinor == amountMinor &&
      other.currency == currency;

  @override
  int get hashCode => Object.hash(fromUserId, toUserId, amountMinor, currency);

  @override
  String toString() => '$fromUserId -> $toUserId $amountMinor $currency';
}

class Balances {
  Balances._(this._pair);

  /// _pair[currency][(a,b)] with a < b: positive means b owes a.
  final Map<String, Map<(String, String), int>> _pair;

  static Balances compute(
      Iterable<LedgerExpense> expenses, Iterable<LedgerSettlement> settlements) {
    final pair = <String, Map<(String, String), int>>{};
    void owe(String debtor, String creditor, int amount, String currency) {
      if (debtor == creditor || amount == 0) return;
      final m = pair.putIfAbsent(currency, () => {});
      if (debtor.compareTo(creditor) < 0) {
        final k = (debtor, creditor);
        m[k] = (m[k] ?? 0) - amount;
      } else {
        final k = (creditor, debtor);
        m[k] = (m[k] ?? 0) + amount;
      }
    }

    for (final e in expenses) {
      e.splits.forEach((user, share) => owe(user, e.payerId, share, e.currency));
    }
    for (final s in settlements) {
      // Paying someone reduces what you owe them, i.e. they now owe you.
      owe(s.toUserId, s.fromUserId, s.amountMinor, s.currency);
    }
    for (final m in pair.values) {
      m.removeWhere((_, v) => v == 0);
    }
    pair.removeWhere((_, m) => m.isEmpty);
    return Balances._(pair);
  }

  Set<String> get currencies => _pair.keys.toSet();

  /// Amount [debtor] owes [creditor] in [currency]; negative if reversed.
  int owes(String debtor, String creditor, String currency) {
    final m = _pair[currency];
    if (m == null || debtor == creditor) return 0;
    if (debtor.compareTo(creditor) < 0) return -(m[(debtor, creditor)] ?? 0);
    return m[(creditor, debtor)] ?? 0;
  }

  /// Net position of [user] per currency: positive = owed to them.
  Map<String, int> netFor(String user) {
    final out = <String, int>{};
    _pair.forEach((currency, m) {
      var net = 0;
      m.forEach((k, v) {
        if (k.$1 == user) net += v;
        if (k.$2 == user) net -= v;
      });
      if (net != 0) out[currency] = net;
    });
    return out;
  }

  /// Every user's net per currency.
  Map<String, Map<String, int>> nets() {
    final out = <String, Map<String, int>>{};
    _pair.forEach((currency, m) {
      m.forEach((k, v) {
        final a = out.putIfAbsent(k.$1, () => {});
        final b = out.putIfAbsent(k.$2, () => {});
        a[currency] = (a[currency] ?? 0) + v;
        b[currency] = (b[currency] ?? 0) - v;
      });
    });
    for (final m in out.values) {
      m.removeWhere((_, v) => v == 0);
    }
    out.removeWhere((_, m) => m.isEmpty);
    return out;
  }

  /// Per counterparty: positive means the counterparty owes [user].
  Map<String, Map<String, int>> counterpartiesOf(String user) {
    final out = <String, Map<String, int>>{};
    _pair.forEach((currency, m) {
      m.forEach((k, v) {
        if (k.$1 == user) {
          out.putIfAbsent(k.$2, () => {})[currency] = v;
        } else if (k.$2 == user) {
          out.putIfAbsent(k.$1, () => {})[currency] = -v;
        }
      });
    });
    return out;
  }

  /// Totals for [user]: (owed to user, owed by user) per currency.
  ({Map<String, int> owedToMe, Map<String, int> iOwe}) totalsFor(String user) {
    final owedToMe = <String, int>{};
    final iOwe = <String, int>{};
    counterpartiesOf(user).forEach((_, byCurrency) {
      byCurrency.forEach((currency, v) {
        if (v > 0) owedToMe[currency] = (owedToMe[currency] ?? 0) + v;
        if (v < 0) iOwe[currency] = (iOwe[currency] ?? 0) - v;
      });
    });
    return (owedToMe: owedToMe, iOwe: iOwe);
  }

  /// "Simplify debts": a small set of transfers that clears every net balance,
  /// computed per currency with deterministic tie-breaks.
  List<Transfer> suggestedTransfers() {
    final out = <Transfer>[];
    final byCurrency = <String, Map<String, int>>{};
    nets().forEach((user, m) => m.forEach(
        (currency, v) => byCurrency.putIfAbsent(currency, () => {})[user] = v));
    final currencies = byCurrency.keys.toList()..sort();
    for (final currency in currencies) {
      final net = Map.of(byCurrency[currency]!);
      while (true) {
        String? creditor, debtor;
        for (final u in (net.keys.toList()..sort())) {
          final v = net[u]!;
          if (v > 0 && (creditor == null || v > net[creditor]!)) creditor = u;
          if (v < 0 && (debtor == null || v < net[debtor]!)) debtor = u;
        }
        if (creditor == null || debtor == null) break;
        final amount = net[creditor]! < -net[debtor]! ? net[creditor]! : -net[debtor]!;
        out.add(Transfer(debtor, creditor, amount, currency));
        net[creditor] = net[creditor]! - amount;
        net[debtor] = net[debtor]! + amount;
      }
    }
    return out;
  }
}
