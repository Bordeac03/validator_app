import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Brand colors and design tokens.
///
/// Identity built directly on the official coat of arms of Municipiul Roman:
///   • Gules (red) field  → primary brand color
///   • Or (gold) boar head → accent / highlight
///   • Argent (silver) mural crown → neutral metal accent
class MovaColors {
  MovaColors._();

  // ── Primary identity: civic MAGENTA (from Consiliul Local livestream) ────
  // Sober, institutional aubergine-magenta — the SBB approach: ONE confident,
  // restrained accent on calm white surfaces (not a neon highlight). Slightly
  // deepened & desaturated from the raw broadcast #99168C for a quieter,
  // more corporate railway feel.
  static const Color magenta = Color(0xFF8A1A7F); // primary brand (sober)
  static const Color magentaDark = Color(0xFF6E1466);
  static const Color magentaDeep = Color(0xFF53104D); // hero gradient end
  static const Color magentaLight = Color(0xFF9E3494);
  static const Color magentaTint = Color(0xFFF4ECF3); // soft wash on white

  // The brand "red" alias now points to magenta so the entire legacy UI
  // (which references MovaColors.red everywhere) instantly re-skins.
  static const Color red = magenta;
  static const Color redDark = magentaDark;
  static const Color redDeep = magentaDeep;
  static const Color redLight = magentaLight;

  // ── Heraldic crest colours (kept exact for the coat of arms accents) ─────
  static const Color heraldicRed = Color(0xFFD82128); // shield field
  static const Color gold = Color(0xFFFAD511); // boar head (Or)
  static const Color goldDeep = Color(0xFFE0B800);
  static const Color goldSoft = Color(0xFFFFEC8A);

  // ── Metal: heraldic SILVER (Argent) ─────────────────────────────────────
  static const Color silver = Color(0xFFC1C2C0); // coroana murală
  static const Color silverDark = Color(0xFF9DA09D);

  // ── Backwards-compat aliases (kept so legacy refs keep compiling) ────────
  static const Color teal = magenta;
  static const Color tealDark = magentaDark;
  static const Color tealLight = magentaLight;
  static const Color tealGlow = magentaLight;
  // Deep neutral ink used for map markers / pills (clean, not brown).
  static const Color navy = Color(0xFF211B2A);
  static const Color navyMid = Color(0xFF332A40);

  // ── Light scheme (pure, clean SBB white — bright & airy) ────────────────
  static const Color lightBg = Color(0xFFFFFFFF); // pure white canvas
  static const Color lightCard = Colors.white;
  static const Color lightCardAlt = Color(0xFFF7F7FA); // faint grey tier
  static const Color lightText = Color(0xFF202024); // near-black ink
  static const Color lightTextSecondary = Color(0xFF8A8A93); // soft grey
  static const Color lightBorder = Color(0xFFEDEDF1); // hairline grey

  // ── Dark scheme (deep plum-tinted slate — premium, on-brand) ────────────
  static const Color darkBg = Color(0xFF14101A);
  static const Color darkSurface = Color(0xFF1C1724);
  static const Color darkCard = Color(0xFF221C2C);
  static const Color darkCardAlt = Color(0xFF2A2336); // elevated tier
  static const Color darkText = Color(0xFFF4F1F7);
  static const Color darkTextSecondary = Color(0xFFA39BAE);
  static const Color darkBorder = Color(0xFF332B40);

  // ── Status ──────────────────────────────────────────────────────────────
  static const Color success = Color(0xFF2E9E5B);
  static const Color warning = Color(0xFFE0A400);
  static const Color danger = Color(0xFFD64545);
  static const Color used = Color(0xFF8A909C);

  // ── Municipal aliases (explicit names used across UI) ────────────────────
  static const Color romanRed = heraldicRed;
  static const Color romanRedDark = magentaDark;
  static const Color romanGold = gold;
  static const Color romanGoldDeep = goldDeep;
  static const Color romanSilver = silver;
  static const Color romanSilverDark = silverDark;
}

/// Helper to read palette based on brightness.
class MovaPalette {
  final bool isDark;
  const MovaPalette(this.isDark);

