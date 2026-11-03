import 'package:flutter/material.dart';

// Sage design language (see design/tokens.md). Colors adapt to Light/Dark; spacing uses only Sp.*.
class Sp { static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0; }

class Sage extends ThemeExtension<Sage> {
  final Color bg, card, soft, line, text, muted, accent, onAccent, warn, warnBg, danger, dangerBg;
  const Sage({required this.bg, required this.card, required this.soft, required this.line, required this.text, required this.muted, required this.accent, required this.onAccent, required this.warn, required this.warnBg, required this.danger, required this.dangerBg});
  static const light = Sage(bg: Color(0xFFEEF2EC), card: Color(0xFFF8FAF6), soft: Color(0xFFDDE7DA), line: Color(0xFFD3DCCF), text: Color(0xFF2F3A33), muted: Color(0xFF5E6B61), accent: Color(0xFF4F7A5A), onAccent: Color(0xFFFFFFFF), warn: Color(0xFF7A5A12), warnBg: Color(0xFFF6EBD3), danger: Color(0xFF8A2F26), dangerBg: Color(0xFFF4DEDA));
  static const dark = Sage(bg: Color(0xFF151B17), card: Color(0xFF1D2520), soft: Color(0xFF24302A), line: Color(0xFF2E3A33), text: Color(0xFFE4EBE5), muted: Color(0xFF9BAB9F), accent: Color(0xFF8FBF9A), onAccent: Color(0xFF11201A), warn: Color(0xFFE5C57A), warnBg: Color(0xFF2B2616), danger: Color(0xFFE8A097), dangerBg: Color(0xFF2D1B19));
  @override Sage copyWith() => this;
  @override Sage lerp(ThemeExtension<Sage>? o, double t) => this;
}

extension SageX on BuildContext { Sage get sage => Theme.of(this).extension<Sage>()!; }

ThemeData sageTheme(Brightness b) {
  final s = b == Brightness.dark ? Sage.dark : Sage.light;
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  const label = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    fontFamily: 'Figtree',
    scaffoldBackgroundColor: s.bg,
    extensions: [s],
    colorScheme: ColorScheme(brightness: b, primary: s.accent, onPrimary: s.onAccent, secondary: s.accent, onSecondary: s.onAccent, error: s.danger, onError: s.dangerBg, surface: s.bg, onSurface: s.text, onSurfaceVariant: s.muted, outline: s.line, outlineVariant: s.line, surfaceContainerHighest: s.card, primaryContainer: s.soft, onPrimaryContainer: s.text, tertiaryContainer: s.warnBg, onTertiaryContainer: s.warn, errorContainer: s.dangerBg, onErrorContainer: s.danger),
    textTheme: ThemeData(brightness: b, fontFamily: 'Figtree').textTheme.apply(bodyColor: s.text, displayColor: s.text),
    appBarTheme: AppBarTheme(backgroundColor: s.bg, foregroundColor: s.text, elevation: 0, scrolledUnderElevation: 0, centerTitle: false, titleTextStyle: TextStyle(fontFamily: 'Figtree', fontSize: 20, fontWeight: FontWeight.w700, color: s.text)),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(64, 44), padding: const EdgeInsets.symmetric(horizontal: Sp.xl), shape: pill, textStyle: label)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(64, 44), padding: const EdgeInsets.symmetric(horizontal: Sp.xl), shape: pill, side: BorderSide(color: s.line), foregroundColor: s.text, textStyle: label)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(64, 44), shape: pill, foregroundColor: s.muted, textStyle: label)),
    dialogTheme: DialogThemeData(backgroundColor: s.card, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: s.line))),
    inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: s.bg, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: s.line)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: s.line))),
    dividerTheme: DividerThemeData(color: s.line, space: 1, thickness: 1),
    snackBarTheme: SnackBarThemeData(backgroundColor: s.card, contentTextStyle: TextStyle(color: s.text, fontFamily: 'Figtree'), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: s.line))),
  );
}

// ---- shared building blocks ----

class AppCard extends StatelessWidget {
  final Widget child;
  final bool tint;
  final VoidCallback? onTap;
  const AppCard({super.key, required this.child, this.tint = false, this.onTap});
  @override
  Widget build(BuildContext c) {
    final s = c.sage;
    return Material(
      color: tint ? s.soft : s.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: s.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(Sp.lg), child: SizedBox(width: double.infinity, child: child))),
    );
  }
}

// The one way status is shown everywhere: dot + word.
class StatusWord extends StatelessWidget {
  final String word;
  final Color color;
  const StatusWord(this.word, this.color, {super.key});
  @override
  Widget build(BuildContext c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: Sp.sm),
        Text(word, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
      ]);
}

class Logo extends StatelessWidget {
  final double size;
  const Logo({super.key, this.size = 32});
  @override
  Widget build(BuildContext c) => Container(
        width: size, height: size,
        decoration: BoxDecoration(color: c.sage.accent, borderRadius: BorderRadius.circular(size * .3)),
        child: Icon(Icons.nightlight_round, size: size * .55, color: c.sage.onAccent),
      );
}

class Caption extends StatelessWidget {
  final String text;
  const Caption(this.text, {super.key});
  @override
  Widget build(BuildContext c) => Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.sage.muted));
}

// A banner that sits above the terminal (approval needed, connection lost).
class Banner2 extends StatelessWidget {
  final Color bg, fg;
  final Widget? lead;
  final String text;
  final Widget? action;
  const Banner2({super.key, required this.bg, required this.fg, required this.text, this.lead, this.action});
  @override
  Widget build(BuildContext c) => Container(
        margin: const EdgeInsets.fromLTRB(Sp.md, Sp.sm, Sp.md, 0),
        padding: const EdgeInsets.all(Sp.md),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          if (lead != null) ...[lead!, const SizedBox(width: Sp.md)],
          Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w500))),
          if (action != null) ...[const SizedBox(width: Sp.md), action!],
        ]),
      );
}
