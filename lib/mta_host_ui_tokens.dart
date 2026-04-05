import 'package:flutter/material.dart';

/// Đồng bộ với [mta.pos.ui.theme.AppColors] (Agent-Kiosk-Mobile) — NFC dialog / form trong module.
abstract final class MtaHostUi {
  static const Color primary = Color(0xFF702B8F);
  static const Color primaryLight = Color(0xFFE8CFF6);
  static const Color background = Color(0xFFF0F1F3);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color text = Color(0xFF1E1E1E);
  static const Color textSecondary = Color(0xFF6C7280);
  static const Color error = Color(0xFFC23A3A);
  static const Color warning = Color(0xFFC47F18);
  static const Color border = Color(0xFFDFE3EA);

  /// Bo góc thẻ dialog (Compose: 16.dp.scaled).
  static const double cardRadius = 16;

  /// Đổ bóng thẻ (Compose: shadowElevation 8.dp).
  static const double cardElevation = 8;

  /// Chiều ngang thẻ / dialog so với màn hình (Compose: fillMaxWidth 0.8f).
  static const double cardWidthFraction = 0.8;

  /// Trần chiều cao thẻ (Compose: maxHeight * 0.92f).
  static const double cardMaxHeightFraction = 0.92;

  static ThemeData theme() {
    final scheme = ColorScheme.light(
      primary: primary,
      onPrimary: Colors.white,
      surface: surface,
      onSurface: text,
      error: error,
      onError: Colors.white,
      primaryContainer: primaryLight,
      onPrimaryContainer: text,
    );
    final radius = BorderRadius.circular(8);
    final enabledOutline = OutlineInputBorder(
      borderRadius: radius,
      borderSide: const BorderSide(color: border),
    );
    final focusedOutline = OutlineInputBorder(
      borderRadius: radius,
      borderSide: const BorderSide(color: primary, width: 2),
    );
    final errorOutline = OutlineInputBorder(
      borderRadius: radius,
      borderSide: const BorderSide(color: error),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: enabledOutline,
        enabledBorder: enabledOutline,
        focusedBorder: focusedOutline,
        errorBorder: errorOutline,
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: const BorderSide(color: error, width: 2),
        ),
        labelStyle: const TextStyle(color: textSecondary),
        hintStyle: const TextStyle(color: textSecondary),
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        bodyLarge: TextStyle(fontSize: 16, color: text),
        bodyMedium: TextStyle(fontSize: 14, color: text),
        bodySmall: TextStyle(fontSize: 12, color: textSecondary),
      ),
    );
  }
}
