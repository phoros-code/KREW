import 'package:flutter/material.dart';

/// Design tokens — exact values from DESIGN.md. Do not invent new ones.
///
/// Palette:
///   base dark  #12131A / base light #F5F4F0 (70% neutral)
///   primary    #1E5F4A (deep teal-green, dominant)
///   accent     #E8A33D (warm amber, sparing — one or two things per screen)
///   success    #3A8B5C / warning #D9932A / error #C4453D (status only)
///
/// Accessible text variants (Track C1, same hues, WCAG AA):
///   warningOnLight #8A5A12 (5.37:1 on baseLight)
///   warningOnDark  #E1A955 (8.83:1 on baseDark)
///   successOnLight #2E6F4A (5.47:1 on baseLight)
///   successOnDark  #4E976C (5.26:1 on baseDark)
///   errorOnLight   #B03E37 (5.31:1 on baseLight)
///   errorOnDark    #D06A64 (5.23:1 on baseDark)
///   outlineOnDark  #6E6F7A (3.72:1 on baseDark, M3 outline slot)
///
/// Rule: 11px badge/pill labels, error titles, and error copy ALWAYS use the
/// OnLight/OnDark variant matching the current brightness. Base hues remain
/// for large graphics only (6px dots, fills).
///
/// Type: Space Grotesk headlines / IBM Plex Sans body / JetBrains Mono mono.
/// Fonts are bundled TTFs under assets/fonts/ (TODO-FONTS pending) — NO
/// runtime CDN. TextStyle(fontFamily) prefers the DESIGN.md family and falls
/// back to Roboto explicitly.
/// Spacing: 4 / 8 / 12 / 16 / 24 / 32 / 48 / 64 (base unit 4px).
/// Radii: 8 interactive (buttons, inputs), 12 containers.
abstract final class BuddyColors {
  static const Color baseDark = Color(0xFF12131A);
  static const Color baseLight = Color(0xFFF5F4F0);
  static const Color primary = Color(0xFF1E5F4A);
  static const Color accent = Color(0xFFE8A33D);
  static const Color success = Color(0xFF3A8B5C);
  static const Color warning = Color(0xFFD9932A);
  static const Color error = Color(0xFFC4453D);

  // Accessible text variants — same hues, darker/lighter only.
  static const Color warningOnLight = Color(0xFF8A5A12);
  static const Color warningOnDark = Color(0xFFE1A955);
  static const Color successOnLight = Color(0xFF2E6F4A);
  static const Color successOnDark = Color(0xFF4E976C);
  static const Color errorOnLight = Color(0xFFB03E37);
  static const Color errorOnDark = Color(0xFFD06A64);
  static const Color outlineOnDark = Color(0xFF6E6F7A);

  // Neutrals derived from the two bases — text and hairlines only.
  static const Color inkOnLight = Color(0xFF1B1C22);
  static const Color inkMutedOnLight = Color(0xFF5B5C66);
  static const Color hairlineOnLight = Color(0xFFDCD9D1);
  static const Color inkOnDark = Color(0xFFF5F4F0);
  static const Color inkMutedOnDark = Color(0xFFA7A7B0);
  static const Color hairlineOnDark = Color(0xFF2E2F3A);
}

/// Spacing scale from DESIGN.md — use only these values.
abstract final class BuddySpacing {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;
  static const double s8 = 64;
}

/// Corner radii from DESIGN.md — 8 interactive, 12 containers.
abstract final class BuddyRadii {
  static const double interactive = 8;
  static const double container = 12;
}

// M3 container tints derived from the palette (same hues, no purple).
// Light: light tints of primary/accent/error + warm-grey neutrals from base.
// Dark: reuse of the OnLight/OnDark text variants + near-black neutrals.
const Color _primaryContainerLight = Color(0xFFD9E7DE);
const Color _secondaryContainerLight = Color(0xFFF7E8C9);
const Color _errorContainerLight = Color(0xFFF8E0DD);
const Color _surfaceContainerLight = Color(0xFFEFEDE8);
const Color _surfaceContainerHighLight = Color(0xFFE7E4DD);
const Color _surfaceLowestDark = Color(0xFF0C0D12);
const Color _surfaceContainerDark = Color(0xFF1B1C24);
const Color _surfaceContainerHighDark = Color(0xFF24252F);

abstract final class BuddyTheme {
  /// DESIGN.md families. Bundled TTFs pending (TODO-FONTS) — until they land
  /// the runtime falls back to Roboto explicitly (no CDN).
  static const String headlineFamily = 'Space Grotesk';
  static const String bodyFamily = 'IBM Plex Sans';
  static const String monoFamily = 'JetBrains Mono';
  static const String fallbackFamily = 'Roboto';

