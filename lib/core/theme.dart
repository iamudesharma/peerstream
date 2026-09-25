import 'package:dartnative/dartnative.dart';

import 'design_tokens.dart';

ThemeData buildPeerStreamTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: DesignTokens.background,
    colorScheme: const ColorScheme(
      brightness: Brightness.dark,
      primary: DesignTokens.accent,
      onPrimary: Color(0xFF06231B),
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
      headlineSmall: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
      titleLarge: TextStyle(
        color: DesignTokens.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
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
