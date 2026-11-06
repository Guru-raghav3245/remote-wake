import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

// Terminal-bloom design language (see design/rose-style.html and design/tokens.md). Dark only, system monospace, spacing only from Sp.*.
class Sp { static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0; }

const mono = 'monospace';

class Sage extends ThemeExtension<Sage> {
  final Color bg, card, soft, line, text, muted, accent, onAccent, warn, warnBg, danger, dangerBg, pink, pinkBg, blue, screen;
  const Sage({required this.bg, required this.card, required this.soft, required this.line, required this.text, required this.muted, required this.accent, required this.onAccent, required this.warn, required this.warnBg, required this.danger, required this.dangerBg, required this.pink, required this.pinkBg, required this.blue, required this.screen});
  static const dark = Sage(
    bg: Color(0xFF0B0B0E), card: Color(0xFF121217), soft: Color(0xFF1A1A20), line: Color(0xFF23232B), text: Color(0xFFE8E8EC), muted: Color(0xFF6B6B78),
    accent: Color(0xFF7BE0B0), onAccent: Color(0xFF06130D), warn: Color(0xFFE3B341), warnBg: Color(0xFF2B251C), danger: Color(0xFFE5484D), dangerBg: Color(0xFF2B181D),
    pink: Color(0xFFFF6AC1), pinkBg: Color(0xFF2B1826), blue: Color(0xFF6CB6FF), screen: Color(0xFF050507));
  @override Sage copyWith() => this;
  @override Sage lerp(ThemeExtension<Sage>? o, double t) => this;
}

extension SageX on BuildContext { Sage get sage => Theme.of(this).extension<Sage>()!; }

ThemeData sageTheme() {
  final s = Sage.dark;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  const label = TextStyle(fontFamily: mono, fontSize: 14, fontWeight: FontWeight.w700);
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: mono,
    scaffoldBackgroundColor: s.bg,
    extensions: [s],
    colorScheme: ColorScheme(brightness: Brightness.dark, primary: s.accent, onPrimary: s.onAccent, secondary: s.accent, onSecondary: s.onAccent, error: s.danger, onError: s.dangerBg, surface: s.bg, onSurface: s.text, onSurfaceVariant: s.muted, outline: s.line, outlineVariant: s.line, surfaceContainerHighest: s.card, primaryContainer: s.soft, onPrimaryContainer: s.text, tertiaryContainer: s.warnBg, onTertiaryContainer: s.warn, errorContainer: s.dangerBg, onErrorContainer: s.danger),
    textTheme: ThemeData(brightness: Brightness.dark, fontFamily: mono).textTheme.apply(bodyColor: s.text, displayColor: s.text, fontFamily: mono),
    appBarTheme: AppBarTheme(backgroundColor: s.bg, foregroundColor: s.text, elevation: 0, scrolledUnderElevation: 0, centerTitle: false, titleTextStyle: TextStyle(fontFamily: mono, fontSize: 18, fontWeight: FontWeight.w700, color: s.text)),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(64, 44), padding: const EdgeInsets.symmetric(horizontal: Sp.lg), shape: shape, textStyle: label)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(64, 44), padding: const EdgeInsets.symmetric(horizontal: Sp.lg), shape: shape, side: BorderSide(color: s.line), foregroundColor: s.text, textStyle: label)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(64, 44), shape: shape, foregroundColor: s.muted, textStyle: label)),
    dialogTheme: DialogThemeData(backgroundColor: s.card, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: s.line))),
    inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: const Color(0xFF16161C), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: s.line)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: s.line)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: s.accent, width: 2))),
    dividerTheme: DividerThemeData(color: s.line, space: 1, thickness: 1),
    snackBarTheme: SnackBarThemeData(backgroundColor: s.card, contentTextStyle: TextStyle(color: s.text, fontFamily: mono), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: s.line))),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: s.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(Sp.lg), child: SizedBox(width: double.infinity, child: child))),
    );
  }
}

// The one way status is shown everywhere: a glowing dot + a word.
class StatusWord extends StatelessWidget {
  final String word;
  final Color color;
  final bool dot; // false: the word alone, no glowing dot before it
  const StatusWord(this.word, this.color, {super.key, this.dot = true});
  @override
  // a state change fades the word and eases the dot's colour instead of snapping
  Widget build(BuildContext c) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot) ...[
          AnimatedContainer(duration: const Duration(milliseconds: 350), width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: color.withValues(alpha: .7), blurRadius: 8)])),
          const SizedBox(width: Sp.sm),
        ],
        AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: Text(word, key: ValueKey(word), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color))),
      ]);
}

class Logo extends StatelessWidget {
  final double size;
  const Logo({super.key, this.size = 32});
  @override
  Widget build(BuildContext c) => DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(size * .2237), border: Border.all(color: c.sage.line)), child: ClipRRect(borderRadius: BorderRadius.circular(size * .2237), child: Image.asset('assets/icon.png', width: size, height: size, filterQuality: FilterQuality.medium, semanticLabel: 'Remote Wake')));
}

class Caption extends StatelessWidget {
  final String text;
  const Caption(this.text, {super.key});
  @override
  Widget build(BuildContext c) => Text(text.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1, color: c.sage.muted));
}

