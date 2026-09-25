import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Every value from docs/design.md §3 ("Sticker UI"). Nothing outside this file picks its own color or radius.
abstract final class LennyTokens {
  // Neutrals
  static const ink = Color(0xFF07081A);
  static const page = Color(0xFF1A1D38);
  static const pageDot = Color(0xFF2C3060);
  static const surface = Color(0xFF262A4D);
  static const well = Color(0xFF0F1126);
  static const text = Color(0xFFF4F1E8);
  static const textMuted = Color(0xFFB7B9D6);
  static const textFaint = Color(0xFF9A9DC8);

  // Accents: one color = one meaning
  static const yellow = Color(0xFFFFD23F); // primary action, max one per view
  static const mint = Color(0xFF2EE6C5); // on / selected
  static const green = Color(0xFF4ADE80); // live status only
  static const coral = Color(0xFFFF6B6B); // stop / disconnected / error
  static const lilac = Color(0xFFA78BFA); // values & info, waiting

  // Shape
  static const border = 3.0;
  static const radiusCard = 20.0;
  static const radiusButton = 16.0;
  static const radiusInput = 14.0;
  static const radiusTile = 14.0;
  static const radiusChipSmall = 12.0;
  static const radiusPill = 999.0;

  // Shadow offsets (down-right, blur 0)
  static const shadowHero = 8.0;
  static const shadowCard = 6.0;
  static const shadowPrimary = 5.0;
  static const shadowButton = 4.0;
  static const shadowSmall = 3.0;

  // Type. ponytail: google_fonts downloads on first run and caches; offline first run falls back to the system
  // font. Bundle the TTFs under assets/google_fonts/ if that ever matters.
  static TextStyle wordmark(double size) => GoogleFonts.bricolageGrotesque(
        fontSize: size,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.02 * size,
        color: text,
        shadows: const [Shadow(color: ink, offset: Offset(3, 3))],
      );
  static TextStyle heading([double size = 24]) =>
      GoogleFonts.bricolageGrotesque(fontSize: size, fontWeight: FontWeight.w800, color: text);
  static TextStyle body({double size = 15, FontWeight weight = FontWeight.w500, Color color = text}) =>
      GoogleFonts.dmSans(fontSize: size, fontWeight: weight, color: color);
  static TextStyle button([Color color = text]) =>
      GoogleFonts.dmSans(fontSize: 17, fontWeight: FontWeight.w700, color: color);
  static TextStyle label() => GoogleFonts.jetBrainsMono(
      fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.96, color: textMuted);
  static TextStyle mono({double size = 15, FontWeight weight = FontWeight.w600, Color color = text}) =>
      GoogleFonts.jetBrainsMono(fontSize: size, fontWeight: weight, color: color);
}

ThemeData lennyTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: LennyTokens.page,
      textTheme: GoogleFonts.dmSansTextTheme(ThemeData.dark().textTheme)
          .apply(bodyColor: LennyTokens.text, displayColor: LennyTokens.text),
      colorScheme: const ColorScheme.dark(
        primary: LennyTokens.yellow,
        onPrimary: LennyTokens.ink,
        error: LennyTokens.coral,
        surface: LennyTokens.surface,
        onSurface: LennyTokens.text,
        outline: LennyTokens.ink,
      ),
      // Press feedback is the sticker sink, never a ripple.
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      textSelectionTheme: const TextSelectionThemeData(cursorColor: LennyTokens.yellow),
    );

/// The dotted page behind every screen (design.md §3.7).
class DotBackground extends StatelessWidget {
  const DotBackground({super.key, required this.child, this.spacing = 24});
  final Widget child;
  final double spacing;

  @override
  // The boundary keeps per-second stat updates from repainting the dots.
  Widget build(BuildContext context) => CustomPaint(painter: _Dots(spacing), child: RepaintBoundary(child: child));
}

class _Dots extends CustomPainter {
  _Dots(this.spacing);
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(LennyTokens.page, BlendMode.src);
    final p = Paint()..color = LennyTokens.pageDot;
    for (var y = spacing / 2; y < size.height; y += spacing) {
      for (var x = spacing / 2; x < size.width; x += spacing) {
        canvas.drawCircle(Offset(x, y), 1.6, p);
      }
    }
  }

  @override
  bool shouldRepaint(_Dots old) => old.spacing != spacing;
}
