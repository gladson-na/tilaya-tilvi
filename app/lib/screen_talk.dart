import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'personal_style.dart';
import 'callwords.dart';
import 'screen_capture.dart';
import 'widgets.dart';

final _needsPlace = RegExp(
    r'weather|temperature|rain|how far|distance|far is|how long|मौसम|बारिश|तापमान|दूर|दूरी|ପାଗ|ଦୂର|వాతావరణ|దూరం|வானிலை|தூரம்|ಹವಾಮಾನ|ದೂರ|കാലാവസ്ഥ|ദൂരം|আবহাওয়া|দূর|હવામાન|અંતર|ਮੌਸਮ|ਦੂਰੀ',
    caseSensitive: false);

/// One open conversation: talk or type, Tilda answers out loud and in writing.
class TalkScreen extends StatefulWidget {
  final PersonalStyle style;
  const TalkScreen({super.key, required this.style});

  @override
  State<TalkScreen> createState() => _TalkScreenState();
}

class _TalkScreenState extends State<TalkScreen> {
  final _mic = Mic();
  final _player = AudioPlayer();
  final _tts = FlutterTts();
  final _typeCtl = TextEditingController();
  final _scroll = ScrollController();
  final _history = <Map<String, String>>[];
  OrbState _orb = OrbState.idle;
  double _level = 0;
  bool _active = false; // the conversation is open: Tilda keeps listening after she answers
  bool _typing = false;
  bool _noisy = false;
  bool _finishing = false;
  bool _voiced = false;
  double _floor = -1; // the room's steady noise (a fan, traffic), learned while listening
  DateTime _lastVoice = DateTime.now();
  DateTime _t0 = DateTime.now();
  int _empty = 0;
  String _lang = ''; // the language of this conversation, learned from the greeting
  String _status = '';
  double? _lat, _lon;
  String? _fbKind;
  String _fbText = '';
  bool _fbSent = false;
  bool _ttsDown = false;
  bool _viaType = false; // this turn was typed, so do not switch the mic on afterwards

  @override
  void initState() {
    super.initState();
    _tts.awaitSpeakCompletion(true);
    unawaited(Api.wake());
  }

