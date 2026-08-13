import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// Typography helpers. IBM Plex Sans carries the UI; IBM Plex Mono is reserved
/// for bus numbers, site codes, user IDs, times and numeric values.
abstract final class AppText {
  static TextStyle sans({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color color = T.ink,
    double? height,
    double? letterSpacing,
    TextDecoration? decoration,
  }) {
    return GoogleFonts.ibmPlexSans(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
      decoration: decoration,
    );
  }

  static TextStyle mono({
    double size = 14,
    FontWeight weight = FontWeight.w600,
    Color color = T.ink,
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.ibmPlexMono(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  // Named roles from the handoff's type scale.
  static TextStyle get pageTitle => sans(size: 22, weight: FontWeight.w700);
  static TextStyle get sectionTitle => sans(size: 16, weight: FontWeight.w700);
  static TextStyle get cardTitle =>
      sans(size: 15.5, weight: FontWeight.w700, height: 1.25);
  static TextStyle get bodyText => sans(size: 14, color: T.body, height: 1.45);
  static TextStyle get label =>
      sans(size: 13, weight: FontWeight.w600, color: T.body);
  static TextStyle get meta => sans(size: 12.5, color: T.muted);
  static TextStyle get input => sans(size: 16);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: T.green,
      primary: T.green,
      onPrimary: T.white,
      surface: T.card,
      onSurface: T.ink,
      error: T.red,
      onError: T.white,
    ),
    scaffoldBackgroundColor: T.pageBg,
  );

  return base.copyWith(
    textTheme: GoogleFonts.ibmPlexSansTextTheme(base.textTheme).apply(
      bodyColor: T.ink,
      displayColor: T.ink,
    ),
    splashFactory: InkRipple.splashFactory,
    // Surfaces are drawn with a 1px border rather than elevation throughout,
    // so no Material Card theming is needed.
    dividerTheme: const DividerThemeData(
      color: T.border,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: T.card,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: AppText.sans(size: 16, color: T.muted),
      border: _fieldBorder(T.inputBorder),
      enabledBorder: _fieldBorder(T.inputBorder),
      // Focus state: green border, with the 3px ring painted by [FocusRing].
      focusedBorder: _fieldBorder(T.green),
      errorBorder: _fieldBorder(T.red),
      focusedErrorBorder: _fieldBorder(T.red),
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: T.card,
      headerBackgroundColor: T.green,
      headerForegroundColor: T.white,
      shape: const RoundedRectangleBorder(borderRadius: T.cardShape),
      todayForegroundColor: WidgetStateProperty.all(T.green),
    ),
    timePickerTheme: const TimePickerThemeData(
      backgroundColor: T.card,
      shape: RoundedRectangleBorder(borderRadius: T.cardShape),
      dialHandColor: T.green,
      hourMinuteTextColor: T.ink,
    ),
  );
}

OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
      borderRadius: T.controlShape,
      borderSide: BorderSide(color: color, width: 1.5),
    );
