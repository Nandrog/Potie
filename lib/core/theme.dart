import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Brand {
  static const ink = Color(0xFF16181D);
  static const paper = Color(0xFFF6F4EF);
  static const amber = Color(0xFFF2A63B);
  static const teal = Color(0xFF2FB5A8);
  static const danger = Color(0xFFE5484D);

  // Accent colours used as *text* need a darker shade on light backgrounds.
  static Color amberText(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? amber : const Color(0xFFB26A00);
  static Color tealText(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? teal : const Color(0xFF157F75);

  static ThemeData theme(Brightness b) {
    final dark = b == Brightness.dark;
    final bg = dark ? ink : paper;
    final card = dark ? const Color(0xFF23272F) : Colors.white;
    final scheme = ColorScheme.fromSeed(
      seedColor: amber,
      brightness: b,
      surface: dark ? const Color(0xFF1D2026) : Colors.white,
    ).copyWith(primary: amber, onPrimary: Colors.black, secondary: teal);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: dark ? BorderSide.none : const BorderSide(color: Color(0xFFE6E2D8)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? card : const Color(0xFFEDEAE3),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

/// Holds the user's light / dark / system choice and remembers it.
class ThemeController extends ChangeNotifier {
  ThemeController(this._mode);
  ThemeMode _mode;
  static const _key = 'theme_mode';

  ThemeMode get mode => _mode;

  static Future<ThemeController> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getString(_key);
      return ThemeController(ThemeMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => ThemeMode.system,
      ));
    } catch (_) {
      return ThemeController(ThemeMode.system);
    }
  }

  Future<void> set(ThemeMode m) async {
    _mode = m;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, m.name);
    } catch (_) {/* preference just won't persist */}
  }

  /// Quick toggle between light and dark based on what is showing now.
  Future<void> toggle(BuildContext context) => set(
      Theme.of(context).brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
}
