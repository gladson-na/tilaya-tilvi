import 'dart:math' as math;

import 'package:flutter/material.dart';

const kNavy = Color(0xFF0B1630);
const kCard = Color(0xFF14224A);
const kTeal = Color(0xFF2DD4BF);
const kBlue = Color(0xFF3B82F6);
const kOrange = Color(0xFFFB923C);

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

/// Tilda's face: a glowing ball that moves differently for each thing she is doing.
/// Blue and pulsing with your voice while listening, orange while she speaks,
/// scanning lines while reading, and circling dots while thinking.
class TildaOrb extends StatefulWidget {
  final OrbState state;
  final double level; // 0..1 loudness, drives the pulse while listening
  final double size;
  const TildaOrb({super.key, required this.state, this.level = 0, this.size = 190});

  @override
  State<TildaOrb> createState() => _TildaOrbState();
}

class _TildaOrbState extends State<TildaOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(painter: _OrbPainter(widget.state, _c.value, widget.level)),
        ),
      );
}

class _OrbPainter extends CustomPainter {
  final OrbState s;
  final double t; // 0..1 looping
  final double level;
  _OrbPainter(this.s, this.t, this.level);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = size.width * 0.28;
    final wave = math.sin(t * 2 * math.pi);
    final speakPulse = s == OrbState.speaking ? 0.5 + 0.5 * math.sin(t * 2 * math.pi * 3) : 0.0;
    final voice = s == OrbState.listening ? (level * 6).clamp(0.0, 1.0) : 0.0;
    final idleBreath = 0.04 * wave;
    final r = base * (1 + idleBreath + 0.28 * voice + 0.14 * speakPulse);
    final warm = s == OrbState.speaking;
    final main = warm ? kOrange : (s == OrbState.idle ? kTeal : kBlue);
    final edge = warm ? const Color(0xFFEA580C) : (s == OrbState.idle ? const Color(0xFF0F9D8E) : const Color(0xFF2563EB));

    // soft halo
    final haloR = r * (1.9 + 0.25 * voice + 0.2 * speakPulse);
    canvas.drawCircle(
        c,
        haloR,
        Paint()
          ..shader = RadialGradient(colors: [main.withOpacity(0.45), main.withOpacity(0.0)]).createShader(Rect.fromCircle(center: c, radius: haloR)));

    // rings that drift outwards
    if (s == OrbState.listening || s == OrbState.speaking) {
      for (var i = 0; i < 3; i++) {
        final p = (t + i / 3) % 1.0;
        canvas.drawCircle(
            c,
            r * (1.1 + 0.9 * p),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = main.withOpacity(0.5 * (1 - p)));
      }
    }

    // the ball
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.35),
            colors: [Colors.white.withOpacity(0.9), main, edge],
            stops: const [0.0, 0.45, 1.0],
          ).createShader(Rect.fromCircle(center: c, radius: r)));

    if (s == OrbState.thinking) {
      for (var i = 0; i < 3; i++) {
        final a = t * 2 * math.pi * (i.isEven ? 1 : -1) + i * 2.1;
        final rr = r * (1.35 + 0.12 * i);
        canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * rr, 5.5 - i, Paint()..color = Colors.white.withOpacity(0.9));
      }
    }
    if (s == OrbState.reading) {
      canvas.save();
      canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
      final y = c.dy - r + (t * 2 * r);
      canvas.drawRect(Rect.fromLTWH(c.dx - r, y - 4, r * 2, 8), Paint()..color = Colors.white.withOpacity(0.7));
      for (var i = -2; i <= 2; i++) {
        canvas.drawRect(Rect.fromLTWH(c.dx - r * 0.55, c.dy + i * r * 0.28, r * 1.1, 3), Paint()..color = Colors.white.withOpacity(0.35));
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_OrbPainter o) => true;
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
                  final c1 = widget.quiet ? Colors.grey : kBlue;
                  final c2 = widget.quiet ? Colors.blueGrey : kTeal;
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
