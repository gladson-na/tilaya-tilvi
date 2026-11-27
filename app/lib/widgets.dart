import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const kNavy = Color(0xFF0B1630);
const kCard = Color(0xFF14224A);
const kTeal = Color(0xFF2DD4BF);
const kBlue = Color(0xFF3B82F6);
const kOrange = Color(0xFFFB923C);
const kPink = Color(0xFFF472B6);

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

/// Tilda's face: a soft living blob of light, drawn flat in 2D. Its colour, speed and wobble glide smoothly
/// from one state to the next. Calm and teal when idle, blue and swelling with your voice while listening,
/// violet with small orbiting dots while thinking, warm orange pulsing while she speaks, a scan line while reading.
class TildaOrb extends StatefulWidget {
  final OrbState state;
  final double level; // 0..1 loudness, drives the swell while listening
  final double size;
  const TildaOrb({super.key, required this.state, this.level = 0, this.size = 190});

  @override
  State<TildaOrb> createState() => _TildaOrbState();
}

class _OrbLook {
  final Color a, b; // the two colours the blob blends between
  final double wobble, speed, glow;
  const _OrbLook(this.a, this.b, this.wobble, this.speed, this.glow);
}

const _looks = {
  OrbState.idle: _OrbLook(Color(0xFF2DD4BF), Color(0xFF3B82F6), 0.05, 0.35, 0.45),
  OrbState.listening: _OrbLook(Color(0xFF3B82F6), Color(0xFF22D3EE), 0.10, 0.9, 0.7),
  OrbState.thinking: _OrbLook(Color(0xFF8B5CF6), Color(0xFF3B82F6), 0.07, 1.3, 0.6),
  OrbState.speaking: _OrbLook(Color(0xFFFB923C), Color(0xFFF472B6), 0.12, 1.1, 0.75),
  OrbState.reading: _OrbLook(Color(0xFF2DD4BF), Color(0xFF38BDF8), 0.06, 0.7, 0.6),
};

class _TildaOrbState extends State<TildaOrb> with SingleTickerProviderStateMixin {
  late final Ticker _tick;
  final _frame = ValueNotifier<int>(0);
  Duration _last = Duration.zero;
  double _phase = 0; // moves faster or slower with the state, never jumps
  double _wobble = 0.05, _speed = 0.35, _glow = 0.45, _lvl = 0, _swing = 0;
  Color _a = _looks[OrbState.idle]!.a, _b = _looks[OrbState.idle]!.b;

  @override
  void initState() {
    super.initState();
    _tick = createTicker((e) {
      final dt = ((e - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
      _last = e;
      final to = _looks[widget.state]!;
      final k = 1 - math.exp(-dt * 5); // glide: about a fifth of a second to settle
      _a = Color.lerp(_a, to.a, k)!;
      _b = Color.lerp(_b, to.b, k)!;
      _wobble += (to.wobble - _wobble) * k;
      _speed += (to.speed - _speed) * k;
      _glow += (to.glow - _glow) * k;
      _lvl += ((widget.state == OrbState.listening ? (widget.level * 6).clamp(0.0, 1.0) : 0.0) - _lvl) * (1 - math.exp(-dt * 14));
      _phase += dt * _speed * 2 * math.pi;
      _swing = widget.state == OrbState.speaking ? 0.5 + 0.5 * math.sin(_phase * 3.2) : _swing * 0.9;
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
        height: widget.size,
        child: CustomPaint(painter: _OrbPainter(this, _frame)),
      );
}

class _OrbPainter extends CustomPainter {
  final _TildaOrbState o;
  _OrbPainter(this.o, Listenable repaint) : super(repaint: repaint);

  Path _blob(Offset c, double r, double amp, double ph, int k) {
    final p = Path();
    const n = 72;
    for (var i = 0; i <= n; i++) {
      final t = i / n * 2 * math.pi;
      final w = math.sin(t * k + ph) * 0.6 + math.sin(t * (k + 1) - ph * 1.3) * 0.4;
      final rr = r * (1 + amp * w);
      final pt = c + Offset(math.cos(t), math.sin(t)) * rr;
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    return p..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = size.width * 0.27;
    final st = o.widget.state;
    final breathe = 1 + 0.03 * math.sin(o._phase * 0.8);
    final r = base * breathe * (1 + 0.22 * o._lvl + 0.10 * o._swing);
    final amp = o._wobble + 0.10 * o._lvl + 0.05 * o._swing;
    final ph = o._phase;

    final haloR = r * 2.2;
    canvas.drawCircle(c, haloR, Paint()..shader = RadialGradient(colors: [o._a.withOpacity(0.38 * o._glow + 0.1), o._a.withOpacity(0)]).createShader(Rect.fromCircle(center: c, radius: haloR)));

    // three soft layers, each wobbling at its own pace
    canvas.drawPath(_blob(c, r * 1.08, amp * 1.2, ph * 0.8 + 1.0, 3), Paint()..color = o._b.withOpacity(0.38));
    canvas.drawPath(_blob(c, r * 1.02, amp, -ph * 1.1 + 2.0, 4), Paint()..color = o._a.withOpacity(0.55));
    final body = _blob(c, r, amp * 0.8, ph, 3);
    canvas.drawPath(
        body,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [o._b, o._a]).createShader(Rect.fromCircle(center: c, radius: r * 1.2)));
    // a small highlight gives it a gentle sheen without making it look like a glass ball
    canvas.drawCircle(c + Offset(-r * 0.32, -r * 0.36), r * 0.3, Paint()..shader = RadialGradient(colors: [Colors.white.withOpacity(0.55), Colors.white.withOpacity(0)]).createShader(Rect.fromCircle(center: c + Offset(-r * 0.32, -r * 0.36), radius: r * 0.3)));

    if (st == OrbState.thinking) {
      for (var i = 0; i < 3; i++) {
        final a = ph * (i.isEven ? 1.0 : -0.8) + i * 2.1;
        canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (r * (1.5 + 0.1 * i)), 4.5 - i, Paint()..color = Colors.white.withOpacity(0.9));
      }
    }
    if (st == OrbState.reading) {
      canvas.save();
      canvas.clipPath(body);
      final y = c.dy - r + (0.5 + 0.5 * math.sin(ph * 1.6)) * 2 * r;
      canvas.drawRect(Rect.fromLTWH(c.dx - r, y - 3, r * 2, 6), Paint()..color = Colors.white.withOpacity(0.65));
      canvas.restore();
    }
    if (st == OrbState.listening || st == OrbState.speaking) {
      for (var i = 0; i < 2; i++) {
        final p = ((ph / (2 * math.pi) * 0.6) + i / 2) % 1.0;
        canvas.drawCircle(c, r * (1.15 + 0.8 * p), Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..color = o._a.withOpacity(0.35 * (1 - p)));
      }
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => false;
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