  Color get bg => isDark ? MovaColors.darkBg : MovaColors.lightBg;
  Color get card => isDark ? MovaColors.darkCard : MovaColors.lightCard;
  Color get cardAlt =>
      isDark ? MovaColors.darkCardAlt : MovaColors.lightCardAlt;
  Color get surface => isDark ? MovaColors.darkSurface : MovaColors.lightCard;
  Color get text => isDark ? MovaColors.darkText : MovaColors.lightText;
  Color get textSecondary =>
      isDark ? MovaColors.darkTextSecondary : MovaColors.lightTextSecondary;
  Color get border => isDark ? MovaColors.darkBorder : MovaColors.lightBorder;

  /// Soft brand wash for chips / selected states on light surfaces.
  Color get brandTint => isDark
      ? MovaColors.magenta.withValues(alpha: 0.18)
      : MovaColors.magentaTint;

  static MovaPalette of(BuildContext context) =>
      MovaPalette(Theme.of(context).brightness == Brightness.dark);
}

class MovaTheme {
  MovaTheme._();

  static const double radius = 18.0;
  static const double radiusSmall = 14.0;

  /// Soft red glow shadow for hero actions.
  static List<BoxShadow> tealGlow({double opacity = 0.35, double blur = 24}) =>
      [
        BoxShadow(
          color: MovaColors.red.withValues(alpha: opacity),
          blurRadius: blur,
          offset: const Offset(0, 8),
        ),
      ];

  /// Warm golden glow (used on crest / premium accents).
  static List<BoxShadow> goldGlow({double opacity = 0.45, double blur = 26}) =>
      [
        BoxShadow(
          color: MovaColors.gold.withValues(alpha: opacity),
          blurRadius: blur,
          offset: const Offset(0, 6),
        ),
      ];

  /// Soft neutral card shadow (premium, subtle, two-layer in light mode).
  static List<BoxShadow> softShadow(bool isDark) => isDark
      ? [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.32),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ]
      : [
          BoxShadow(
            color: const Color(0xFF1B1B2E).withValues(alpha: 0.045),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: const Color(0xFF1B1B2E).withValues(alpha: 0.025),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ];

  /// Civic-magenta hero gradient — sober, near-flat, institutional.
  /// Only a subtle top→bottom deepening; no flashy three-colour rainbow.
  static const LinearGradient heroGradient = LinearGradient(
    colors: [MovaColors.magenta, MovaColors.magentaDark],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Action gradient (kept restrained — single hue, gentle depth).
  static const LinearGradient tealGradient = LinearGradient(
    colors: [MovaColors.magenta, MovaColors.magentaDark],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Golden gradient for crest / premium chips.
  static const LinearGradient goldGradient = LinearGradient(
    colors: [MovaColors.goldSoft, MovaColors.gold, MovaColors.goldDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final p = MovaPalette(isDark);

    final colorScheme = ColorScheme.fromSeed(
      seedColor: MovaColors.red,
      brightness: brightness,
    ).copyWith(
      primary: MovaColors.red,
      secondary: MovaColors.gold,
      surface: p.card,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.bg,
      fontFamily: 'Roboto',
    );

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: p.text),
      ),
      cardTheme: CardThemeData(
        color: p.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: p.border, width: isDark ? 1 : 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: MovaColors.red,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          backgroundColor: Colors.transparent,
          side: BorderSide(color: p.border, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSmall),
          ),
          textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: MovaColors.red,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        hintStyle: TextStyle(color: p.textSecondary),
        labelStyle: TextStyle(color: p.textSecondary),
        prefixIconColor: p.textSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: const BorderSide(color: MovaColors.red, width: 1.8),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? MovaColors.darkCard : MovaColors.redDark,
        contentTextStyle: const TextStyle(
            color: Colors.white, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dividerTheme: DividerThemeData(color: p.border, thickness: 1),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: p.card,
        selectedItemColor: MovaColors.red,
        unselectedItemColor: p.textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        selectedLabelStyle:
            const TextStyle(fontWeight: FontWeight.w700, fontSize: 11.5),
        unselectedLabelStyle:
            const TextStyle(fontWeight: FontWeight.w600, fontSize: 11.5),
      ),
    );
  }

  static ThemeData get light => _base(Brightness.light);
  static ThemeData get dark => _base(Brightness.dark);
}
