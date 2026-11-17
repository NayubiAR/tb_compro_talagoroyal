import 'package:flutter/material.dart';

class Brand {
  static const navy = Color(0xFF1F2A5A);
  static const gold = Color(0xFFC9A227);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.navy,
    brightness: brightness,
    primary: dark ? const Color(0xFFB9C3FF) : Brand.navy,
    secondary: Brand.gold,
    surface: dark ? const Color(0xFF14161C) : const Color(0xFFFAFAF8),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF0F1115) : const Color(0xFFF3F4F7),
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingTextStyle: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant, fontSize: 13),
      dataRowMinHeight: 44,
      dataRowMaxHeight: 64,
      horizontalMargin: 16,
      columnSpacing: 20,
    ),
    dialogTheme: const DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, width: 420),
  );
}

/// Warna status (dipakai chip & indikator) — selalu disertai ikon + label, tidak warna saja.
enum Tone { good, info, warning, serious, critical, neutral }

Color toneColor(BuildContext context, Tone tone) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (tone) {
    case Tone.good:
      return dark ? const Color(0xFF5CC46A) : const Color(0xFF2E7D32);
    case Tone.info:
      return dark ? const Color(0xFF7FA8F5) : const Color(0xFF1F5FBF);
    case Tone.warning:
      return dark ? const Color(0xFFE8B931) : const Color(0xFF946200);
    case Tone.serious:
      return dark ? const Color(0xFFF08A4B) : const Color(0xFFC2410C);
    case Tone.critical:
      return dark ? const Color(0xFFF07070) : const Color(0xFFB91C1C);
    case Tone.neutral:
      return dark ? const Color(0xFFA1A1AA) : const Color(0xFF5B5B66);
  }
}

/// Palet kategorikal tervalidasi (slot 1–3) untuk kanal pendapatan.
/// Urutan tetap: Eceran, B2B, Cetak — warna mengikuti entitas, bukan peringkat.
class ChartPalette {
  static List<Color> series(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const [Color(0xFF3987E5), Color(0xFFD95926), Color(0xFF199E70)]
        : const [Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A)];
  }

  static Color sequential(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? const Color(0xFF3987E5) : const Color(0xFF2A78D6);
}
