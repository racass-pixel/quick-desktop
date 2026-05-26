// Design tokens and a Material ThemeData wired to them.
// Palette mirrors quick-web's deep-ink + ember accent system.

import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFF0F1014);
  static const panel = Color(0xFF16171C);
  static const raised = Color(0xFF1C1D24);
  static const line = Color(0xFF22232C);
  static const ink1 = Color(0xFFE8E9EE);
  static const ink2 = Color(0xFFA6A8B5);
  static const ink3 = Color(0xFF6F7180);
  static const ember = Color(0xFFEA580C);
  static const emberSoft = Color(0xFFF97316);
  static const err = Color(0xFFEF4444);
}

class AppRadii {
  static const rSm = 6.0;
  static const rMd = 10.0;
  static const rLg = 14.0;
  static const rXl = 20.0;
}

ThemeData buildAppTheme() {
  const baseFont = 'Segoe UI';
  final scheme = const ColorScheme.dark(
    primary: AppColors.ember,
    onPrimary: Colors.white,
    secondary: AppColors.emberSoft,
    surface: AppColors.panel,
    onSurface: AppColors.ink1,
    error: AppColors.err,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.bg,
    fontFamily: baseFont,
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.compact,
  );

  TextStyle t(double size, FontWeight w, Color c, {double? height}) =>
      TextStyle(fontSize: size, fontWeight: w, color: c, height: height);

  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: baseFont).copyWith(
          headlineMedium: t(20, FontWeight.w600, AppColors.ink1),
          titleMedium: t(15, FontWeight.w600, AppColors.ink1),
          bodyLarge: t(14, FontWeight.w400, AppColors.ink1, height: 1.35),
          bodyMedium: t(13.5, FontWeight.w400, AppColors.ink1, height: 1.4),
          bodySmall: t(12, FontWeight.w400, AppColors.ink2),
          labelLarge: t(13, FontWeight.w600, AppColors.ink1),
          labelMedium: t(12, FontWeight.w500, AppColors.ink2),
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.raised,
      hintStyle: const TextStyle(color: AppColors.ink3),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.rMd),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.rMd),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.rMd),
        borderSide: const BorderSide(color: AppColors.ember, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.rMd),
        borderSide: const BorderSide(color: AppColors.err),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.ember,
        foregroundColor: Colors.white,
        elevation: 0,
        padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.rMd),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.emberSoft,
        textStyle: const TextStyle(fontWeight: FontWeight.w500),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.line,
      thickness: 1,
      space: 1,
    ),
  );
}

// Deterministic avatar background from a hex string or a fallback hash of the
// seed string. Returns a Color usable in BoxDecoration.
Color avatarColor(String hex, [String seed = '']) {
  if (hex.startsWith('#') && (hex.length == 7 || hex.length == 4)) {
    var s = hex.substring(1);
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    final v = int.tryParse(s, radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  // Fallback: pick from a small palette by hashing the seed.
  const palette = <int>[
    0xFFEA580C, 0xFF6366F1, 0xFF10B981, 0xFFF59E0B,
    0xFFEC4899, 0xFF06B6D4, 0xFF8B5CF6, 0xFFEF4444,
  ];
  final h = seed.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7FFFFFFF);
  return Color(palette[h % palette.length]);
}

String avatarInitials(String name) {
  final cleaned = name.trim();
  if (cleaned.isEmpty) return '?';
  final parts = cleaned.split(RegExp(r'\s+'));
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
}
