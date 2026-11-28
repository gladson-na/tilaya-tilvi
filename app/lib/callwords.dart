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
  static const _name = r'(?:[td][iyeu]l+[dt]?[aeu]r?|hilda|hilder|[टत]िल्?[डद][ाेा]?)';
  static const _calls = r'(?:hey|hi|hello|ae|ay|aye|eh|a|oye|oi|o|oh|arre|are|suno|ok|okay|हे|हेलो|ए|ऐ|ओय|ओ|अरे|सुनो|ओके)';

  static RegExp _re(PersonalStyle s) {
    final learned = s.callHeard.where((e) => e.trim().isNotEmpty).map((e) => RegExp.escape(e.trim().toLowerCase())).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final heard = learned.isEmpty ? '' : '(?:${learned.join('|')})|';
    return RegExp('^\\s*(?:\\S+\\s+)?(?:$heard(?:$_calls[\\s,.!?-]+)?$_name)(?=[\\s,.!?-]|\$)[\\s,.!?-]*', caseSensitive: false, unicode: true);
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
  final VoidCallback? onBack;
  const CallWordsScreen({super.key, required this.style, required this.onDone, this.onBack});

  @override
  State<CallWordsScreen> createState() => _CallWordsScreenState();
}

class _CallWordsScreenState extends State<CallWordsScreen> {
  final _picked = <String>{};
  final _stt = LiveStt();
  List<String> _queue = []; // every call to practise, each three times
  int _i = 0;
  bool _practising = false;
  bool _allDone = false; // all tries finished: show the saved screen with a Done button
  final _cnt = <String, int>{};
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

  /// Saves the choice and the practice, then shows the "all set" screen. Nothing is lost if the person leaves now.
  Future<void> _save() async {
    final s = widget.style;
    s.callWords
      ..clear()
      ..addAll(_picked.isEmpty ? {'hey'} : _picked);
    s.callDone = true;
    await s.save();
    if (mounted) setState(() => _allDone = true);
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
      _allDone = false;
      _cnt.clear();
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
            final k = _queue[_i];
            final n = (_cnt[k] ?? 0) + 1;
            _cnt[k] = n;
            if (n >= 3) {
              widget.style.callTrained.add(k);
              _note = 'Got it. "${CallWords.label(k)} Tilda" is ready.';
            } else {
              _note = 'Got it.';
            }
            _i++;
          } else {
            _note = 'I did not catch Tilda. Please say it again.';
          }
        });
        if (good) await widget.style.save();
        if (_i >= _queue.length) await _save();
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!_allDone && (_practising || widget.onBack != null))
                IconButton(
                  onPressed: () {
                    if (_listening) _stt.stop();
                    if (_practising) {
                      setState(() {
                        _practising = false;
                        _listening = false;
                        _heard = '';
                        _note = '';
                      });
                    } else {
                      widget.onBack!();
                    }
                  },
                  icon: const Icon(Icons.arrow_back, color: kInk, size: 28),
                  tooltip: 'Back',
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                ),
              Expanded(child: _allDone ? _saved() : (_practising ? _practice() : _choose())),
            ]),
          ),
        ),
      );

  Widget _choose() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('How do you call Tilda?', style: TextStyle(color: kInk, fontSize: 28, fontWeight: FontWeight.w800, height: 1.15)),
        const SizedBox(height: 6),
        const Text('Like you call a friend: "Ae Suresh". Pick the ones you use.', style: TextStyle(color: kSub, fontSize: 17, height: 1.35)),
        const SizedBox(height: 6),
        const Text('A tick means you practised it three times, so it will work.', style: TextStyle(color: kSub, fontSize: 15)),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final e in CallWords.options.entries)
            FilterChip(
              avatar: widget.style.callTrained.contains(e.key) ? Icon(Icons.check_circle, color: _picked.contains(e.key) ? Colors.white : kPrimary, size: 22) : null,
              label: Text('${e.value} Tilda', style: TextStyle(fontSize: 19, color: _picked.contains(e.key) ? Colors.white : kInk)),
              showCheckmark: false,
              selectedColor: kPrimary,
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
        TextButton(onPressed: _finish, child: const Text('Skip for now', style: TextStyle(color: kSub, fontSize: 16))),
      ]);

  Widget _saved() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 20),
        const Icon(Icons.check_circle, color: kPrimary, size: 64),
        const SizedBox(height: 12),
        const Text('All set. Saved.', style: TextStyle(color: kInk, fontSize: 30, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('You can call Tilda with these, any time:', style: TextStyle(color: kSub, fontSize: 18)),
        const SizedBox(height: 16),
        for (final k in _picked)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Icon(widget.style.callTrained.contains(k) ? Icons.check_circle : Icons.circle_outlined, color: kPrimary),
              const SizedBox(width: 12),
              Text('${CallWords.label(k)} Tilda', style: const TextStyle(color: kInk, fontSize: 22, fontWeight: FontWeight.w700)),
            ]),
          ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          height: 58,
          child: FilledButton(onPressed: widget.onDone, child: const Text('Done', style: TextStyle(fontSize: 20))),
        ),
      ]);

  Widget _practice() {
    final done = _i >= _queue.length;
    final key = done ? '' : _queue[_i];
    final round = done ? 3 : (_i % 3) + 1;
    return Column(children: [
      const SizedBox(height: 10),
      TildaOrb(state: _listening ? OrbState.listening : OrbState.idle, size: 150),
      const SizedBox(height: 18),
      Text('Say: ${CallWords.label(key)} Tilda', style: const TextStyle(color: kInk, fontSize: 30, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text('Try $round of 3', style: const TextStyle(color: kSub, fontSize: 18)),
      const SizedBox(height: 24),
      if (_heard.isNotEmpty) Text(_heard, textAlign: TextAlign.center, style: const TextStyle(color: kPrimary, fontSize: 24, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      if (_note.isNotEmpty) Text(_note, textAlign: TextAlign.center, style: const TextStyle(color: kSub, fontSize: 17)),
      const Spacer(),
      Semantics(
        button: true,
        label: _listening ? 'Listening' : 'Say it now',
        child: GestureDetector(
          onTap: _say,
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(shape: BoxShape.circle, color: _listening ? const Color(0xFFB3261E) : kPrimary),
            child: Icon(_listening ? Icons.graphic_eq : Icons.mic, color: Colors.white, size: 40),
          ),
        ),
      ),
      TextButton(onPressed: _finish, child: const Text('Skip for now', style: TextStyle(color: kSub, fontSize: 16))),
    ]);
  }
}
