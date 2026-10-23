import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ledger_repository.dart';
import '../domain/balance_calculator.dart';
import '../domain/models.dart';
import 'services.dart';

/// Overridden in main() once the identity and database are open.
final servicesProvider = Provider<AppServices>((ref) => throw UnimplementedError());

final repoProvider = Provider<LedgerRepository>((ref) => ref.watch(servicesProvider).repo);

final meProvider = Provider<String>((ref) => ref.watch(repoProvider).me);

/// Ticks on every local or remote ledger change; data providers watch it.
final ledgerTickProvider = StreamProvider<int>((ref) async* {
  var n = 0;
  yield n;
  await for (final _ in ref.watch(repoProvider).changes) {
    yield ++n;
  }
});

Future<T> _q<T>(Ref ref, Future<T> Function(LedgerRepository r) f) {
  ref.watch(ledgerTickProvider);
  return f(ref.watch(repoProvider));
}

final peopleProvider = FutureProvider<Map<String, Person>>((ref) => _q(ref, (r) => r.people()));

final groupsProvider =
    FutureProvider<List<Group>>((ref) => _q(ref, (r) => r.groups(includeArchived: true)));

/// Groups and direct (friend) groups an expense can be added to.
final selectableGroupsProvider = FutureProvider<List<Group>>(
    (ref) => _q(ref, (r) => r.groups(includeArchived: false, includeDirect: true)));

final groupProvider = FutureProvider.family<Group?, String>((ref, id) => _q(ref, (r) => r.group(id)));

final membersProvider =
    FutureProvider.family<List<Member>, String>((ref, id) => _q(ref, (r) => r.members(id)));

final groupExpensesProvider = FutureProvider.family<List<Expense>, String>(
    (ref, id) => _q(ref, (r) => r.expenses(groupId: id)));

final recentExpensesProvider =
    FutureProvider<List<Expense>>((ref) => _q(ref, (r) => r.expenses(limit: 8)));

final expenseProvider =
    FutureProvider.family<Expense?, String>((ref, id) => _q(ref, (r) => r.expense(id)));

final groupSettlementsProvider = FutureProvider.family<List<Settlement>, String>(
    (ref, id) => _q(ref, (r) => r.settlements(groupId: id)));

/// null = across all groups.
final balancesProvider =
    FutureProvider.family<Balances, String?>((ref, id) => _q(ref, (r) => r.balances(groupId: id)));

final friendsProvider = FutureProvider<List<Person>>((ref) => _q(ref, (r) => r.friends()));

final activityProvider = FutureProvider.family<List<ActivityEntry>, String?>(
    (ref, id) => _q(ref, (r) => r.activity(groupId: id)));

final conflictsProvider = FutureProvider.family<List<ConflictInfo>, String?>(
    (ref, id) => _q(ref, (r) => r.openConflicts(groupId: id)));

final syncSummaryProvider = FutureProvider<({int unsynced, int pending, int devices, int? lastSync})>(
    (ref) => _q(ref, (r) async {
          final devices = await r.db.query('sync_devices', where: "status = 'paired'");
          final last = devices
              .map((d) => d['last_sync_at'] as int?)
              .whereType<int>()
              .fold<int?>(null, (a, b) => a == null || b > a ? b : a);
          return (
            unsynced: await r.unsyncedLocalChanges(),
            pending: await r.pendingRemoteChanges(),
            devices: devices.length,
            lastSync: last,
          );
        }));

final pairedDevicesProvider = FutureProvider<List<Map<String, Object?>>>(
    (ref) => _q(ref, (r) => r.db.query('sync_devices', orderBy: 'paired_at DESC')));
