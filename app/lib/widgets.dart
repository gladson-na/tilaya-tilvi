import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

// Tilda's look: calm and light, one deep teal, soft mint cards, large plain text.
const kBg = Color(0xFFF6FAF8); // page
const kInk = Color(0xFF13211D); // text
const kSub = Color(0xFF55665F); // secondary text
const kPrimary = Color(0xFF0B6B5A); // buttons, the one accent
const kMint = Color(0xFFE1F3EC); // cards
const kLine = Color(0xFFCFE0D9); // thin borders
const kPeach = Color(0xFFFCE6DC); // "the other person" in Translate
const kDark = Color(0xFF0E1A17); // the camera screen only
// older names, kept so every screen picks up the new look
const kNavy = kBg;
const kCard = kMint;
const kTeal = kPrimary;
const kBlue = kPrimary;
const kOrange = Color(0xFFC96A3F);
const kPink = kPrimary;

ThemeData tildaTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kPrimary, brightness: Brightness.light).copyWith(
    primary: kPrimary,
    onPrimary: Colors.white,
    surface: kBg,
    onSurface: kInk,
    surfaceContainerHighest: kMint,
    outline: kLine,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    canvasColor: kBg,
    appBarTheme: const AppBarTheme(
        backgroundColor: kBg, foregroundColor: kInk, elevation: 0, scrolledUnderElevation: 0, centerTitle: false,
        titleTextStyle: TextStyle(color: kInk, fontSize: 22, fontWeight: FontWeight.w700)),
    textTheme: ThemeData.light().textTheme.apply(bodyColor: kInk, displayColor: kInk),
    filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
            backgroundColor: kPrimary, foregroundColor: Colors.white, minimumSize: const Size(64, 54),
            shape: const StadiumBorder(), textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
    outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
            foregroundColor: kPrimary, side: const BorderSide(color: kLine), minimumSize: const Size(64, 50), shape: const StadiumBorder())),
    chipTheme: ChipThemeData(
        backgroundColor: kMint, selectedColor: kPrimary, side: BorderSide.none, shape: const StadiumBorder(),
        labelStyle: const TextStyle(color: kInk, fontSize: 16), secondaryLabelStyle: const TextStyle(color: Colors.white),
        checkmarkColor: Colors.white),
    switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : kSub),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? kPrimary : kLine)),
    dividerTheme: const DividerThemeData(color: kLine, space: 1),
    inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: kMint, hintStyle: const TextStyle(color: kSub),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)),
  );
}

/// A soft mint card. Every list row and panel in the app uses this, so the screens feel like one thing.
class TildaCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final VoidCallback? onTap;
  const TildaCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color = kMint, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

enum OrbState { idle, listening, reading, thinking, speaking }

String orbLabel(OrbState s) {
  switch (s) {
    case OrbState.listening:
      return 'Listening';
    case OrbState.reading:
      return 'Reading';
    case OrbState.thinking:
      return 'Thinking';
    case OrbState.speaking:
      return 'Speaking';
    case OrbState.idle:
      return 'Tap the mic and talk';
  }
}

/// Tilda's voice shown as a few teal bars: still and low when idle, moving with your voice while listening,
/// a quick ripple while thinking, a steady pulse while she speaks. (Kept under its old name so every screen uses it.)
class TildaOrb extends StatefulWidget {
  final OrbState state;
  final double level; // 0..1 loudness, drives the bars while listening
  final double size;
  const TildaOrb({super.key, required this.state, this.level = 0, this.size = 190});

  @override
  State<TildaOrb> createState() => _TildaOrbState();
}

class _TildaOrbState extends State<TildaOrb> with SingleTickerProviderStateMixin {
  late final Ticker _tick;
  final _frame = ValueNotifier<int>(0);
  Duration _last = Duration.zero;
  double _phase = 0, _amp = 0.18, _speed = 0.6, _lvl = 0;

  @override
  void initState() {
    super.initState();
    _tick = createTicker((e) {
      final dt = ((e - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
      _last = e;
      final st = widget.state;
      final ampTo = switch (st) { OrbState.idle => 0.16, OrbState.listening => 0.3, OrbState.thinking => 0.38, OrbState.speaking => 0.62, OrbState.reading => 0.34 };
      final spTo = switch (st) { OrbState.idle => 0.5, OrbState.listening => 1.4, OrbState.thinking => 2.6, OrbState.speaking => 1.9, OrbState.reading => 1.2 };
      final k = 1 - math.exp(-dt * 5);
      _amp += (ampTo - _amp) * k;
      _speed += (spTo - _speed) * k;
      _lvl += ((st == OrbState.listening ? (widget.level * 6).clamp(0.0, 1.0) : 0.0) - _lvl) * (1 - math.exp(-dt * 14));
      _phase += dt * _speed * 2 * math.pi;
      _frame.value++;
    })..start();
  }

  @override
  void dispose() {
    _tick.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size * 0.55,
        child: CustomPaint(painter: _BarsPainter(this, _frame)),
      );
}

class _BarsPainter extends CustomPainter {
  final _TildaOrbState o;
  _BarsPainter(this.o, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    const n = 11;
    final gap = size.width / n;
    final w = gap * 0.42;
    final active = o.widget.state != OrbState.idle;
    for (var i = 0; i < n; i++) {
      final edge = 1 - ((i - (n - 1) / 2).abs() / ((n - 1) / 2)) * 0.55; // the middle bars are the tallest
      final wave = 0.5 + 0.5 * math.sin(o._phase + i * 0.7);
      final h = size.height * (0.14 + (o._amp + 0.5 * o._lvl) * wave * edge).clamp(0.12, 1.0);
      final x = gap * (i + 0.5);
      final paint = Paint()
        ..color = (active ? kPrimary : kPrimary.withOpacity(0.55))
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, size.height / 2 - h / 2), Offset(x, size.height / 2 + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => false;
}

/// A glow that breathes along the screen edges. Blue while recording, grey when nothing is heard.
class GlowFrame extends StatefulWidget {
  final bool on;
  final bool quiet;
  final Widget child;
  const GlowFrame({super.key, required this.on, required this.child, this.quiet = false});

  @override
  State<GlowFrame> createState() => _GlowFrameState();
}

class _GlowFrameState extends State<GlowFrame> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        widget.child,
        if (widget.on)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, __) {
                  final a = widget.quiet ? 0.18 : 0.30 + 0.30 * _c.value;
                  final c1 = widget.quiet ? Colors.grey : kPrimary;
                  final c2 = widget.quiet ? Colors.blueGrey : const Color(0xFF3FB59D);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 1.05,
                        center: Alignment(0.6 * (_c.value - 0.5), 0.0),
                        colors: [Colors.transparent, Colors.transparent, c2.withOpacity(a * 0.6), c1.withOpacity(a)],
                        stops: const [0.0, 0.62, 0.84, 1.0],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ]);
}
