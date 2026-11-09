import 'package:flutter/material.dart';

/// Стиль как у приложения для самоката: тёмная тема, бирюзовый акцент.
class AppColors {
  static const bg = Color(0xFF0B0F14);
  static const surface = Color(0xFF151B23);
  static const surface2 = Color(0xFF1E2630);
  static const accent = Color(0xFF2DD4BF);
  static const text = Color(0xFFE6EDF3);
  static const muted = Color(0xFF8B98A5);
  static const good = Color(0xFF2DD4BF);
  static const warn = Color(0xFFFFB020);
  static const bad = Color(0xFFFF5252);
  static const land = Color(0xFF141C24);
  static const border = Color(0xFF2A3A48);
  static const river = Color(0xFF2E6FA8);
  static const rail = Color(0xFFB0A090);
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.surface,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surface2,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

String fmtMw(double mw) {
  if (mw.abs() >= 1000) return '${(mw / 1000).toStringAsFixed(2)} ГВт';
  if (mw.abs() >= 10) return '${mw.toStringAsFixed(0)} МВт';
  return '${mw.toStringAsFixed(1)} МВт';
}

String fmtT(double t) {
  if (t >= 1e6) return '${(t / 1e6).toStringAsFixed(2)} млн т';
  if (t >= 1000) return '${(t / 1000).toStringAsFixed(1)} тыс. т';
  return '${t.toStringAsFixed(0)} т';
}

String fmtPop(int p) {
  if (p >= 1000000) return '${(p / 1e6).toStringAsFixed(2)} млн';
  if (p >= 1000) return '${(p / 1000).toStringAsFixed(0)} тыс.';
  return '$p';
}
