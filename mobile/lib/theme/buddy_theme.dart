import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens — exact values from DESIGN.md. Do not invent new ones.
///
/// Palette:
///   base dark  #12131A / base light #F5F4F0 (70% neutral)
///   primary    #1E5F4A (deep teal-green, dominant)
///   accent     #E8A33D (warm amber, sparing — one or two things per screen)
///   success    #3A8B5C / warning #D9932A / error #C4453D (status only)
///
/// Type: Space Grotesk headlines / IBM Plex Sans body / JetBrains Mono mono.
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

abstract final class BuddyTheme {
  static TextTheme _textTheme(Color body, Color muted) {
    // Headlines: Space Grotesk. Body: IBM Plex Sans. Mono: JetBrains Mono.
    final headlines = GoogleFonts.spaceGroteskTextTheme(
      TextTheme(
        headlineSmall: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          color: body,
          letterSpacing: -0.25,
        ),
        titleLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: body,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: body,
        ),
      ),
    );
    final bodyThemes = GoogleFonts.ibmPlexSansTextTheme(
      TextTheme(
        bodyLarge: TextStyle(fontSize: 15, color: body, height: 1.45),
        bodyMedium: TextStyle(fontSize: 13.5, color: body, height: 1.45),
        bodySmall: TextStyle(fontSize: 12.5, color: muted, height: 1.4),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: body,
        ),
      ),
    );
    return headlines.merge(bodyThemes);
  }

  static TextStyle mono(Color color, {double size = 12.5}) {
    return GoogleFonts.jetBrainsMono(
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

  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: BuddyColors.primary,
      secondary: BuddyColors.accent,
      surface: BuddyColors.baseLight,
      error: BuddyColors.error,
      onPrimary: Colors.white,
      onSurface: BuddyColors.inkOnLight,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: BuddyColors.baseLight,
      textTheme: _textTheme(
        BuddyColors.inkOnLight,
        BuddyColors.inkMutedOnLight,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: BuddyColors.baseLight,
        foregroundColor: BuddyColors.inkOnLight,
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
          textStyle: GoogleFonts.ibmPlexSans(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BuddyColors.primary,
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
      inputDecorationTheme: const InputDecorationTheme(
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
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: BuddyColors.baseLight,
        selectedItemColor: BuddyColors.primary,
        unselectedItemColor: BuddyColors.inkMutedOnLight,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: BuddyColors.primary,
      secondary: BuddyColors.accent,
      surface: BuddyColors.baseDark,
      error: BuddyColors.error,
      onPrimary: Colors.white,
      onSurface: BuddyColors.inkOnDark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: BuddyColors.baseDark,
      textTheme: _textTheme(
        BuddyColors.inkOnDark,
        BuddyColors.inkMutedOnDark,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: BuddyColors.baseDark,
        foregroundColor: BuddyColors.inkOnDark,
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
          textStyle: GoogleFonts.ibmPlexSans(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BuddyColors.accent,
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
      inputDecorationTheme: const InputDecorationTheme(
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
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: BuddyColors.baseDark,
        selectedItemColor: BuddyColors.accent,
        unselectedItemColor: BuddyColors.inkMutedOnDark,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }
}