  static TextTheme _textTheme(Color body, Color muted) {
    // Headlines: Space Grotesk. Body: IBM Plex Sans. Fallback: Roboto.
    return TextTheme(
      headlineSmall: TextStyle(
        fontFamily: headlineFamily,
        fontFamilyFallback: const <String>[fallbackFamily],
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: body,
        letterSpacing: -0.25,
      ),
      titleLarge: TextStyle(
        fontFamily: headlineFamily,
        fontFamilyFallback: const <String>[fallbackFamily],
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: body,
      ),
      titleMedium: TextStyle(
        fontFamily: headlineFamily,
        fontFamilyFallback: const <String>[fallbackFamily],
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: body,
      ),
      bodyLarge: TextStyle(
        fontFamily: bodyFamily,
        fontFamilyFallback: const <String>[fallbackFamily],
        fontSize: 15,
        color: body,
        height: 1.45,
      ),
      bodyMedium: TextStyle(
        fontFamily: bodyFamily,
        fontFamilyFallback: const <String>[fallbackFamily],
        fontSize: 13.5,
        color: body,
        height: 1.45,
      ),
      bodySmall: TextStyle(
        fontFamily: bodyFamily,
        fontFamilyFallback: const <String>[fallbackFamily],
        fontSize: 12.5,
        color: muted,
        height: 1.4,
      ),
      labelLarge: TextStyle(
        fontFamily: bodyFamily,
        fontFamilyFallback: const <String>[fallbackFamily],
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: body,
      ),
    );
  }

