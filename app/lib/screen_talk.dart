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
import 'live_stt.dart';
import 'screen_capture.dart';
import 'widgets.dart';

final _needsPlace = RegExp(
    r'weather|temperature|rain|how far|distance|far is|how long|near|nearest|closest|around here|hospital|clinic|pharmacy|restaurant|hotel|atm|petrol|पास में|नज़दीक|नजदीक|आसपास|अस्पताल|मौसम|बारिश|तापमान|दूर|दूरी|ପାଗ|ଦୂର|వాతావరణ|దూరం|வானிலை|தூரம்|ಹವಾಮಾನ|ದೂರ|കാലാവസ്ഥ|ദൂരം|আবহাওয়া|দূর|હવામાન|અંતર|ਮੌਸਮ|ਦੂਰੀ',
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
  final _wake = LiveStt(); // listens for "Hey Tilda" while the conversation is closed
  bool _handsFree = true;
  bool _woke = false;
  String _wakeHeard = ''; // what the phone last heard while waiting, so a failed Hey Tilda is not a mystery
  int _wakeFails = 0;
  bool _viaType = false; // this turn was typed, so do not switch the mic on afterwards

  @override
  void initState() {
    super.initState();
    _tts.awaitSpeakCompletion(true);
    unawaited(Api.wake());
    Future.delayed(const Duration(milliseconds: 900), _startWake);
  }

  String get _wakeLocale {
    final l = widget.style.myLangs;
    final one = l.contains('en-IN') ? 'en-IN' : (l.isNotEmpty ? l.first : 'en-IN');
    return one == 'od-IN' ? 'or-IN' : one;
  }

  /// With the app open and nobody talking yet, the phone's own speech engine waits for a call-word and Tilda's name.
  Future<void> _startWake() async {
    if (!mounted || !_handsFree || _active || _wake.active) return;
    _woke = false;
    final ok = await _wake.start(
      locale: _wakeLocale,
      onPartial: _heardWake,
      onPhrase: _heardWake,
      onEnd: (why) {
        if (!mounted || !_handsFree || _active) return;
        if (why == 'quiet' || why == 'error_no_match') {
          _wakeFails = 0;
          Future.delayed(const Duration(milliseconds: 400), _startWake);
        } else if (++_wakeFails <= 4) {
          Future.delayed(const Duration(milliseconds: 1200), _startWake);
        } else {
          _set(() {
            _handsFree = false;
            _wakeHeard = 'Hands-free stopped ($why). Tap the mic instead.';
          });
        }
      },
    );
    if (!ok && mounted) _set(() => _handsFree = false);
  }

  void _heardWake(String t) {
    if (_woke || _active || !_handsFree) return;
    _set(() => _wakeHeard = t);
    if (!CallWords.called(t, widget.style)) return;
    _woke = true;
    unawaited(_wakeUp(t));
  }

  Future<void> _wakeUp(String heard) async {
    await _wake.stop();
    if (!mounted) return;
    _active = true;
    _noisy = false;
    _empty = 0;
    final rest = CallWords.strip(heard, widget.style);
    if (rest.trim().isNotEmpty && rest.trim() != heard.trim()) {
      _viaType = false;
      await _ask(heard); // "Hey Tilda, what is the weather": the question came with the call
    } else {
      await _listen();
    }
  }

  Future<void> _toggleHandsFree() async {
    _set(() => _handsFree = !_handsFree);
    if (_handsFree) {
      await _startWake();
    } else {
      await _wake.stop();
    }
  }

  @override
  void dispose() {
    _active = false;
    _handsFree = false;
    _wake.stop();
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
    await _wake.stop();
    _active = true;
    _noisy = false;
    _empty = 0;
    await _listen();
  }

  int _gen = 0; // bumped by Stop, so an answer still arriving never speaks after it

  Future<void> _stopAll() async {
    _gen++;
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
    Future.delayed(const Duration(milliseconds: 900), _startWake);
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
    if (_voiced && now.difference(_lastVoice).inMilliseconds > 2500) { // a slower speaker who stops to think is not cut off
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
    await _wake.stop();
    _active = true;
    _viaType = true;
    await _ask(t);
  }

  Future<void> _ask(String heard) async {
    final gen = _gen;
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
        if (gen != _gen) break; // Stop was pressed: drop the rest of this answer
        if (a64 != null && _active) {
          if (!spoke) _set(() => _orb = OrbState.speaking);
          spoke = true;
          chain = chain.then((_) async {
            if (gen != _gen) return;
            final done = _player.onPlayerComplete.first;
            await _player.play(BytesSource(base64Decode(a64)));
            await done.timeout(const Duration(seconds: 90));
          }).catchError((_) {});
        }
      }
    } catch (_) {}
    await chain;
    if (gen != _gen) {
      _finishing = false;
      return;
    }
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
          color: me ? kPrimary : kMint,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(text, style: TextStyle(color: me ? Colors.white : kInk, fontSize: 18, height: 1.35)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showLive = _live.isNotEmpty;
    return Scaffold(
      backgroundColor: kNavy,
      appBar: AppBar(title: const Text('Talk to Tilda')),
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 4),
          TildaOrb(state: _orb, level: _level, size: 200),
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(color: kMint, borderRadius: BorderRadius.circular(20)),
              child: Text(_orb == OrbState.idle && _active ? 'Your turn' : orbLabel(_orb),
                  style: const TextStyle(color: kPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
          if (!_active)
            TextButton.icon(
              onPressed: _toggleHandsFree,
              icon: Icon(_handsFree ? Icons.hearing : Icons.hearing_disabled, color: kPrimary, size: 20),
              label: Text(_handsFree ? 'Say "Hey Tilda" or tap the mic. Tap here to turn off.' : 'Hands-free is off. Tap to turn on.',
                  style: const TextStyle(color: kSub, fontSize: 14)),
            ),
          if (!_active && _wakeHeard.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: Text(_handsFree ? 'Heard: "$_wakeHeard"' : _wakeHeard, textAlign: TextAlign.center, style: const TextStyle(color: kSub, fontSize: 13)),
            ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(_status, textAlign: TextAlign.center, style: const TextStyle(color: kSub, fontSize: 16)),
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
              decoration: BoxDecoration(color: kMint, borderRadius: BorderRadius.circular(16)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Send this ${_fbKind!} to the Tilda team?', style: const TextStyle(color: kInk, fontWeight: FontWeight.w700, fontSize: 16)),
                if (_fbText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_fbText, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kSub)),
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
                    style: const TextStyle(color: kInk, fontSize: 17),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _typed(),
                    decoration: InputDecoration(
                      hintText: 'Type to Tilda in any language',
                      hintStyle: const TextStyle(color: kSub),
                      filled: true,
                      fillColor: kMint,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                IconButton(onPressed: _typed, tooltip: 'Send', icon: const Icon(Icons.send, color: kPrimary)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
              SizedBox(
                width: 64,
                child: Semantics(
                  button: true,
                  label: _typing ? 'Hide the keyboard' : 'Type instead',
                  child: InkWell(
                    onTap: () => _set(() => _typing = !_typing),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: const BoxDecoration(color: kMint, shape: BoxShape.circle),
                          child: Icon(_typing ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined, color: kPrimary),
                        ),
                        const SizedBox(height: 4),
                        const ExcludeSemantics(child: Text('Type', style: TextStyle(color: kSub, fontSize: 14))),
                      ]),
                    ),
                  ),
                ),
              ),
              Column(children: [
                Semantics(
                  button: true,
                  label: _active ? 'Finish speaking' : 'Start talking',
                  child: GestureDetector(
                    onTap: _toggle,
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: kPrimary),
                      child: Icon(_active ? Icons.stop_rounded : Icons.mic, color: Colors.white, size: 40),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ExcludeSemantics(child: Text(_active ? 'Finish speaking' : 'Start talking', style: const TextStyle(color: kInk, fontSize: 15))),
              ]),
              const SizedBox(width: 64),
            ]),
          ),
        ]),
      ),
    );
  }
}
