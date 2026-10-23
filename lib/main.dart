import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'app/services.dart';
import 'identity/identity.dart';
import 'ui/router.dart';
import 'ui/screens/backup_screen.dart' show maybeAutoBackup;
import 'ui/screens/onboarding_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = IdentityStore(PlatformSecretStore());
  final identity = await store.load();
  final services = identity == null ? null : await AppServices.open(identity, store);
  runApp(SplitMateRoot(store: store, initial: services));
}

/// Switches between onboarding and the app. No network is touched here:
/// the dashboard opens fully offline.
class SplitMateRoot extends StatefulWidget {
  const SplitMateRoot({super.key, required this.store, this.initial});
  final IdentityStore store;
  final AppServices? initial;

  @override
  State<SplitMateRoot> createState() => _SplitMateRootState();
}

class _SplitMateRootState extends State<SplitMateRoot> {
  AppServices? _services;

  @override
  void initState() {
    super.initState();
    _services = widget.initial;
  }

  Future<void> _createIdentity(String name) async {
    final identity = await LocalIdentity.generate(name);
    await widget.store.save(identity);
    final services = await AppServices.open(identity, widget.store);
    setState(() => _services = services);
  }

  Future<void> _reset() async {
    await _services?.deleteAllData();
    setState(() => _services = null);
  }

  @override
  Widget build(BuildContext context) {
    final services = _services;
    if (services == null) {
      return MaterialApp(
        title: 'SplitMate',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: OnboardingScreen(
          onCreate: _createIdentity,
          store: widget.store,
          onRestored: (s) => setState(() => _services = s),
        ),
      );
    }
    return ProviderScope(
      key: ValueKey(services),
      overrides: [
        servicesProvider.overrideWithValue(services),
        resetAppProvider.overrideWithValue(_reset),
      ],
      child: const SplitMateApp(),
    );
  }
}

final resetAppProvider = Provider<Future<void> Function()>((ref) => throw UnimplementedError());

class SplitMateApp extends ConsumerStatefulWidget {
  const SplitMateApp({super.key});

  @override
  ConsumerState<SplitMateApp> createState() => _SplitMateAppState();
}

class _SplitMateAppState extends ConsumerState<SplitMateApp> {
  late final router = buildRouter();

  @override
  void initState() {
    super.initState();
    // Opt-in only; a no-op unless the user enabled automatic Drive backups.
    maybeAutoBackup(ref.read(servicesProvider));
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'SplitMate',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        routerConfig: router,
      );
}
