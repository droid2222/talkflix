import 'package:flutter/material.dart';

const talkflixPrimary = Color(0xFFE50914);
const _lightBackground = Color(0xFFFFFFFF);
const _lightSurface = Color(0xFFFFFFFF);
const _lightCard = Color(0xFFF6F6F7);
const _lightBorder = Color(0x1F000000);
const _lightMuted = Color(0x8C000000);

const _darkBackground = Color(0xFF161616);
const _darkSurface = Color(0xFF1C1C1E);
const _darkCard = Color(0xFF232326);
const _darkBorder = Color(0x24FFFFFF);
const _darkMuted = Color(0x99FFFFFF);

ThemeData buildTalkflixLightTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: talkflixPrimary,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFFFDAD6),
    onPrimaryContainer: Color(0xFF410001),
    secondary: Color(0xFF5C5C61),
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFE1E1E6),
    onSecondaryContainer: Color(0xFF1A1C1E),
    tertiary: Color(0xFF7A4E00),
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xFFFFDDAE),
    onTertiaryContainer: Color(0xFF261900),
    error: Color(0xFFBA1A1A),
    onError: Colors.white,
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFF410002),
    surface: _lightSurface,
    onSurface: Colors.black,
    surfaceContainerHighest: _lightCard,
    onSurfaceVariant: _lightMuted,
    outline: _lightBorder,
    outlineVariant: _lightBorder,
    shadow: Colors.black26,
    scrim: Colors.black54,
    inverseSurface: Color(0xFF2F3033),
    onInverseSurface: Colors.white,
    inversePrimary: Color(0xFFFFB4AB),
  );

  return _buildTheme(
    scheme: scheme,
    background: _lightBackground,
    card: _lightCard,
    border: _lightBorder,
  );
}

ThemeData buildTalkflixDarkTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: talkflixPrimary,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFF93000A),
    onPrimaryContainer: Color(0xFFFFDAD6),
    secondary: Color(0xFFC5C6CC),
    onSecondary: Color(0xFF2E3133),
    secondaryContainer: Color(0xFF44474A),
    onSecondaryContainer: Color(0xFFE1E2E8),
    tertiary: Color(0xFFFFB84C),
    onTertiary: Color(0xFF402D00),
    tertiaryContainer: Color(0xFF5C4200),
    onTertiaryContainer: Color(0xFFFFDDAE),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: _darkSurface,
    onSurface: Colors.white,
    surfaceContainerHighest: _darkCard,
    onSurfaceVariant: _darkMuted,
    outline: _darkBorder,
    outlineVariant: _darkBorder,
    shadow: Colors.black87,
    scrim: Colors.black87,
    inverseSurface: Colors.white,
    onInverseSurface: Color(0xFF161616),
    inversePrimary: Color(0xFFC00110),
  );

  return _buildTheme(
    scheme: scheme,
    background: _darkBackground,
    card: _darkCard,
    border: _darkBorder,
  );
}

ThemeData _buildTheme({
  required ColorScheme scheme,
  required Color background,
  required Color card,
  required Color border,
}) {
  final isDark = scheme.brightness == Brightness.dark;
  final base = ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    canvasColor: background,
    dividerColor: border,
    fontFamily: 'Helvetica Neue',
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: border),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: background,
      indicatorColor: talkflixPrimary.withValues(alpha: isDark ? 0.24 : 0.14),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? talkflixPrimary : scheme.onSurfaceVariant,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? talkflixPrimary : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: talkflixPrimary,
      foregroundColor: Colors.white,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: talkflixPrimary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: talkflixPrimary.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: talkflixPrimary,
        side: const BorderSide(color: talkflixPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: const BorderSide(color: talkflixPrimary, width: 1.4),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: card,
      side: BorderSide(color: border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      labelStyle: TextStyle(color: scheme.onSurface),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark
          ? const Color(0xFF2A2A2D)
          : const Color(0xFF222222),
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return talkflixPrimary;
          }
          return scheme.surface;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return scheme.onSurface;
        }),
        side: WidgetStatePropertyAll(BorderSide(color: border)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    ),
  );
}
