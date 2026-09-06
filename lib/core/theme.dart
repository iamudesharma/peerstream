import 'package:flutter/material.dart';

import 'design_tokens.dart';

ThemeData buildPeerStreamTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: DesignTokens.accent,
    brightness: Brightness.dark,
    surface: DesignTokens.surface,
  ).copyWith(
    primary: DesignTokens.accent,
    onPrimary: const Color(0xFF06231B),
    surface: DesignTokens.surface,
    surfaceContainerHighest: DesignTokens.surface2,
    error: DesignTokens.danger,
  );
  const shapeCard = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(
      Radius.circular(DesignTokens.radiusCard),
    ),
    side: BorderSide(color: DesignTokens.line),
  );
  const shapeInput = OutlineInputBorder(
    borderRadius: BorderRadius.all(
      Radius.circular(DesignTokens.radiusInput),
    ),
    borderSide: BorderSide.none,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: DesignTokens.background,
    cardTheme: const CardThemeData(
      color: DesignTokens.surface,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      shape: shapeCard,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: DesignTokens.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: DesignTokens.textPrimary,
      titleTextStyle: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: DesignTokens.surface2,
      hintStyle: TextStyle(color: DesignTokens.textTertiary),
      prefixIconColor: DesignTokens.textSecondary,
      suffixIconColor: DesignTokens.textSecondary,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: shapeInput,
      enabledBorder: shapeInput,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(DesignTokens.radiusInput),
        ),
        borderSide: BorderSide(color: DesignTokens.accent, width: 1.5),
      ),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: DesignTokens.surface2,
      selectedColor: DesignTokens.accentDim,
      disabledColor: DesignTokens.surface,
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      labelStyle: TextStyle(color: DesignTokens.textPrimary, fontSize: 13),
      secondaryLabelStyle:
          TextStyle(color: DesignTokens.textSecondary, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(DesignTokens.radiusInput),
        ),
        side: BorderSide(color: DesignTokens.lineStrong),
      ),
      side: BorderSide(color: DesignTokens.lineStrong),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: DesignTokens.textPrimary,
      unselectedLabelColor: DesignTokens.textSecondary,
      indicatorColor: DesignTokens.accent,
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: DesignTokens.line,
      labelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      unselectedLabelStyle: TextStyle(fontSize: 13),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: DesignTokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(DesignTokens.radiusCard),
        ),
        side: BorderSide(color: DesignTokens.lineStrong),
      ),
      titleTextStyle: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
      contentTextStyle: TextStyle(
        color: DesignTokens.textSecondary,
        fontSize: 14,
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: DesignTokens.surface,
      indicatorColor: DesignTokens.accentDim,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: DesignTokens.background,
      indicatorColor: DesignTokens.accentDim,
      selectedIconTheme: IconThemeData(color: DesignTokens.accent),
      selectedLabelTextStyle: TextStyle(color: DesignTokens.textPrimary),
      unselectedLabelTextStyle: TextStyle(color: DesignTokens.textSecondary),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: DesignTokens.textSecondary,
      titleTextStyle: TextStyle(
        color: DesignTokens.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      subtitleTextStyle: TextStyle(color: DesignTokens.textSecondary),
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    dividerTheme: const DividerThemeData(
      color: DesignTokens.line,
      thickness: 1,
      space: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: DesignTokens.accent,
      linearTrackColor: DesignTokens.surface2,
      circularTrackColor: DesignTokens.surface2,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: DesignTokens.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(DesignTokens.radiusCard),
        ),
        side: BorderSide(color: DesignTokens.lineStrong),
      ),
      textStyle: TextStyle(color: DesignTokens.textPrimary),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: DesignTokens.surface2,
      contentTextStyle: TextStyle(color: DesignTokens.textPrimary),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(DesignTokens.radiusInput),
        ),
      ),
    ),
  );
}
