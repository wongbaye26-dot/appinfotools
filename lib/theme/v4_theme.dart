import 'package:flutter/material.dart';

/// V4 "Paper & Signal" design tokens.
///
/// These are UI-only values. They intentionally do not encode parser, report,
/// or security semantics; pages remain responsible for their own meaning.
abstract final class V4Colors {
  static const paper = Color(0xFFF4F2EE);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFF9F7F3);
  static const surface3 = Color(0xFFF5F3EF);
  static const surface4 = Color(0xFFEAE7E1);

  static const ink = Color(0xFF16151B);
  static const ink2 = Color(0xFF57535F);
  static const ink3 = Color(0xFF8E8A97);
  static const line = Color(0xFFE5E1D8);

  static const violet = Color(0xFF6A57F2);
  static const blue = Color(0xFF2F8FE0);
  static const mint = Color(0xFF119C72);
  static const amber = Color(0xFFD6731E);
  static const danger = Color(0xFFD93A55);

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF7B61FF), Color(0xFF3D8BFF), Color(0xFF1FB89A)],
    stops: [0, 0.55, 1],
  );

  static const darkPaper = Color(0xFF0D0F13);
  static const darkSurface = Color(0xFF15181E);
  static const darkSurface2 = Color(0xFF1A1E25);
  static const darkSurface3 = Color(0xFF20252D);
  static const darkLine = Color(0xFF2D333C);
  static const darkInk = Color(0xFFF1EEE8);
  static const darkInk2 = Color(0xFFB9B4AC);
  static const darkInk3 = Color(0xFF85808A);
}

abstract final class V4Radius {
  static const card = 20.0;
  static const panel = 22.0;
  static const button = 12.0;
  static const chip = 999.0;
  static const field = 12.0;
}

abstract final class V4Spacing {
  static const page = 24.0;
  static const section = 20.0;
  static const card = 18.0;
}

