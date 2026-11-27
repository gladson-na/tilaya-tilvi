import 'package:flutter/material.dart';

import 'live_stt.dart';
import 'personal_style.dart';
import 'widgets.dart';

/// How people in India call someone: "Hey Suresh", "Ae Suresh", "Oye Suresh", "Arre Suresh".
/// Tilda answers to any of these before her name. The person picks the ones they use, practises them,
/// and Tilda remembers how the phone's speech engine writes that person's voice saying them.
class CallWords {
  static const options = {
    'hey': 'Hey',
    'ae': 'Ae',
    'oye': 'Oye',
    'o': 'O',
    'arre': 'Arre',
    'suno': 'Suno',
    'ok': 'Ok',
  };

  // Speech engines write the name many ways: Tilda, Tilde, Telda, Hilda, टिल्डा, तिल्दा ...
  static const _name = r'(?:t[iyeu]l[dt][aeu]r?|hilda|[टत]िल्?[डद][ाेा]?)';
  static const _calls = r'(?:hey|hi|hello|ae|ay|aye|eh|a|oye|oi|o|oh|arre|are|suno|ok|okay|हे|हेलो|ए|ऐ|ओय|ओ|अरे|सुनो|ओके)';

  static RegExp _re(PersonalStyle s) {
    final learned = s.callHeard.where((e) => e.trim().isNotEmpty).map((e) => RegExp.escape(e.trim().toLowerCase())).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final heard = learned.isEmpty ? '' : '(?:${learned.join('|')})|';
    return RegExp('^\\s*(?:$heard(?:$_calls[\\s,.!?-]+)?$_name)(?=[\\s,.!?-]|\$)[\\s,.!?-]*', caseSensitive: false, unicode: true);
  }

  /// True when the sentence starts with a call-word and Tilda's name.
  static bool called(String text, PersonalStyle s) => _re(s).hasMatch(text.toLowerCase());

  /// The sentence without the call, so "Ae Tilda, capture this" becomes "capture this".
  static String strip(String text, PersonalStyle s) {
    final t = text.trim();
    final m = _re(s).firstMatch(t.toLowerCase());
    if (m == null) return t;
    final rest = t.substring(m.end <= t.length ? m.end : t.length).trim();
    return rest.isEmpty ? t : rest;
  }

  /// A practice try: remembers how the speech engine wrote it, if it really looks like a call to Tilda.
  static bool learn(String heard, PersonalStyle s) {
    final h = heard.trim().toLowerCase().replaceAll(RegExp(r'[,.!?]+$'), '');
    if (h.isEmpty || h.split(RegExp(r'\s+')).length > 4) return false;
    if (!RegExp(_name, caseSensitive: false, unicode: true).hasMatch(h)) return false;
    s.callHeard.add(h);
    return true;
  }

  static String label(String key) => options[key] ?? key;
}

/// Step two of setup, and reachable again from Settings: pick your call-words, then say each one three times.
class CallWordsScreen extends StatefulWidget {
  final PersonalStyle style;
  final VoidCallback onDone;
  const CallWordsScreen({super.key, required this.style, required this.onDone});

  @override
  State<CallWordsScreen> createState() => _CallWordsScreenState();
}

class _CallWordsScreenState extends State<CallWordsScreen> {
  final _picked = <String>{};
  final _stt = LiveStt();
  List<String> _queue = []; // every call to practise, each three times
  int _i = 0;
  bool _practising = false;
  bool _listening = false;
  String _heard = '';
  String _note = '';

  @override
  void initState() {
    super.initState();
    _picked.addAll(widget.style.callWords);
  }

  @override
  void dispose() {
    _stt.stop();
    super.dispose();
  }

  String get _locale {
    final l = widget.style.myLangs.isNotEmpty ? widget.style.myLangs.first : 'en-IN';
    return l == 'od-IN' ? 'or-IN' : l;
  }