  @override
  void dispose() {
    _active = false;
    _mic.dispose();
    _player.dispose();
    _tts.stop();
    _typeCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _speakLang => _lang.isNotEmpty ? _lang : (widget.style.myLangs.isNotEmpty ? widget.style.myLangs.first : 'en-IN');

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  Future<void> _place() async {
    try {
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.always || p == LocationPermission.whileInUse) {
        final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 10)));
        _lat = pos.latitude;
        _lon = pos.longitude;
      }
    } catch (_) {}
  }

  // ---- listening ----

  Future<void> _toggle() async {
    if (_active) {
      await _stopAll();
      return;
    }
    _active = true;
    _noisy = false;
    _empty = 0;
    await _listen();
  }

  Future<void> _stopAll() async {
    _active = false;
    _finishing = false;
    try {
      await _mic.stop();
      await _player.stop();
      await _tts.stop();
    } catch (_) {}
    _set(() {
      _orb = OrbState.idle;
      _level = 0;
    });
  }

  Future<void> _listen() async {
    if (!_active || _mic.on) return;
    final ok = await _mic.start(_onLevel);
    if (!ok) {
      _active = false;
      _set(() => _status = 'Please allow the microphone for Tilda.');
      return;
    }
    _voiced = false;
    _floor = -1;
    _finishing = false;
    _t0 = DateTime.now();
    _lastVoice = _t0;
    _set(() {
      _orb = OrbState.listening;
      _status = '';
    });
  }

  void _onLevel(double l) {
    if (!mounted || _orb != OrbState.listening || _finishing) return;
    final now = DateTime.now();
    // learn the steady background: it drops to the quietest level at once and creeps up slowly
    _floor = _floor < 0 ? l : (l < _floor ? l : _floor + (l - _floor) * 0.02);
    final warm = now.difference(_t0).inMilliseconds > 400; // first moments only measure the room
    // speech must stand clearly above the steady noise, so a fan or traffic never counts as a voice
    if (warm && l > math.max(0.03, _floor * 2.6 + 0.01)) {
      _voiced = true;
      _lastVoice = now;
    }
    setState(() => _level = l);
    if (_voiced && now.difference(_lastVoice).inMilliseconds > 1800) {
      unawaited(_finish());
    } else if (!_voiced && now.difference(_t0).inSeconds > 14) {
      unawaited(_stopAll());
      _set(() => _status = 'I did not hear anything. Tap the mic when you are ready.');
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    _set(() {
      _orb = OrbState.reading;
      _level = 0;
    });
    final wav = await _mic.stop();
    if (!_active) return;
    try {
      final Map<String, dynamic> j = wav.length < 600
          ? {'text': ''}
          : await Api.transcribe(wav, _lang.isEmpty ? 'auto' : _lang, widget.style.myLangs.toList(), ext: _mic.ext);
      final text = ((j['text'] ?? '') as String).trim();
      final lang = (j['language'] ?? '') as String;
      if (_lang.isEmpty && lang.isNotEmpty && lang != 'unknown') _lang = lang;
      if (text.isEmpty) {
        _empty++;
        if (_empty >= 2) {
          await _tooNoisy();
          return;
        }
        _set(() => _status = 'I did not catch that, please say it again.');
        _finishing = false;
        await _listen();
        return;
      }
      _empty = 0;
      await _ask(text);
    } catch (e) {
      _set(() => _status = 'Could not reach the server. Check the internet and try again.');
      _finishing = false;
      await _stopAll();
    }
  }

  Future<void> _tooNoisy() async {
    await _stopAll();
    _set(() {
      _noisy = true;
      _typing = true;
      _status = 'It is too noisy for me to hear you. Please type instead.';
    });
    await _speak('It is too noisy for me to hear. Please type your message.', _speakLang);
  }

  // ---- asking ----

  Future<void> _typed() async {
    final t = _typeCtl.text.trim();
    if (t.isEmpty) return;
    _typeCtl.clear();
    if (_mic.on) await _mic.stop();
    _active = true;
    _viaType = true;
    await _ask(t);
  }

  Future<void> _ask(String heard) async {
    final said = CallWords.strip(heard, widget.style);
    _history.add({'role': 'user', 'content': said});
    if (_fbKind != null && !_fbSent && said.length > _fbText.length) _fbText = said;
    _set(() {
      _orb = OrbState.thinking;
      _status = '';
    });
    _toBottom();
    if (_needsPlace.hasMatch(said) && _lat == null) await _place();
    var answer = '';
    var spoke = false;
    var wantCamera = false;
    var chain = Future<void>.value();
    try {
      final recent = _history.length > 12 ? _history.sublist(_history.length - 12) : _history;
      await for (final j in Api.talk(recent, _speakLang, lat: _lat, lon: _lon)) {
        final intent = j['intent'] as String?;
        if (intent == 'camera') wantCamera = true;
        if (intent == 'complaint' || intent == 'suggestion') {
          _set(() {
            _fbKind = intent;
            _fbSent = false;
            if (said.length > _fbText.length) _fbText = said;
          });
        }
        final t = (j['text'] ?? '') as String;
        if (t.isNotEmpty) {
          answer = answer.isEmpty ? t : '$answer $t';
          _showAnswer(answer);
        }
        final a64 = j['audio'] as String?;
        if (a64 != null && _active) {
          if (!spoke) _set(() => _orb = OrbState.speaking);
          spoke = true;
          chain = chain.then((_) async {
            final done = _player.onPlayerComplete.first;
            await _player.play(BytesSource(base64Decode(a64)));
            await done.timeout(const Duration(seconds: 90));
          }).catchError((_) {});
        }
      }
    } catch (_) {}
    await chain;
    if (answer.isEmpty) answer = 'Sorry, I could not answer that right now. Please try again.';
    _showAnswer(answer, final_: true);
    _history.add({'role': 'assistant', 'content': answer});
    if (!mounted) return;
    if (!spoke && _active) {
      _set(() => _orb = OrbState.speaking);
      await _speak(answer, _speakLang);
    }
    _finishing = false;
    _set(() => _orb = OrbState.idle);
    if (wantCamera && mounted) {
      await _stopAll();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CaptureScreen(style: widget.style, autoStart: true)));
      return;
    }
    final typed = _viaType;
    _viaType = false;
    if (typed) {
      _active = false;
    } else if (_active && !_noisy) {
      await _listen();
    }
  }

  // the answer is drawn live, as the last bubble
  String _live = '';
  void _showAnswer(String a, {bool final_ = false}) {
    _set(() => _live = final_ ? '' : a);
    _toBottom();
  }

  Future<void> _speak(String text, String lang) async {
    try {
      if (!_ttsDown) {
        final b = await Api.speak(text, lang);
        if (b != null) {
          final done = _player.onPlayerComplete.first;
          await _player.play(BytesSource(b));
          await done.timeout(const Duration(seconds: 90));
          return;
        }
        _ttsDown = true; // the server voice is out: use the phone's voice for the rest of this chat
      }
      await _tts.setLanguage(lang == 'od-IN' ? 'or-IN' : lang);
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _sendFeedback() async {
    final kind = _fbKind ?? 'suggestion';
    final ok = await Api.sendFeedback(kind, _fbText.isEmpty ? (_history.isNotEmpty ? _history.last['content'] ?? '' : '') : _fbText, _speakLang);
    _set(() {
      _fbSent = ok;
      _fbKind = ok ? null : _fbKind;
      _status = ok ? 'Sent to the Tilda team. Thank you.' : 'Could not send it just now. Please try again in a moment.';
    });
  }

  // ---- screen ----

  Widget _bubble(String who, String text) {
    final me = who == 'user';
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: me ? const Color(0xFF1D4ED8) : const Color(0xFF3A2A18),
          border: me ? null : Border.all(color: kOrange.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 17, height: 1.3)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showLive = _live.isNotEmpty;
    return Scaffold(
      backgroundColor: kNavy,
      appBar: AppBar(backgroundColor: kNavy, foregroundColor: Colors.white, title: const Text('Talk to Tilda'), elevation: 0),
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 4),
          TildaOrb(state: _orb, level: _level, size: 190),
          Text(_orb == OrbState.idle && _active ? 'Your turn' : orbLabel(_orb),
              style: TextStyle(color: _orb == OrbState.speaking ? kOrange : kTeal, fontSize: 18, fontWeight: FontWeight.w600)),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              children: [
                for (final m in _history) _bubble(m['role'] ?? 'user', m['content'] ?? ''),
                if (showLive) _bubble('assistant', _live),
              ],
            ),
          ),
          if (_fbKind != null && !_fbSent)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: kTeal.withOpacity(0.5))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Send this ${_fbKind!} to the Tilda team?', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                if (_fbText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_fbText, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                  ),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: () => _set(() => _fbKind = null), child: const Text('Not now')),
                  FilledButton(onPressed: _sendFeedback, child: const Text('Send')),
                ]),
              ]),
            ),
          if (_typing)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _typeCtl,
                    autofocus: _noisy,
                    style: const TextStyle(color: Colors.white),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _typed(),
                    decoration: InputDecoration(
                      hintText: 'Type to Tilda in any language',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                IconButton(onPressed: _typed, icon: const Icon(Icons.send, color: kTeal)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              IconButton(
                iconSize: 30,
                onPressed: () => _set(() => _typing = !_typing),
                icon: Icon(_typing ? Icons.keyboard_hide : Icons.keyboard, color: Colors.white70),
              ),
              GestureDetector(
                onTap: _toggle,
                child: Container(
                  width: 78,
                  height: 78,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _active ? Colors.redAccent : kBlue,
                    boxShadow: [BoxShadow(color: (_active ? Colors.redAccent : kBlue).withOpacity(0.5), blurRadius: 18)],
                  ),
                  child: Icon(_active ? Icons.stop : Icons.mic, color: Colors.white, size: 38),
                ),
              ),
              const SizedBox(width: 48),
            ]),
          ),
        ]),
      ),
    );
  }
}
