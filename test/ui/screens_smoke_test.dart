import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitmate/app/providers.dart';
import 'package:splitmate/domain/models.dart';
import 'package:splitmate/domain/split_calculator.dart';
import 'package:splitmate/ui/screens/activity_screen.dart';
import 'package:splitmate/ui/screens/balances_screen.dart';
import 'package:splitmate/ui/screens/conflicts_screen.dart';
import 'package:splitmate/ui/screens/dashboard_screen.dart';
import 'package:splitmate/ui/screens/expense_form_screen.dart';
import 'package:splitmate/ui/screens/friends_screen.dart';
import 'package:splitmate/ui/screens/group_detail_screen.dart';
import 'package:splitmate/ui/screens/groups_screen.dart';
import 'package:splitmate/ui/screens/settle_screen.dart';
import 'package:splitmate/ui/theme.dart';

import '../support/harness.dart';

/// Renders the main screens against a real (FFI) SQLite ledger, offline,
/// to catch layout and wiring errors. syncSummaryProvider is stubbed
/// because it is the only one needing the full AppServices.
void main() {
  late TestDevice alice;
  late String g;

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        repoProvider.overrideWithValue(alice.repo),
        syncSummaryProvider.overrideWith((ref) async => (unsynced: 2, pending: 0, devices: 1, lastSync: null)),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: screen),
    ));
    // Let real async SQLite queries finish, then settle frames.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
  }

  setUpAll(() async {
    alice = await TestDevice.create('alice');
    final bob = await TestDevice.create('bob');
    g = await alice.repo.createGroup('Goa trip', 'INR');
    await alice.addMember(g, bob);
    final dan = await alice.repo.addPlaceholderMember(g, 'Dan');
    await alice.repo.addExpense(ExpenseDraft(
      groupId: g,
      description: 'Beach shack dinner',
      amountMinor: 120000,
      currency: 'INR',
      payerId: alice.userId,
      splitType: SplitType.equal,
      participants: [SplitInput(alice.userId), SplitInput(bob.userId), SplitInput(dan)],
      expenseDate: DateTime(2026, 10, 1).millisecondsSinceEpoch,
      category: 'food',
    ));
    await alice.repo.addFriend('Priya', 'INR');
    await bob.dispose();
  });

  tearDownAll(() => alice.dispose());

  testWidgets('dashboard shows totals, groups and recent expenses', (tester) async {
    await pumpScreen(tester, const DashboardScreen());
    expect(find.text('Net balance'), findsOneWidget);
    expect(find.text('Goa trip'), findsWidgets);
    expect(find.text('Beach shack dinner'), findsOneWidget);
    expect(find.textContaining('₹800.00'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('groups, group detail and balances render', (tester) async {
    await pumpScreen(tester, const GroupsScreen());
    expect(find.text('Goa trip'), findsOneWidget);
    await pumpScreen(tester, GroupDetailScreen(groupId: g));
    expect(find.text('Beach shack dinner'), findsOneWidget);
    expect(find.text('Settle up'), findsOneWidget);
    await pumpScreen(tester, BalancesScreen(groupId: g));
    expect(find.text('Suggested payments'.toUpperCase()), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expense form validates splits live', (tester) async {
    await pumpScreen(tester, ExpenseFormScreen(groupId: g));
    expect(find.text('Add expense'), findsWidgets);
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '90');
    await tester.pump();
    expect(find.text('₹30.00'), findsNWidgets(3));
    await tester.tap(find.text('Exact'));
    await tester.pump();
    expect(find.textContaining('add up to'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settle, friends, activity and conflicts render', (tester) async {
    await pumpScreen(tester, SettleScreen(groupId: g));
    expect(find.textContaining('never moves money'), findsOneWidget);
    await pumpScreen(tester, const FriendsScreen());
    expect(find.text('Priya'), findsOneWidget);
    await pumpScreen(tester, const ActivityScreen());
    expect(find.textContaining('Beach shack dinner'), findsOneWidget);
    await pumpScreen(tester, const ConflictsScreen());
    expect(find.text('No conflicts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
