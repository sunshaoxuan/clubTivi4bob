import 'package:flutter/material.dart';

import 'bobtv_palette.dart';

/// clubTivi dark theme — optimized for TV viewing (OLED-friendly, high contrast).
class ClubTiviTheme {
  static ThemeData get dark {
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: BobTvPalette.accent,
        brightness: Brightness.dark,
        surface: BobTvPalette.background,
        surfaceContainer: BobTvPalette.panel,
        surfaceContainerHigh: BobTvPalette.raised,
        primary: BobTvPalette.accent,
        onPrimary: BobTvPalette.onAccent,
        secondary: BobTvPalette.pink,
        onSecondary: BobTvPalette.onAccent,
        secondaryContainer: BobTvPalette.selected,
        onSecondaryContainer: BobTvPalette.ink,
        onSurface: BobTvPalette.ink,
        onSurfaceVariant: BobTvPalette.muted,
        outline: BobTvPalette.outline,
      ),
      scaffoldBackgroundColor: BobTvPalette.background,
      cardTheme: const CardThemeData(
        color: BobTvPalette.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      // Focus highlight for D-pad / remote navigation
      focusColor: BobTvPalette.accent.withValues(alpha: 0.45),
      hoverColor: BobTvPalette.accent.withValues(alpha: 0.1),
      // ListTile focus/hover styling
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        selectedTileColor: BobTvPalette.accent.withValues(alpha: 0.2),
      ),
      // Filled button focus styling
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          backgroundColor: BobTvPalette.accent,
          foregroundColor: BobTvPalette.onAccent,
        ).copyWith(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: BobTvPalette.onAccent, width: 2);
            }
            return null;
          }),
        ),
      ),
      // Text button focus styling
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 48),
        ).copyWith(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: BobTvPalette.accent, width: 2);
            }
            return null;
          }),
        ),
      ),
      // Icon button focus styling
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
        ).copyWith(
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: BobTvPalette.accent, width: 2);
            }
            return null;
          }),
        ),
      ),
      // FloatingActionButton styling
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: BobTvPalette.accent,
        foregroundColor: BobTvPalette.onAccent,
        focusColor: BobTvPalette.accent.withValues(alpha: 0.8),
        focusElevation: 8,
      ),
      // Switch styling for settings
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return BobTvPalette.accent;
          return Colors.white54;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BobTvPalette.accent.withValues(alpha: 0.4);
          }
          return Colors.white12;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return BobTvPalette.accent.withValues(alpha: 0.2);
          }
          return null;
        }),
      ),
      // Input decoration for text fields
      inputDecorationTheme: InputDecorationTheme(
        border: const OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: BobTvPalette.accent, width: 2),
          borderRadius: BorderRadius.circular(8),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      // Tab bar styling
      tabBarTheme: const TabBarThemeData(
        indicatorColor: BobTvPalette.accent,
        labelColor: BobTvPalette.accent,
        unselectedLabelColor: Colors.white54,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: BobTvPalette.ink,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: BobTvPalette.ink,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: BobTvPalette.muted,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: BobTvPalette.muted,
        ),
      ),
    );
  }
}