  static TextStyle mono(Color color, {double size = 12.5}) {
    return TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: const <String>[fallbackFamily],
      fontSize: size,
      color: color,
      height: 1.45,
    );
  }

  static const _inputBorderLight = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(BuddyRadii.interactive)),
    borderSide: BorderSide(color: BuddyColors.hairlineOnLight),
  );

  static const _inputBorderDark = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(BuddyRadii.interactive)),
    borderSide: BorderSide(color: BuddyColors.hairlineOnDark),
  );

  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: BuddyColors.primary,
    onPrimary: Colors.white,
    primaryContainer: _primaryContainerLight,
    onPrimaryContainer: BuddyColors.primary,
    primaryFixed: _primaryContainerLight,
    primaryFixedDim: BuddyColors.primary,
    onPrimaryFixed: BuddyColors.primary,
    onPrimaryFixedVariant: BuddyColors.primary,
    secondary: BuddyColors.accent,
    onSecondary: BuddyColors.inkOnLight,
    secondaryContainer: _secondaryContainerLight,
    onSecondaryContainer: BuddyColors.warningOnLight,
    secondaryFixed: _secondaryContainerLight,
    secondaryFixedDim: BuddyColors.accent,
    onSecondaryFixed: BuddyColors.warningOnLight,
    onSecondaryFixedVariant: BuddyColors.warningOnLight,
    tertiary: BuddyColors.primary,
    onTertiary: Colors.white,
    tertiaryContainer: _primaryContainerLight,
    onTertiaryContainer: BuddyColors.primary,
    tertiaryFixed: _primaryContainerLight,
    tertiaryFixedDim: BuddyColors.primary,
    onTertiaryFixed: BuddyColors.primary,
    onTertiaryFixedVariant: BuddyColors.primary,
    error: BuddyColors.errorOnLight,
    onError: Colors.white,
    errorContainer: _errorContainerLight,
    onErrorContainer: BuddyColors.errorOnLight,
    surface: BuddyColors.baseLight,
    onSurface: BuddyColors.inkOnLight,
    surfaceDim: BuddyColors.hairlineOnLight,
    surfaceBright: Colors.white,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: BuddyColors.baseLight,
    surfaceContainer: _surfaceContainerLight,
    surfaceContainerHigh: _surfaceContainerHighLight,
    surfaceContainerHighest: BuddyColors.hairlineOnLight,
    onSurfaceVariant: BuddyColors.inkMutedOnLight,
    outline: BuddyColors.inkMutedOnLight,
    outlineVariant: BuddyColors.hairlineOnLight,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: BuddyColors.baseDark,
    onInverseSurface: BuddyColors.inkOnDark,
    inversePrimary: BuddyColors.accent,
    surfaceTint: BuddyColors.primary,
  );

  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: BuddyColors.primary,
    onPrimary: Colors.white,
    primaryContainer: BuddyColors.primary,
    onPrimaryContainer: _primaryContainerLight,
    primaryFixed: _primaryContainerLight,
    primaryFixedDim: BuddyColors.primary,
    onPrimaryFixed: BuddyColors.primary,
    onPrimaryFixedVariant: BuddyColors.primary,
    secondary: BuddyColors.accent,
    onSecondary: BuddyColors.baseDark,
    secondaryContainer: BuddyColors.warningOnLight,
    onSecondaryContainer: _secondaryContainerLight,
    secondaryFixed: _secondaryContainerLight,
    secondaryFixedDim: BuddyColors.accent,
    onSecondaryFixed: BuddyColors.warningOnLight,
    onSecondaryFixedVariant: BuddyColors.warningOnLight,
    tertiary: BuddyColors.primary,
    onTertiary: Colors.white,
    tertiaryContainer: BuddyColors.primary,
    onTertiaryContainer: _primaryContainerLight,
    tertiaryFixed: _primaryContainerLight,
    tertiaryFixedDim: BuddyColors.primary,
    onTertiaryFixed: BuddyColors.primary,
    onTertiaryFixedVariant: BuddyColors.primary,
    error: BuddyColors.errorOnDark,
    onError: BuddyColors.baseDark,
    errorContainer: BuddyColors.errorOnLight,
    onErrorContainer: _errorContainerLight,
    surface: BuddyColors.baseDark,
    onSurface: BuddyColors.inkOnDark,
    surfaceDim: _surfaceLowestDark,
    surfaceBright: BuddyColors.hairlineOnDark,
    surfaceContainerLowest: _surfaceLowestDark,
    surfaceContainerLow: BuddyColors.baseDark,
    surfaceContainer: _surfaceContainerDark,
    surfaceContainerHigh: _surfaceContainerHighDark,
    surfaceContainerHighest: BuddyColors.hairlineOnDark,
    onSurfaceVariant: BuddyColors.inkMutedOnDark,
    outline: BuddyColors.outlineOnDark,
    outlineVariant: BuddyColors.hairlineOnDark,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: BuddyColors.baseLight,
    onInverseSurface: BuddyColors.inkOnLight,
    inversePrimary: BuddyColors.primary,
    surfaceTint: BuddyColors.primary,
  );

  static NavigationBarThemeData _navTheme({
    required Color background,
    required Color indicator,
    required Color selected,
    required Color unselected,
  }) {
    return NavigationBarThemeData(
      backgroundColor: background,
      elevation: 0,
      indicatorColor: indicator,
      indicatorShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(
          Radius.circular(BuddyRadii.interactive),
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
        (Set<WidgetState> states) => TextStyle(
          fontFamily: bodyFamily,
          fontFamilyFallback: const <String>[fallbackFamily],
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: states.contains(WidgetState.selected)
              ? selected
              : unselected,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>(
        (Set<WidgetState> states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? selected
              : unselected,
          size: 24,
        ),
      ),
    );
  }

  /// Shared ThemeData builder — light() and dark() differ only by the
  /// scheme, scaffold/app-bar colors, text theme, input borders, outlined
  /// foreground, and nav theme. Everything else (M3, buttons, radii,
  /// spacing) is identical.
  static ThemeData _build({
    required ColorScheme scheme,
    required Color scaffold,
    required TextTheme textTheme,
    required InputDecorationTheme inputTheme,
    required Color outlinedFg,
    required NavigationBarThemeData navTheme,
  }) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        foregroundColor: scheme.onSurface,
        elevation: 0,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: BuddyColors.primary,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(BuddyRadii.interactive),
            ),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: BuddySpacing.s4,
            vertical: BuddySpacing.s3,
          ),
          textStyle: const TextStyle(
            fontFamily: bodyFamily,
            fontFamilyFallback: <String>[fallbackFamily],
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: outlinedFg,
          side: const BorderSide(color: BuddyColors.primary),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(
              Radius.circular(BuddyRadii.interactive),
            ),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: BuddySpacing.s4,
            vertical: BuddySpacing.s3,
          ),
        ),
      ),
      inputDecorationTheme: inputTheme,
      navigationBarTheme: navTheme,
    );
  }

  static ThemeData light() {
    return _build(
      scheme: _lightScheme,
      scaffold: BuddyColors.baseLight,
      textTheme: _textTheme(
        BuddyColors.inkOnLight,
        BuddyColors.inkMutedOnLight,
      ),
      inputTheme: const InputDecorationTheme(
        border: _inputBorderLight,
        enabledBorder: _inputBorderLight,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(BuddyRadii.interactive),
          ),
          borderSide: BorderSide(color: BuddyColors.primary, width: 1.5),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: BuddySpacing.s3,
          vertical: BuddySpacing.s3,
        ),
      ),
      outlinedFg: BuddyColors.primary,
      navTheme: _navTheme(
        background: BuddyColors.baseLight,
        indicator: _primaryContainerLight,
        selected: BuddyColors.primary,
        unselected: BuddyColors.inkMutedOnLight,
      ),
    );
  }

  static ThemeData dark() {
    return _build(
      scheme: _darkScheme,
      scaffold: BuddyColors.baseDark,
      textTheme: _textTheme(
        BuddyColors.inkOnDark,
        BuddyColors.inkMutedOnDark,
      ),
      inputTheme: const InputDecorationTheme(
        border: _inputBorderDark,
        enabledBorder: _inputBorderDark,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(BuddyRadii.interactive),
          ),
          borderSide: BorderSide(color: BuddyColors.primary, width: 1.5),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: BuddySpacing.s3,
          vertical: BuddySpacing.s3,
        ),
      ),
      outlinedFg: BuddyColors.accent,
      navTheme: _navTheme(
        background: BuddyColors.baseDark,
        indicator: BuddyColors.primary,
        selected: Colors.white,
        unselected: BuddyColors.inkMutedOnDark,
      ),
    );
  }
}
