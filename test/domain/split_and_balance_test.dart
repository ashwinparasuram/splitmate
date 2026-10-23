import 'package:flutter_test/flutter_test.dart';
import 'package:splitmate/core/money.dart';
import 'package:splitmate/domain/balance_calculator.dart';
import 'package:splitmate/domain/split_calculator.dart';

void main() {
  const a = 'aaaaaaaa-0000-4000-8000-000000000001';
  const b = 'bbbbbbbb-0000-4000-8000-000000000002';
  const c = 'cccccccc-0000-4000-8000-000000000003';

  group('SplitCalculator', () {
    test('equal split of the documented example: ₹1,200 among three', () {
      final r = SplitCalculator.allocate(
          total: 120000, type: SplitType.equal, inputs: const [SplitInput(a), SplitInput(b), SplitInput(c)]);
      expect(r, {a: 40000, b: 40000, c: 40000});
    });

    test('equal split gives leftover units to lowest user ids, regardless of input order', () {
      final r1 = SplitCalculator.allocate(
          total: 1000, type: SplitType.equal, inputs: const [SplitInput(c), SplitInput(a), SplitInput(b)]);
      final r2 = SplitCalculator.allocate(
          total: 1000, type: SplitType.equal, inputs: const [SplitInput(b), SplitInput(c), SplitInput(a)]);
      expect(r1, {a: 334, b: 333, c: 333});
      expect(r2, r1);
    });

    test('exact split must add up', () {
      expect(
          SplitCalculator.allocate(
              total: 1000, type: SplitType.exact, inputs: const [SplitInput(a, 700), SplitInput(b, 300)]),
          {a: 700, b: 300});
      expect(
          () => SplitCalculator.allocate(
              total: 1000, type: SplitType.exact, inputs: const [SplitInput(a, 700), SplitInput(b, 200)]),
          throwsA(isA<SplitValidationException>()));
    });

    test('percentage split uses largest remainder and must total 100%', () {
      final r = SplitCalculator.allocate(
          total: 100,
          type: SplitType.percentage,
          inputs: const [SplitInput(a, 3333), SplitInput(b, 3333), SplitInput(c, 3334)]);
      expect(r.values.reduce((x, y) => x + y), 100);
      expect(r, {a: 33, b: 33, c: 34});
      expect(
          () => SplitCalculator.allocate(
              total: 100, type: SplitType.percentage, inputs: const [SplitInput(a, 5000), SplitInput(b, 4000)]),
          throwsA(isA<SplitValidationException>()));
    });

    test('shares split with uneven rounding', () {
      final r = SplitCalculator.allocate(
          total: 1001,
          type: SplitType.shares,
          inputs: const [SplitInput(a, 1), SplitInput(b, 1), SplitInput(c, 1)]);
      expect(r, {a: 334, b: 334, c: 333});
      final r2 = SplitCalculator.allocate(
          total: 1000, type: SplitType.shares, inputs: const [SplitInput(a, 2), SplitInput(b, 1)]);
      expect(r2, {a: 667, b: 333});
    });

    test('zero-weight share participant never gets a leftover unit', () {
      final r = SplitCalculator.allocate(
          total: 5, type: SplitType.shares, inputs: const [SplitInput(a, 0), SplitInput(b, 1), SplitInput(c, 1)]);
      expect(r[a], 0);
      expect(r[b]! + r[c]!, 5);
    });

    test('rejects invalid input', () {
      expect(() => SplitCalculator.allocate(total: 0, type: SplitType.equal, inputs: const [SplitInput(a)]),
          throwsA(isA<SplitValidationException>()));
      expect(() => SplitCalculator.allocate(total: 10, type: SplitType.equal, inputs: const []),
          throwsA(isA<SplitValidationException>()));
      expect(
          () => SplitCalculator.allocate(
              total: 10, type: SplitType.equal, inputs: const [SplitInput(a), SplitInput(a)]),
          throwsA(isA<SplitValidationException>()));
    });

    test('JPY has no minor units, KWD has three', () {
      expect(parseMinor('1200', Currency.of('JPY')), 1200);
      expect(() => parseMinor('12.5', Currency.of('JPY')), throwsA(isA<MoneyFormatException>()));
      expect(parseMinor('1.234', Currency.of('KWD')), 1234);
      expect(parseMinor('1,200.5', Currency.of('INR')), 120050);
      expect(() => parseMinor('1.234', Currency.of('INR')), throwsA(isA<MoneyFormatException>()));
      expect(formatMoney(120000, 'INR'), '₹1,200.00');
      expect(formatMoney(-5, 'KWD'), '-KD 0.005');
    });
  });

  group('Balances', () {
    LedgerExpense equal(String payer, int total, List<String> people, [String cur = 'INR']) =>
        LedgerExpense(
          payerId: payer,
          currency: cur,
          splits: SplitCalculator.allocate(
              total: total, type: SplitType.equal, inputs: [for (final p in people) SplitInput(p)]),
        );

    test('documented example: Alice paid ₹1,200 for three', () {
      final bal = Balances.compute([equal(a, 120000, [a, b, c])], const []);
      expect(bal.owes(b, a, 'INR'), 40000);
      expect(bal.owes(c, a, 'INR'), 40000);
      expect(bal.netFor(a), {'INR': 80000});
      expect(bal.totalsFor(a).owedToMe, {'INR': 80000});
      expect(bal.totalsFor(b).iOwe, {'INR': 40000});
    });

    test('multiple expenses net out pairwise', () {
      final bal = Balances.compute([equal(a, 120000, [a, b, c]), equal(b, 60000, [a, b])], const []);
      expect(bal.owes(b, a, 'INR'), 10000);
      expect(bal.owes(a, b, 'INR'), -10000);
      expect(bal.netFor(a)['INR'], 50000);
    });

    test('partial and full settlements', () {
      final e = [equal(a, 120000, [a, b, c])];
      final partial = Balances.compute(e, const [
        LedgerSettlement(fromUserId: b, toUserId: a, amountMinor: 15000, currency: 'INR'),
      ]);
      expect(partial.owes(b, a, 'INR'), 25000);
      final full = Balances.compute(e, const [
        LedgerSettlement(fromUserId: b, toUserId: a, amountMinor: 40000, currency: 'INR'),
        LedgerSettlement(fromUserId: c, toUserId: a, amountMinor: 40000, currency: 'INR'),
      ]);
      expect(full.nets(), isEmpty);
      expect(full.suggestedTransfers(), isEmpty);
    });

    test('currencies are never combined', () {
      final bal = Balances.compute([equal(a, 1000, [a, b]), equal(b, 300, [a, b], 'USD')], const []);
      expect(bal.netFor(a), {'INR': 500, 'USD': -150});
      expect(bal.currencies, {'INR', 'USD'});
    });

    test('suggested transfers clear every net balance', () {
      final bal = Balances.compute([
        equal(a, 90000, [a, b, c]),
        equal(b, 30000, [b, c]),
      ], const []);
      final transfers = bal.suggestedTransfers();
      final settled = Balances.compute([
        equal(a, 90000, [a, b, c]),
        equal(b, 30000, [b, c]),
      ], [
        for (final t in transfers)
          LedgerSettlement(
              fromUserId: t.fromUserId, toUserId: t.toUserId, amountMinor: t.amountMinor, currency: t.currency),
      ]);
      expect(settled.nets(), isEmpty);
      expect(transfers.length, lessThanOrEqualTo(2));
    });
  });
}