// A banner that sits above the terminal (approval needed, connection lost).
class Banner2 extends StatelessWidget {
  final Color bg, fg;
  final Widget? lead;
  final String text;
  final Widget? action;
  final String? hint; // small second line, e.g. how to dismiss the banner
  const Banner2({super.key, required this.bg, required this.fg, required this.text, this.lead, this.action, this.hint});
  @override
  Widget build(BuildContext c) => Container(
        margin: const EdgeInsets.fromLTRB(Sp.md, Sp.sm, Sp.md, 0),
        padding: const EdgeInsets.all(Sp.md),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          if (lead != null) ...[lead!, const SizedBox(width: Sp.md)],
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600, height: 1.4)),
            if (hint != null) Padding(padding: const EdgeInsets.only(top: Sp.xs), child: Text(hint!, style: TextStyle(color: fg.withValues(alpha: .65), fontSize: 11, height: 1.3))),
          ])),
          if (action != null) ...[const SizedBox(width: Sp.md), action!],
        ]),
      );
}

// ---- ASCII pieces ----

const _ramp = ' .:-=+*#%@';

// Calls [tick] with elapsed seconds at ~10 fps while [active] and the user has not asked for reduced motion.
mixin _Anim<T extends StatefulWidget> on State<T> {
  Ticker? _tk;
  double secs = 0;
  bool get animate;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tk?.dispose(); _tk = null;
    if (animate && !MediaQuery.of(context).disableAnimations) {
      var last = -1.0;
      _tk = Ticker((d) { final t = d.inMilliseconds / 1000; if (t - last >= .1) { last = t; setState(() => secs = t); } })..start();
    }
  }
  @override
  void dispose() { _tk?.dispose(); super.dispose(); }
}

// Primary action: a frame of shaded characters (rippling while an action is expected), bold label inside.
class AsciiButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  const AsciiButton(this.label, {super.key, required this.onPressed, this.primary = true});
  @override
  State<AsciiButton> createState() => _AsciiButtonState();
}

class _AsciiButtonState extends State<AsciiButton> with _Anim<AsciiButton> {
  @override
  bool get animate => widget.primary && widget.onPressed != null;
  @override
  void didUpdateWidget(AsciiButton o) { super.didUpdateWidget(o); if (o.primary != widget.primary || (o.onPressed == null) != (widget.onPressed == null)) didChangeDependencies(); }

  @override
  Widget build(BuildContext c) {
    final s = c.sage, on = animate;
    final w = widget.label.length + 4;
    final edge = on ? List.generate(w, (i) => _ramp[(4 + (.5 + .5 * math.sin(i * .5 - secs * 3)) * 5).floor().clamp(0, 9)]).join() : '-' * w;
    final color = widget.onPressed == null ? s.muted.withValues(alpha: .5) : (widget.primary ? s.accent : s.muted);
    return Semantics(
      button: true, label: widget.label, excludeSemantics: true,
      child: Material(
        color: widget.primary && on ? s.accent.withValues(alpha: .1) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: widget.onPressed,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: Sp.sm, vertical: Sp.sm),
            child: Text('+$edge+\n|  ${widget.label}  |\n+$edge+', softWrap: false,
                style: TextStyle(fontFamily: mono, fontSize: 14, height: 1.15, fontWeight: FontWeight.w700, color: color, shadows: on ? [Shadow(color: s.accent.withValues(alpha: .6), blurRadius: 10)] : null)),
          ),
        ),
      ),
    );
  }
}

enum LaptopMode { on, off, idle }

// 28 columns, every row exactly 28 characters, mirror-symmetric (checked by assert).
class AsciiLaptop extends StatefulWidget {
  final LaptopMode mode;
  const AsciiLaptop(this.mode, {super.key});
  static const cols = 28;
  static String pad(String t) { final n = cols - t.length, l = n >> 1; return ' ' * l + t + ' ' * (n - l); }
  static final rows = [
    pad('.${'-' * 22}.'),
    ...List.filled(5, pad('|${'#' * 22}|')),
    pad("'${'-' * 22}'"),
    ".-'${'-' * 22}'-.",
    "'${'-' * 26}'",
  ];
  @override
  State<AsciiLaptop> createState() => _AsciiLaptopState();
}

class _AsciiLaptopState extends State<AsciiLaptop> with _Anim<AsciiLaptop> {
  @override
  bool get animate => widget.mode == LaptopMode.on;
  @override
  void didUpdateWidget(AsciiLaptop o) { super.didUpdateWidget(o); if (o.mode != widget.mode) didChangeDependencies(); }

  @override
  Widget build(BuildContext c) {
    assert(AsciiLaptop.rows.every((r) => r.length == AsciiLaptop.cols));
    final s = c.sage;
    final col = switch (widget.mode) { LaptopMode.on => s.accent, LaptopMode.off => s.danger, LaptopMode.idle => s.muted };
    final spans = <InlineSpan>[];
    for (var r = 0; r < AsciiLaptop.rows.length; r++) {
      final row = AsciiLaptop.rows[r];
      for (var i = 0; i < row.length; i++) {
        var ch = row[i], a = .6;
        if (ch == '#') {
          if (widget.mode == LaptopMode.on) { final b = .5 + .5 * math.sin(i * .45 - secs * 2.2 + r * .7); ch = _ramp[(3 + b * 6).floor()]; a = .35 + b * .65; }
          else if (widget.mode == LaptopMode.off) { ch = (i * 7 + r * 13) % 29 == 0 ? 'z' : ' '; a = .8; }
          else { ch = (i + r) % 6 == 0 ? '.' : ' '; a = .5; }
        }
        spans.add(TextSpan(text: ch, style: TextStyle(color: col.withValues(alpha: a))));
      }
      if (r < AsciiLaptop.rows.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return Semantics(
      label: switch (widget.mode) { LaptopMode.on => 'Mac online', LaptopMode.off => 'Mac asleep', LaptopMode.idle => 'No Mac' }, excludeSemantics: true,
      child: Center(child: Text.rich(TextSpan(children: spans), softWrap: false, style: const TextStyle(fontFamily: mono, fontSize: 13, height: 1.15))),
    );
  }
}