  Future<void> _finish() async {
    final s = widget.style;
    s.callWords
      ..clear()
      ..addAll(_picked.isEmpty ? {'hey'} : _picked);
    s.callDone = true;
    await s.save();
    widget.onDone();
  }

  void _begin() {
    _queue = [for (final k in _picked) ...List.filled(3, k)];
    setState(() {
      _practising = true;
      _i = 0;
      _heard = '';
      _note = '';
    });
  }

  Future<void> _say() async {
    if (_listening) return;
    setState(() {
      _listening = true;
      _heard = '';
      _note = '';
    });
    final ok = await _stt.start(
      locale: _locale,
      onPartial: (t) => setState(() => _heard = t),
      onPhrase: (t) async {
        await _stt.stop();
        final good = CallWords.learn(t, widget.style);
        if (!mounted) return;
        setState(() {
          _listening = false;
          _heard = t;
          if (good) {
            _note = 'Got it.';
            _i++;
          } else {
            _note = 'I did not catch Tilda. Please say it again.';
          }
        });
        if (good) await widget.style.save();
        if (_i >= _queue.length) await _finish();
      },
      onEnd: (why) {
        if (!mounted) return;
        setState(() {
          _listening = false;
          if (_heard.isEmpty) _note = 'I did not hear anything. Tap and try again.';
        });
      },
    );
    if (!ok && mounted) setState(() {
      _listening = false;
      _note = 'Speech is not ready on this phone. You can skip this step.';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kNavy,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
            child: _practising ? _practice() : _choose(),
          ),
        ),
      );

  Widget _choose() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Center(child: TildaOrb(state: OrbState.idle, size: 110)),
        const SizedBox(height: 10),
        const Text('How do you call Tilda?', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        const Text('Like you call a friend: "Ae Suresh". Pick the ones you use.', style: TextStyle(color: Colors.white70, fontSize: 17, height: 1.35)),
        const SizedBox(height: 18),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final e in CallWords.options.entries)
            FilterChip(
              label: Text('${e.value} Tilda', style: const TextStyle(fontSize: 19)),
              selected: _picked.contains(e.key),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              onSelected: (v) => setState(() => v ? _picked.add(e.key) : _picked.remove(e.key)),
            ),
        ]),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 58,
          child: FilledButton(
            onPressed: _picked.isEmpty ? null : _begin,
            child: Text(_picked.isEmpty ? 'Pick at least one' : 'Practise ${_picked.length * 3} times', style: const TextStyle(fontSize: 19)),
          ),
        ),
        TextButton(onPressed: _finish, child: const Text('Skip for now', style: TextStyle(color: Colors.white60, fontSize: 16))),
      ]);

  Widget _practice() {
    final done = _i >= _queue.length;
    final key = done ? '' : _queue[_i];
    final round = done ? 3 : (_i % 3) + 1;
    return Column(children: [
      const SizedBox(height: 10),
      TildaOrb(state: _listening ? OrbState.listening : OrbState.idle, size: 150),
      const SizedBox(height: 18),
      Text('Say: ${CallWords.label(key)} Tilda', style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      Text('Try $round of 3', style: const TextStyle(color: Colors.white60, fontSize: 18)),
      const SizedBox(height: 24),
      if (_heard.isNotEmpty) Text(_heard, textAlign: TextAlign.center, style: const TextStyle(color: kTeal, fontSize: 24)),
      const SizedBox(height: 8),
      if (_note.isNotEmpty) Text(_note, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 17)),
      const Spacer(),
      GestureDetector(
        onTap: _say,
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(shape: BoxShape.circle, color: _listening ? Colors.redAccent : kBlue),
          child: Icon(_listening ? Icons.graphic_eq : Icons.mic, color: Colors.white, size: 40),
        ),
      ),
      TextButton(onPressed: _finish, child: const Text('Skip for now', style: TextStyle(color: Colors.white60, fontSize: 16))),
    ]);
  }
}
