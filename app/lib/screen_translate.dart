import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'api.dart';
import 'personal_style.dart';
import 'widgets.dart';

/// Two people, two languages. The other person's side is at the top, turned around so they can
/// read it; yours is at the bottom. Hold your button, speak, let go: the phone says it in their language.
class TranslateScreen extends StatefulWidget {
  final PersonalStyle style;
  const TranslateScreen({super.key, required this.style});

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> {
  final _mic = Mic();
  final _player = AudioPlayer();
  final _tts = FlutterTts();
  late String _me;
  String _other = 'en-IN';
  String _meHeard = '', _otherHeard = ''; // what each person said, in their own language
  String _toMe = '', _toOther = ''; // what each person should read
  bool _recMe = false, _recOther = false, _busy = false;
  String _status = '';
  int _downAt = 0;
  bool _ttsDown = false;
  bool _buds = false; // earbud mode: my side plays in the right ear, the other person's in the left

  @override
  void initState() {
    super.initState();
    final mine = widget.style.myLangs;
    _me = mine.isNotEmpty ? mine.first : 'hi-IN';
    if (_me == _other) _other = 'hi-IN';
    _tts.awaitSpeakCompletion(true);
    unawaited(Api.wake());
  }

  @override
  void dispose() {
    _mic.dispose();
    _player.dispose();
    _tts.stop();
    super.dispose();
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  Future<void> _down(bool me) async {
    if (_busy || _mic.on) return;
    _downAt = DateTime.now().millisecondsSinceEpoch;
    final ok = await _mic.start((_) {});
    if (!ok) {
      _set(() => _status = 'Allow the microphone.');
      return;
    }
    _set(() {
      _recMe = me;
      _recOther = !me;
      _status = '';
    });
  }

  Future<void> _up(bool me) async {
    if (!_mic.on) return;
    final held = DateTime.now().millisecondsSinceEpoch - _downAt;
    final wav = await _mic.stop();
    _set(() {
      _recMe = false;
      _recOther = false;
    });
    if (held < 600 || wav.length < 600) {
      _set(() => _status = 'Keep holding while you speak.');
      return;
    }
    await _process(me, wav);
  }

  Future<void> _process(bool me, Uint8List wav) async {
    final src = me ? _me : _other;
    final dst = me ? _other : _me;
    _set(() {
      _busy = true;
      _status = 'Reading...';
    });
    try {
      final j = await Api.transcribe(wav, src, [src], ext: _mic.ext);
      final said = ((j['text'] ?? '') as String).trim();
      if (said.isEmpty) {
        _set(() => _status = 'Not heard. Hold and try again.');
        return;
      }
      _set(() => _status = 'Translating...');
      final out = await Api.translate(said, src, dst);
      _set(() {
        if (me) {
          _meHeard = said;
          _toOther = out;
        } else {
          _otherHeard = said;
          _toMe = out;
        }
        _status = '';
      });
      await _speak(out, dst, me);
    } catch (_) {
      _set(() => _status = 'No internet. Try again.');
    } finally {
      _set(() => _busy = false);
    }
  }

  Future<void> _speak(String text, String lang, bool me) async {
    try {
      if (!_ttsDown) {
        final b = await Api.speak(text, lang, pan: _buds ? (me ? 'l' : 'r') : null);
        if (b != null) {
          final done = _player.onPlayerComplete.first;
          await _player.play(BytesSource(b));
          await done.timeout(const Duration(seconds: 90));
          return;
        }
        _ttsDown = true;
      }
      await _tts.setLanguage(lang == 'od-IN' ? 'or-IN' : lang);
      await _tts.speak(text);
    } catch (_) {}
  }

  Widget _ear(String side, bool lit, Color accent) => Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: lit ? accent : Colors.transparent,
          border: Border.all(color: lit ? accent : Colors.white24, width: 2),
        ),
        child: Text(side, style: TextStyle(color: lit ? Colors.black : Colors.white38, fontWeight: FontWeight.w800, fontSize: 18)),
      );

  /// Picture of which earbud this person wears: the other person on the left, me on the right.
  Widget _earGuide(bool me, Color accent) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _ear('L', !me, accent),
          const SizedBox(width: 10),
          Icon(me ? Icons.person : Icons.people_alt, color: accent, size: 28),
          const SizedBox(width: 10),
          _ear('R', me, accent),
        ]),
      );

  Widget _panel(bool me) {
    final lang = me ? _me : _other;
    final read = me ? _toMe : _toOther; // the big text this person reads
    final said = me ? _meHeard : _otherHeard;
    final rec = me ? _recMe : _recOther;
    final accent = me ? kTeal : kOrange;
    final body = Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(22), border: Border.all(color: accent.withOpacity(rec ? 0.9 : 0.25), width: rec ? 2.5 : 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(me ? 'You speak' : 'They speak', style: const TextStyle(color: Colors.white54)),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              isDense: true,
              dropdownColor: kCard,
              underline: const SizedBox.shrink(),
              value: lang,
              style: TextStyle(color: accent, fontSize: 17, fontWeight: FontWeight.w700),
              items: [for (final e in kLangs.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => _set(() => me ? _me = v ?? _me : _other = v ?? _other),
            ),
          ),
        ]),
        if (_buds) _earGuide(me, accent),
        Expanded(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(read.isEmpty ? '...' : read, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w600, height: 1.25)),
              if (said.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(said, style: const TextStyle(color: Colors.white38, fontSize: 14)),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTapDown: (_) => _down(me),
          onTapUp: (_) => _up(me),
          onTapCancel: () => _up(me),
          onLongPressEnd: (_) => _up(me),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 64,
            decoration: BoxDecoration(
              color: rec ? accent : accent.withOpacity(0.22),
              borderRadius: BorderRadius.circular(32),
              boxShadow: rec ? [BoxShadow(color: accent.withOpacity(0.6), blurRadius: 18)] : null,
            ),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.mic, color: rec ? Colors.black : accent),
              const SizedBox(width: 8),
              Text(rec ? 'Speak now...' : 'Hold and speak ${kLangs[lang] ?? ''}',
                  style: TextStyle(color: rec ? Colors.black : accent, fontSize: 17, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      ]),
    );
    return Expanded(child: me ? body : Transform.rotate(angle: math.pi, child: body));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kNavy,
        body: SafeArea(
          child: Column(children: [
            _panel(false),
            SizedBox(
              height: 52,
              child: Row(children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white54, size: 18),
                  tooltip: 'Back',
                ),
                Expanded(
                  child: Center(
                    child: _busy
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            const TildaOrb(state: OrbState.thinking, size: 34),
                            const SizedBox(width: 6),
                            Flexible(child: Text(_status, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 13))),
                          ])
                        : Text(_status, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.amberAccent, fontSize: 13)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Material(
                    color: _buds ? kTeal : kCard,
                    shape: const StadiumBorder(),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () => _set(() {
                        _buds = !_buds;
                        _status = '';
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Icon(Icons.headphones, size: 24, color: _buds ? Colors.black : Colors.white70),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            _panel(true),
          ]),
        ),
      );
}
