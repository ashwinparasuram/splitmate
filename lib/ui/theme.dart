import 'package:flutter/material.dart';

const _seed = Color(0xFF14866D);

/// Semantic colours for money direction, tuned per brightness.
@immutable
class MoneyColors extends ThemeExtension<MoneyColors> {
  const MoneyColors({required this.owed, required this.owe, required this.settled});
  final Color owed;
  final Color owe;
  final Color settled;

  @override
  MoneyColors copyWith({Color? owed, Color? owe, Color? settled}) =>
      MoneyColors(owed: owed ?? this.owed, owe: owe ?? this.owe, settled: settled ?? this.settled);

  @override
  MoneyColors lerp(MoneyColors? other, double t) => other == null
      ? this
      : MoneyColors(
          owed: Color.lerp(owed, other.owed, t)!,
          owe: Color.lerp(owe, other.owe, t)!,
          settled: Color.lerp(settled, other.settled, t)!,
        );
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final dark = brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? scheme.surface : const Color(0xFFF6F8F7),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
          fontSize: 22, fontWeight: FontWeight.w700, color: scheme.onSurface, letterSpacing: -0.3),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: dark ? scheme.surfaceContainer : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.4 : 0.6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? scheme.surfaceContainerHigh : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? scheme.surfaceContainer : Colors.white,
      indicatorColor: scheme.primaryContainer,
    ),
    extensions: [
      MoneyColors(
        owed: dark ? const Color(0xFF5DD3A8) : const Color(0xFF0E7C5A),
        owe: dark ? const Color(0xFFFF8A70) : const Color(0xFFC2410C),
        settled: scheme.onSurfaceVariant,
      ),
    ],
  );
}

extension MoneyColorsX on BuildContext {
  MoneyColors get money => Theme.of(this).extension<MoneyColors>()!;
}