/// Builds the V4 Material theme.
///
/// The user's chosen seed colour remains the primary accent, while the paper,
/// panel, line, and typography tokens stay fixed. This preserves the existing
/// theme-colour setting instead of silently turning it into a no-op.
ThemeData buildV4Theme({
  required Color seed,
  required Brightness brightness,
  String? fontFamily,
}) {
  final dark = brightness == Brightness.dark;
  final seeded = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );

  final scheme = seeded.copyWith(
    primary: dark ? const Color(0xFFB9A8FF) : seed,
    onPrimary: dark ? const Color(0xFF1B1235) : Colors.white,
    primaryContainer: dark ? const Color(0xFF33295C) : const Color(0xFFEDE9FF),
    onPrimaryContainer:
        dark ? const Color(0xFFEDE9FF) : const Color(0xFF2B1B66),
    secondary: dark ? const Color(0xFF8FC4FF) : V4Colors.blue,
    onSecondary: dark ? const Color(0xFF062744) : Colors.white,
    secondaryContainer:
        dark ? const Color(0xFF1D3446) : const Color(0xFFE7F2FF),
    onSecondaryContainer:
        dark ? const Color(0xFFD7EBFF) : const Color(0xFF0B365A),
    tertiary: dark ? const Color(0xFF5EE0B0) : V4Colors.mint,
    onTertiary: dark ? const Color(0xFF00281A) : Colors.white,
    tertiaryContainer: dark ? const Color(0xFF123A2E) : const Color(0xFFDFF8EE),
    onTertiaryContainer:
        dark ? const Color(0xFFC6F7E3) : const Color(0xFF064D37),
    error: dark ? const Color(0xFFFFB4C0) : V4Colors.danger,
    onError: dark ? const Color(0xFF3D0010) : Colors.white,
    errorContainer: dark ? const Color(0xFF4A1620) : const Color(0xFFFFE8EC),
    onErrorContainer: dark ? const Color(0xFFFFD9DF) : const Color(0xFF5E0018),
    surface: dark ? V4Colors.darkSurface : V4Colors.surface,
    onSurface: dark ? V4Colors.darkInk : V4Colors.ink,
    surfaceContainerLowest: dark ? const Color(0xFF0A0C10) : V4Colors.surface,
    surfaceContainerLow: dark ? V4Colors.darkSurface : V4Colors.surface2,
    surfaceContainer: dark ? V4Colors.darkSurface2 : V4Colors.surface3,
    surfaceContainerHigh: dark ? V4Colors.darkSurface3 : V4Colors.surface4,
    surfaceContainerHighest: dark ? const Color(0xFF262C35) : V4Colors.surface4,
    onSurfaceVariant: dark ? V4Colors.darkInk2 : V4Colors.ink2,
    outline: dark ? V4Colors.darkLine : const Color(0xFFD8D3C9),
    outlineVariant: dark ? V4Colors.darkLine : V4Colors.line,
    shadow: dark ? Colors.black : V4Colors.ink,
    scrim: Colors.black,
    inverseSurface: dark ? V4Colors.ink : const Color(0xFF232129),
    onInverseSurface: dark ? V4Colors.ink : const Color(0xFFF8F6F1),
  );

  final base = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: dark ? V4Colors.darkPaper : V4Colors.paper,
    canvasColor: dark ? V4Colors.darkPaper : V4Colors.paper,
    dividerColor: dark ? V4Colors.darkLine : V4Colors.line,
    splashFactory: InkSparkle.splashFactory,
  );

  final textTheme = base.textTheme.copyWith(
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontSize: 30,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.0,
      height: 1.08,
      color: scheme.onSurface,
    ),
    headlineMedium: base.textTheme.headlineMedium?.copyWith(
      fontSize: 36,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.4,
      height: 1.03,
      color: scheme.onSurface,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      color: scheme.onSurface,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.15,
      color: scheme.onSurface,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
      color: scheme.onSurface,
    ),
    bodyLarge: base.textTheme.bodyLarge?.copyWith(
      fontSize: 14,
      height: 1.55,
      color: scheme.onSurface,
    ),
    bodyMedium: base.textTheme.bodyMedium?.copyWith(
      fontSize: 12.5,
      height: 1.5,
      color: scheme.onSurfaceVariant,
    ),
    bodySmall: base.textTheme.bodySmall?.copyWith(
      fontSize: 11.5,
      height: 1.45,
      color: scheme.onSurfaceVariant,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.1,
    ),
    labelMedium: base.textTheme.labelMedium?.copyWith(
      fontSize: 10.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
    labelSmall: base.textTheme.labelSmall?.copyWith(
      fontSize: 9.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.25,
    ),
  );

  return base.copyWith(
    textTheme: textTheme,
    cardTheme: CardThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      // 卡片之间统一的垂直节奏。以前是零外边距，而各 Tab 的卡片列表又没有
      // 分隔条 —— 两张卡直接贴在一起，边框叠成一条，看起来像一块坏掉的表格。
      // 间距放在主题里，新加的卡片不用再记得手写 `SizedBox`。
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(V4Radius.card),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.button),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        backgroundColor: scheme.surface.withValues(alpha: 0.6),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(V4Radius.button),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: textTheme.labelMedium,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        highlightColor: scheme.primary.withValues(alpha: 0.10),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      hintStyle: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(V4Radius.field),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(V4Radius.field),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(V4Radius.field),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : scheme.onSurfaceVariant,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.surfaceContainerHighest,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : scheme.outlineVariant,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary.withValues(alpha: 0.10)
              : scheme.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
        textStyle: WidgetStatePropertyAll(textTheme.labelMedium),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(V4Radius.panel),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2A3039) : V4Colors.ink,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(99),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurface.withValues(alpha: 0.16),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2A3039) : V4Colors.ink,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: textTheme.bodySmall?.copyWith(color: Colors.white),
      waitDuration: const Duration(milliseconds: 450),
    ),
  );
}
