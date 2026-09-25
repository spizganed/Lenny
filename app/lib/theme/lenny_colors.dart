import 'package:flutter/material.dart';

/// All app colors. The full sticker style (outline + hard shadow + press animation) lands in the M6 visual pass.
abstract final class LennyColors {
  static const background = Color(0xFF14162B);
  static const surface = Color(0xFF1F2240);
  static const outline = Color(0xFFB9B5CC);
  static const shadow = Color(0xFF0C0C18);
  static const primary = Color(0xFFFFD23F); // bright yellow: main action
  static const danger = Color(0xFFFF5C7A); // warm red/pink
  static const success = Color(0xFF3DDC97);
  static const info = Color(0xFF5CC8FF);
  static const text = Color(0xFFF2F0FA);
}

ThemeData lennyTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: LennyColors.background,
      colorScheme: const ColorScheme.dark(
        primary: LennyColors.primary,
        onPrimary: LennyColors.shadow,
        error: LennyColors.danger,
        surface: LennyColors.surface,
        onSurface: LennyColors.text,
        outline: LennyColors.outline,
      ),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );
