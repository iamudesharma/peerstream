import 'package:dartnative/dartnative.dart';

import 'design_tokens.dart';

ThemeData buildPeerStreamTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: DesignTokens.background,
    colorScheme: const ColorScheme(
      brightness: Brightness.dark,
      primary: DesignTokens.accent,
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: DesignTokens.accentDim,
      onPrimaryContainer: DesignTokens.textPrimary,
      secondary: DesignTokens.accent,
      onSecondary: DesignTokens.textPrimary,
      error: DesignTokens.danger,
      onError: DesignTokens.textPrimary,
      surface: DesignTokens.surface,
      onSurface: DesignTokens.textPrimary,
      surfaceContainerHighest: DesignTokens.surface2,
      surfaceContainerHigh: DesignTokens.surface2,
      surfaceContainer: DesignTokens.surface,
      onSurfaceVariant: DesignTokens.textSecondary,
      outline: DesignTokens.line,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 36,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        height: 1.15,
      ),
      headlineMedium: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 30,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        height: 1.2,
      ),
      headlineSmall: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      titleLarge: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 21,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
      titleMedium: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: TextStyle(color: DesignTokens.textSecondary, fontSize: 14),
      bodySmall: TextStyle(color: DesignTokens.textTertiary, fontSize: 12),
    ),
  );
}
