import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'screens/account_screen.dart';
import 'screens/activity_screen.dart';
import 'screens/backup_screen.dart';
import 'screens/balances_screen.dart';
import 'screens/conflicts_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/expense_detail_screen.dart';
import 'screens/expense_form_screen.dart';
import 'screens/friends_screen.dart';
import 'screens/group_detail_screen.dart';
import 'screens/groups_screen.dart';
import 'screens/pair_screen.dart';
import 'screens/privacy_screen.dart';
import 'screens/settle_screen.dart';
import 'screens/sync_screen.dart';

GoRouter buildRouter() => GoRouter(
      initialLocation: '/home',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => _HomeShell(shell: shell),
          branches: [
            StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const DashboardScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/groups', builder: (_, _) => const GroupsScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/friends', builder: (_, _) => const FriendsScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/activity', builder: (_, _) => const ActivityScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: '/account', builder: (_, _) => const AccountScreen())]),
          ],
        ),
        GoRoute(path: '/group/:id', builder: (_, s) => GroupDetailScreen(groupId: s.pathParameters['id']!)),
        GoRoute(
            path: '/group/:id/balances',
            builder: (_, s) => BalancesScreen(groupId: s.pathParameters['id']!)),
        GoRoute(
            path: '/settle',
            builder: (_, s) => SettleScreen(
                  groupId: s.uri.queryParameters['group'],
                  fromUserId: s.uri.queryParameters['from'],
                  toUserId: s.uri.queryParameters['to'],
                  amountMinor: int.tryParse(s.uri.queryParameters['amount'] ?? ''),
                  currency: s.uri.queryParameters['currency'],
                )),
        GoRoute(
            path: '/expense/new',
            builder: (_, s) => ExpenseFormScreen(groupId: s.uri.queryParameters['group'])),
        GoRoute(path: '/expense/:id', builder: (_, s) => ExpenseDetailScreen(expenseId: s.pathParameters['id']!)),
        GoRoute(
            path: '/expense/:id/edit',
            builder: (_, s) => ExpenseFormScreen(expenseId: s.pathParameters['id']!)),
        GoRoute(path: '/sync', builder: (_, _) => const SyncScreen()),
        GoRoute(
            path: '/pair',
            builder: (_, s) => PairScreen(
                  groupId: s.uri.queryParameters['group'],
                  placeholderUserId: s.uri.queryParameters['placeholder'],
                  scan: s.uri.queryParameters['scan'] == '1',
                )),
        GoRoute(path: '/backup', builder: (_, _) => const BackupScreen()),
        GoRoute(path: '/privacy', builder: (_, _) => const PrivacyScreen()),
        GoRoute(path: '/conflicts', builder: (_, _) => const ConflictsScreen()),
      ],
    );

class _HomeShell extends StatelessWidget {
  const _HomeShell({required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: shell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.space_dashboard_outlined), selectedIcon: Icon(Icons.space_dashboard), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Groups'),
            NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Friends'),
            NavigationDestination(icon: Icon(Icons.history), label: 'Activity'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Account'),
          ],
        ),
      );
}
