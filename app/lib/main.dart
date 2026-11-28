import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'live_stt.dart';
import 'offline_asr.dart';
import 'personal_style.dart';
import 'api.dart';
import 'callwords.dart';
import 'screen_capture.dart';
import 'screen_home.dart';
import 'screen_notes.dart';
import 'screen_talk.dart';
import 'screen_translate.dart';
import 'widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw under the status bar and the camera hole, so the glow fills the whole screen.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const TildaApp());
}

/// Entry point for the floating bubble that sits over other apps (Android only).
/// It only draws the button; the main app records and transcribes.
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: _Bubble()));
}

class _Bubble extends StatefulWidget {
  const _Bubble();

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  String _state = 'idle'; // idle, recording, working, done

  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((e) {
      if (e is Map && e['state'] is String) setState(() => _state = e['state'] as String);
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = {
          'recording': Colors.red,
          'working': Colors.amber,
          'done': Colors.green,
          'nothing': Colors.blueGrey,
        }[_state] ??
        Colors.teal;
    final icon = {
          'recording': Icons.stop,
          'working': Icons.hourglass_top,
          'done': Icons.check,
          'nothing': Icons.mic_off,
        }[_state] ??
        Icons.graphic_eq;
    return Material(
      color: Colors.transparent,
      child: Center(
        child: GestureDetector(
          onTap: () => FlutterOverlayWindow.shareData({'cmd': 'toggle'}),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: const [
              BoxShadow(blurRadius: 8, color: Colors.black38),
            ]),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
      ),
    );
  }
}

class TildaApp extends StatelessWidget {
  const TildaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tilda',
        debugShowCheckedModeBanner: false,
        theme: tildaTheme(),
        themeMode: ThemeMode.light,
        home: const HomePage(),
      );
}

/// Speech is cut into pieces of this many seconds. Each piece is written to the
/// phone's storage the moment it ends, so a dead network never loses words.
const _pieceSeconds = 8;
const _bytesPerSecond = 16000 * 2; // 16 kHz, 16-bit, mono
const _holdMs = 450; // press longer = hold mode (release stops); shorter = tap mode

Uint8List _wav(Uint8List pcm) {
  final h = ByteData(44);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little);
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, 16000, Endian.little);
  h.setUint32(28, _bytesPerSecond, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...pcm]);
}

/// Languages the translator can write into (Sarvam covers the 22 official languages plus English).
const _targets = kLangs;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _recorder = AudioRecorder();
  final _url = TextEditingController(text: 'https://tilda-backend-opfj.onrender.com');
  StreamSubscription<Uint8List>? _sub;
  Timer? _retry;
  final _buf = BytesBuilder(copy: false);
  Directory? _queue;
  int _sess = 0, _seq = 0, _downAt = 0;
  bool _recording = false, _flushing = false;
  bool _styleLoaded = false;
  final _tick = ValueNotifier<int>(0);
  String _lastErr = '';  // why the last upload failed, shown instead of a vague 'no network'
  final _asr = OfflineAsr();
  final _style = PersonalStyle();
  final _tts = FlutterTts();
  String _target = 'en-IN';
  String _source = 'auto';
  DateTime? _serverBadUntil;
  DateTime _lastWake = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _wakeT;
  final _live = LiveStt();
  bool _liveOn = true; // word-by-word typing with the phone's own recogniser
  String _liveLang = 'en-IN'; // long-press the bubble to switch
  String _livePhrases = '';
  String _liveLast = '';
  bool _liveSession = false;
  int _emptyTurns = 0;
  DateTime _lastVoice = DateTime.now();
  bool _voicedEver = false;
  int _pieceLoud = 0;
  bool _closing = false;
  DateTime? _voiceBadUntil;
  String _translation = '';
  bool _translating = false;
  final _textCtl = TextEditingController();
  final _textFocus = FocusNode();
  final _pieceText = <String, String>{}; // piece file name -> text
  final _kept = <String, File>{}; // pieces held for personal training until you review them
  final _rough = <String>{}; // pieces whose text is still the rough offline guess
  final _sessLang = <int, String>{};
  bool _online = true;
  final _typedNames = <String>{}; // pieces already typed live into the other app
  bool _flushAgain = false;
  bool _bubbleSession = false; // this recording was started from the floating bubble
  bool _bubbleOn = false;
  static const _native = MethodChannel('tilda/native');
  bool _autoBubble = true; // bubble appears only while a text box is focused
  bool _readBack = false; // speak the typed text back (eyes-free check)
  bool _nativeOn = false;
  // talking agent
  final _player = AudioPlayer();
  bool _talk = false; // conversation mode is on
  bool _awaitingReply = false; // recording finished, waiting for its text
  final _history = <Map<String, String>>[];
  StreamSubscription<Amplitude>? _ampSub;
  int _quietMs = 0;
  bool _heardVoice = false;
  Timer? _svcT;
  double? _dl; // model download progress
  String _text = '';
  int _shownSess = 0;
  String _info = 'Say a greeting and the name first, e.g. "Namaskaram Tilda".';

  @override
  void initState() {
    super.initState();
    _retry = Timer.periodic(const Duration(seconds: 10), (_) => _flush());
    if (Platform.isAndroid) {
      FlutterOverlayWindow.overlayListener.listen((e) {
        if (e is Map && e['cmd'] == 'toggle') _bubbleToggle();
      });
    }
    if (Platform.isAndroid) {
      _native.setMethodCallHandler((c) async {
        if (c.method == 'focus') {
          if (c.arguments == true) unawaited(_wake());
        }
        if (c.method == 'toggle') _bubbleToggle();
        if (c.method == 'longpress') _nextLiveLang();
        if (c.method == 'notesCtl') await NotesCtl.handler?.call(c.arguments as String);
      });
    }
    _tts.awaitSpeakCompletion(true);
    if (Platform.isAndroid) {
      _svcT = Timer.periodic(const Duration(seconds: 3), (_) async {
        try {
          final v = await _native.invokeMethod<bool>('enabled') ?? false;
          if (v != _nativeOn && mounted) setState(() => _nativeOn = v);
        } catch (_) {}
      });
    }
    _style.load().then((_) => mounted ? setState(() => _styleLoaded = true) : null);
    _asr.check().then((_) async {
      if (mounted) setState(() {});
      // the phone-only engine is the safety net: fetch it once, by itself
      if (!_asr.ready && _dl == null) unawaited(_downloadModel());
    });
    unawaited(_wake());
    _wakeT = Timer.periodic(const Duration(minutes: 9), (_) => _wake());
    _flush();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _tick.value++; // keeps the old test screen alive when it is opened from settings
  }

  void _open(Widget w) {
    Api.base = _url.text.trim();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
  }

  void _openClassic() {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<int>(valueListenable: _tick, builder: (c, _, __) => _classicBuild(c))));
  }

  @override
  Widget build(BuildContext context) {
    if (!_styleLoaded) {
      return const Scaffold(backgroundColor: kNavy, body: Center(child: CircularProgressIndicator()));
    }
    if (!_style.setupDone) {
      return SetupScreen(style: _style, onDone: () => setState(() {}));
    }
    if (!_style.callDone) {
      return CallWordsScreen(style: _style, onDone: () => setState(() {}));
    }
    return HomeScreen(
      onTalk: () => _open(TalkScreen(style: _style)),
      onCapture: () => _open(CaptureScreen(style: _style)),
      onNotes: () => _open(NotesScreen(style: _style)),
      onTranslate: () => _open(TranslateScreen(style: _style)),
      onSettings: _openSettings,
    );
  }

  String _liveBase() => _liveLang.isNotEmpty ? _liveLang : 'en-IN';

  /// Google's code for the recogniser (Odia is "or" there).
  String _liveCode() => _liveBase() == 'od-IN' ? 'or-IN' : _liveBase();

  static const _short = {
    'en-IN': 'EN', 'hi-IN': 'हि', 'od-IN': 'ଓଡ଼', 'bn-IN': 'বা', 'te-IN': 'తె', 'ta-IN': 'த',
    'kn-IN': 'ಕ', 'ml-IN': 'മ', 'mr-IN': 'मर', 'gu-IN': 'ગુ', 'pa-IN': 'ਪੰ',
  };

  /// Long-press on the bubble: switch the live language (English, Hindi, ...) and show it on the bubble.
  void _nextLiveLang() {
    final langs = _style.myLangs.toList();
    if (!langs.contains('en-IN')) langs.insert(0, 'en-IN');
    final i = langs.indexOf(_liveBase());
    final next = langs[(i + 1) % langs.length];
    setState(() {
      _liveLang = next;
      _info = 'Live language: ${_targets[next] ?? next}';
    });
    _native.invokeMethod('label', _short[next] ?? next.substring(0, 2).toUpperCase()).catchError((_) => false);
  }

  void _bubbleToggle() {
    unawaited(_bubbleToggleSafe());
  }

  Future<void> _bubbleToggleSafe() async {
    try {
      unawaited(_wake());
      if (_liveSession) {
        await _stopLive();
      } else if (_recording) {
        await _stop();
      } else if (_liveOn && Platform.isAndroid && !_talk) {
        await _startLive();
      } else {
        _bubbleSession = true;
        await _start();
      }
    } catch (e) {
      _recording = false;
      _liveSession = false;
      _native.invokeMethod('label', '!').catchError((_) => false);
      _tellBubble('nothing');
      if (mounted) setState(() => _info = 'The bubble could not start: $e');
    }
  }

  /// Word by word into the other app, using the phone's own recogniser.
  Future<void> _startLive() async {
    if (_liveSession) return;
    final ok = await _native.invokeMethod<bool>('liveStart').catchError((_) => false) ?? false;
    if (!ok) {
      // not on a text box we can type into: use the normal recorder
      _bubbleSession = true;
      await _start();
      return;
    }
    _livePhrases = '';
    _liveLast = '';
    _liveSession = true;
    final started = await _live.start(
      locale: _liveCode(),
      onPartial: (t) => _liveType(_livePhrases + t),
      onPhrase: (t) {
        _livePhrases = '$_livePhrases$t ';
        _liveType(_livePhrases);
      },
      onEnd: (why) => _stopLive(),
    );
    if (!started) {
      _liveSession = false;
      _bubbleSession = true;
      await _start();
      return;
    }
    _tellBubble('recording');
    if (mounted) setState(() => _info = 'Live: speak, each word is typed as you say it.');
  }

  void _liveType(String t) {
    _liveLast = t;
    _native.invokeMethod('liveSet', t).catchError((_) => false);
    if (mounted) setState(() => _text = t);
  }

  Future<void> _stopLive() async {
    if (!_liveSession) return;
    _liveSession = false;
    await _live.stop();
    if (_liveLast.trim().isNotEmpty) {
      _tellBubble('done');
      Future.delayed(const Duration(seconds: 2), () => _tellBubble('idle'));
      if (mounted) setState(() => _info = 'Typed live.');
    } else {
      _tellBubble('nothing');
      if (mounted) setState(() => _info = 'I did not hear any words, so I closed.');
    }
  }

  /// Talk mode, listening part: the phone hears you, so the answer can start much sooner.
  Future<bool> _talkListen() async {
    _sess = DateTime.now().millisecondsSinceEpoch;
    _shownSess = _sess;
    _sessLang[_sess] = _liveBase();
    _awaitingReply = false;
    final ok = await _live.start(
      locale: _liveCode(),
      onPartial: (t) {
        if (mounted) setState(() => _text = t);
      },
      onPhrase: (t) async {
        await _live.stop();
        if (!_talk) return;
        _stopT = DateTime.now();
        _text = t;
        if (mounted) setState(() => _textCtl.text = t);
        unawaited(_agentTurn());
      },
      onEnd: (why) {
        if (_talk) _endTalk('Nobody spoke, so I stopped listening.');
      },
    );
    if (ok && mounted) setState(() => _info = 'Listening...');
    return ok;
  }

  /// Language for the offline engine: the one heard, else the first of your own languages that it knows.
  String _offlineLang(int sess) {
    final heard = _whisper[_sessLang[sess]];
    if (heard != null) return heard;
    for (final l in _style.myLangs) {
      final w = _whisper[l];
      if (w != null) return w;
    }
    return 'hi';
  }

  /// Watches the microphone: silence is never saved, and a quiet bubble session closes by itself.
  void _watchChunk(Uint8List chunk) {
    var peak = 0;
    final bd = ByteData.sublistView(chunk);
    for (var i = 0; i + 1 < chunk.length; i += 16) {
      final v = bd.getInt16(i, Endian.little).abs();
      if (v > peak) peak = v;
    }
    if (peak > _pieceLoud) _pieceLoud = peak;
    final now = DateTime.now();
    if (peak > 900) {
      _lastVoice = now;
      _voicedEver = true;
    }
    if (_bubbleSession && !_talk && _recording && !_closing) {
      final quiet = now.difference(_lastVoice).inSeconds;
      if (!_voicedEver && quiet >= 8) {
        unawaited(_quietClose());
      } else if (_voicedEver && quiet >= 7) {
        unawaited(_stop());
      }
    }
  }

  Future<void> _quietClose() async {
    if (_closing) return;
    _closing = true;
    _bubbleSession = false;
    await _stop();
    _tellBubble('nothing');
    if (mounted) setState(() => _info = 'I did not hear any words, so I closed.');
    _closing = false;
  }

  /// Wakes the free server (it sleeps after 15 idle minutes) so the first real request is not slow.
  Future<void> _wake() async {
    if (DateTime.now().difference(_lastWake).inSeconds < 20) return;
    _lastWake = DateTime.now();
    try {
      await http.get(Uri.parse('${_url.text.trim()}/health')).timeout(const Duration(seconds: 70));
    } catch (_) {}
  }

  Future<Directory> _dir() async {
    if (_queue != null) return _queue!;
    final base = await getApplicationDocumentsDirectory();
    return _queue = await Directory('${base.path}/queue').create(recursive: true);
  }

  Future<void> _savePiece() async {
    if (_buf.length < _bytesPerSecond ~/ 3) {
      _buf.clear();
      return;
    }
    final loud = _pieceLoud;
    _pieceLoud = 0;
    if (loud < 900) {
      _buf.clear(); // nothing but silence: let it drop
      return;
    }
    final pcm = _buf.takeBytes();
    final d = await _dir();
    final name = '${_sess.toString().padLeft(14, '0')}_${(_seq++).toString().padLeft(5, '0')}.wav';
    await File('${d.path}/$name').writeAsBytes(_wav(pcm), flush: true);
    unawaited(_flush());
  }

  Future<void> _start() async {
    if (_recording) return;
    if (_talk && _liveOn && Platform.isAndroid) {
      if (await _talkListen()) return;
    }
    if (!await _recorder.hasPermission()) {
      setState(() => _info = 'Microphone permission is needed.');
      _native.invokeMethod('label', 'Mic?').catchError((_) => false);
      _tellBubble('nothing');
      return;
    }
    _sess = DateTime.now().millisecondsSinceEpoch;
    _typedNames.clear();
    _seq = 0;
    _shownSess = _sess;
    _buf.clear();
    _pieceLoud = 0;
    _voicedEver = false;
    _lastVoice = DateTime.now();
    final stream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1));
    _sub = stream.listen((chunk) {
      _buf.add(chunk);
      _watchChunk(chunk);
      if (_buf.length >= (_bubbleSession ? 4 : _pieceSeconds) * _bytesPerSecond) _savePiece();
    });
    _tellBubble('recording');
    if (_talk) _watchSilence();
    setState(() {
      _recording = true;
      _text = '';
      _info = 'Recording. Pieces are saved on your phone as you speak.';
    });
  }

  DateTime? _stopT;

  Future<void> _stop() async {
    _stopT = DateTime.now();
    if (!_recording) return;
    await _ampSub?.cancel();
    _ampSub = null;
    if (_talk) _awaitingReply = true;
    await _recorder.stop();
    await _sub?.cancel();
    await _savePiece();
    _tellBubble('working');
    setState(() => _recording = false);
    await _flush();
  }

  /// Translates what is in the text box into the chosen language, using the server.
  Future<void> _translate() async {
    final text = _textCtl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _translating = true;
      _translation = '';
    });
    try {
      final res = await http
          .post(Uri.parse('${_url.text.trim()}/translate'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'text': text, 'source': _source != 'auto' ? _source : (_sessLang[_shownSess] ?? 'auto'), 'target': _target}))
          .timeout(const Duration(seconds: 25));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() => _translation = j['error'] != null ? 'Could not translate: ${j['error']}' : (j['text'] ?? '') as String);
    } catch (e) {
      setState(() => _translation = 'No network, so no translation right now. Your words are safe.');
    } finally {
      setState(() => _translating = false);
    }
  }

  /// Reads the translation aloud so the other person can hear it (needs that language's voice on the phone).
  Future<void> _speak() async {
    if (_translation.isEmpty) return;
    try {
      await _tts.setLanguage(_target);
      await _tts.speak(_translation);
    } catch (_) {
      setState(() => _info = 'This phone has no voice for ${_targets[_target]}. Install it in Android text-to-speech settings.');
    }
  }

  void _tellBubble(String state) {
    if (_bubbleOn && Platform.isAndroid) FlutterOverlayWindow.shareData({'state': state});
    if (Platform.isAndroid) _native.invokeMethod('state', state).catchError((_) {});
  }

  /// Conversation mode: stops recording by itself when you finish a sentence.
  void _watchSilence() {
    _quietMs = 0;
    _heardVoice = false;
    _ampSub?.cancel();
    _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 150)).listen((a) {
      if (a.current > -32) {
        _heardVoice = true;
        _quietMs = 0;
      } else {
        _quietMs += 150;
      }
      if (_heardVoice && _quietMs >= 1300) {
        _stop();
      } else if (!_heardVoice && _quietMs >= 10000) {
        _endTalk('Nobody spoke, so I stopped listening.');
      }
    });
  }

  Future<void> _toggleTalk() async {
    if (_talk) {
      await _endTalk('Stopped talking.');
      return;
    }
    _history.clear();
    setState(() {
      _talk = true;
      _translation = '';
    });
    await _start();
  }

  Future<void> _endTalk(String why) async {
    _talk = false;
    await _live.stop();
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      await _player.stop();
      await _tts.stop();
    } catch (_) {}
    if (_recording) await _stop();
    _awaitingReply = false;
    if (mounted) setState(() => _info = why);
  }

  String _convo() => _history.map((m) => '${m['role'] == 'user' ? 'You' : 'Tilda'}: ${m['content']}').join('\n\n');

  Future<void> _agentTurn() async {
    final said = _text.trim();
    final lang = _sessLang[_shownSess] ?? (_style.myLangs.isNotEmpty ? _style.myLangs.first : 'en-IN');
    _history.add({'role': 'user', 'content': said});
    if (mounted) setState(() { _info = 'Tilda is thinking...'; _translation = _convo(); });
    var answer = '';
    var spoke = false;
    final t0 = DateTime.now();
    final heardMs = _stopT == null ? 0 : t0.difference(_stopT!).inMilliseconds;
    var chain = Future<void>.value();
    try {
      final recent = _history.length > 12 ? _history.sublist(_history.length - 12) : _history;
      final req = http.Request('POST', Uri.parse('${_url.text.trim()}/talk'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'messages': recent, 'lang': lang});
      final resp = await http.Client().send(req).timeout(const Duration(seconds: 60));
      await for (final line in resp.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final j = jsonDecode(line) as Map<String, dynamic>;
        if (j['error'] != null) {
          _lastErr = '${j['error']}';
          _voiceBadUntil = DateTime.now().add(const Duration(seconds: 90));
        }
        final t = (j['text'] ?? '') as String;
        if (t.isNotEmpty) answer = answer.isEmpty ? t : '$answer $t';
        final a64 = j['audio'] as String?;
        if (a64 != null && _talk) {
          if (!spoke && mounted) {
            setState(() => _info = 'Tilda is speaking... (heard you in $heardMs ms, first words ${DateTime.now().difference(t0).inMilliseconds} ms later)');
          }
          spoke = true;
          chain = chain.then((_) async {
            final done = _player.onPlayerComplete.first;
            await _player.play(BytesSource(base64Decode(a64)));
            await done.timeout(const Duration(seconds: 90));
          }).catchError((_) {});
        }
      }
    } catch (e) {
      _lastErr = '$e';
    }
    await chain;
    if (answer.isEmpty) answer = 'Sorry, I could not answer that. Please try again.';
    _history.add({'role': 'assistant', 'content': answer});
    if (!mounted || !_talk) return;
    if (!spoke) {
      setState(() { _info = 'Tilda is speaking...'; _translation = _convo(); });
      await _say(answer, lang);
    } else {
      setState(() => _translation = _convo());
    }
    if (_talk && !_recording) await _start();
  }

  /// Speaks with Sarvam's voice; falls back to the phone's own voice if the server cannot.
  Future<void> _say(String text, String lang) async {
    try {
      if (_voiceBadUntil != null && DateTime.now().isBefore(_voiceBadUntil!)) throw Exception('server voice is down, using the phone voice');
      final res = await http
          .post(Uri.parse('${_url.text.trim()}/speak'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'text': text, 'lang': lang}))
          .timeout(const Duration(seconds: 40));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (j['audio'] == null) throw Exception(j['error'] ?? 'no audio');
      final done = _player.onPlayerComplete.first;
      await _player.play(BytesSource(base64Decode(j['audio'] as String)));
      await done.timeout(const Duration(seconds: 90));
    } catch (e) {
      _lastErr = 'voice: $e';
      _voiceBadUntil = DateTime.now().add(const Duration(seconds: 90));
      try {
        await _tts.setLanguage(lang);
        await _tts.speak(text);
      } catch (_) {}
    }
  }

  Future<bool> _typeInto(String t) async {
    try {
      return await _native.invokeMethod<bool>('insert', '$t ') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _sayBack(String t, String? lang) async {
    try {
      await _tts.setLanguage(lang ?? 'en-IN');
      await _tts.speak(t);
    } catch (_) {}
  }

  Future<void> _toggleBubble() async {
    if (_bubbleOn) {
      await FlutterOverlayWindow.closeOverlay();
      setState(() => _bubbleOn = false);
      return;
    }
    if (!await FlutterOverlayWindow.isPermissionGranted()) {
      await FlutterOverlayWindow.requestPermission();
      setState(() => _info = 'Allow "Display over other apps" for Tilda, come back, and tap the button again.');
      return;
    }
    await FlutterOverlayWindow.showOverlay(
      height: 200,
      width: 200,
      alignment: OverlayAlignment.centerRight,
      enableDrag: true,
      positionGravity: PositionGravity.auto,
      overlayTitle: 'Tilda is ready',
      overlayContent: 'Tap the bubble to speak',
    );
    setState(() {
      _bubbleOn = true;
      _info = 'Bubble is on. Open any app, tap the bubble, speak, tap again. The text is copied: paste it.';
    });
  }

  String _name(File f) => f.uri.pathSegments.last;

  void _refreshText() {
    final names = _pieceText.keys.where((n) => n.startsWith(_shownSess.toString().padLeft(14, '0'))).toList()..sort();
    _text = _style.apply(names.map((n) => _pieceText[n]!).where((t) => t.isNotEmpty).join(' '));
    if (!_textFocus.hasFocus) _textCtl.text = _text;
  }

  static const _whisper = {
    'hi-IN': 'hi', 'te-IN': 'te', 'ta-IN': 'ta', 'kn-IN': 'kn', 'ml-IN': 'ml', 'mr-IN': 'mr',
    'gu-IN': 'gu', 'bn-IN': 'bn', 'pa-IN': 'pa', 'ur-IN': 'ur', 'ur-PK': 'ur', 'ne-IN': 'ne',
    'ne-NP': 'ne', 'bn-BD': 'bn', 'ps-AF': 'ps', 'si-LK': 'si', 'my-MM': 'my', 'bo-CN': 'bo', 'en-IN': 'en',
  };

  /// Send saved pieces in order. A piece is deleted only after the server answers.
  /// While the network is down, pieces get a rough on-device transcript instead.
  Future<void> _flush() async {
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      final d = await _dir();
      final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.wav')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      var netOk = true;
      final busy = _recording || _bubbleSession || _talk;
      for (final f in files) {
        final name = _name(f);
        final sess = int.tryParse(name.split('_').first) ?? 0;
        // nobody waits more than 30 seconds: older pieces just drop
        if (DateTime.now().difference(f.lastModifiedSync()).inSeconds > 30) {
          await f.delete();
          continue;
        }
        if (sess != _sess && busy) continue;
        final cooling = _serverBadUntil != null && DateTime.now().isBefore(_serverBadUntil!);
        if (netOk && !cooling) {
          try {
            final req = http.MultipartRequest('POST', Uri.parse('${_url.text.trim()}/transcribe'))
              ..fields['lang'] = _sessLang[sess] ?? 'auto'
              ..fields['mine'] = _style.myLangs.join(',')
              ..fields['piece'] = name
              ..fields.addAll(_style.hints().isEmpty ? {} : {'hints': _style.hints()})
              ..files.add(Api.slow
                  ? http.MultipartFile.fromBytes('audio', slimWav(await f.readAsBytes()), filename: 'a.wav')
                  : await http.MultipartFile.fromPath('audio', f.path));
            final upT0 = DateTime.now();
            final res = await http.Response.fromStream(await req.send().timeout(Duration(seconds: busy ? 30 : 70)));
            Api.noteSpeed(DateTime.now().difference(upT0));
            Map<String, dynamic> j;
            try {
              j = jsonDecode(res.body) as Map<String, dynamic>;
            } catch (_) {
              throw Exception('server answered ${res.statusCode}: ${res.body.length > 160 ? res.body.substring(0, 160) : res.body}');
            }
            if (j['error'] != null) throw Exception('${j['error']} ${j['log'] ?? ''}');
            _lastErr = '';
            final lang = j['language'] as String?;
            if (lang != null && lang != 'unknown' && (_style.myLangs.contains(lang) || j['greeting_found'] == true) && !_sessLang.containsKey(sess)) {
              _sessLang[sess] = lang;
            }
            if (_style.keepAudio) {
              // held on the phone until you review the text and tap "Save my correction"
              final keep = File('${d.path}/../kept_$name');
              await f.copy(keep.path);
              _kept[name] = keep;
            }
            await f.delete();
            _rough.remove(name);
            _pieceText[name] = (j['text'] ?? '') as String;
            if (!_style.firstDone && _pieceText[name]!.trim().isNotEmpty) {
              _style.firstDone = true;
              await _style.save();
            }
            _online = true;
            if (_bubbleSession && !_talk && sess == _sess && _pieceText[name]!.trim().isNotEmpty) {
              // live: put each piece into the other app as soon as it is understood
              if (await _typeInto(_style.apply(_pieceText[name]!))) _typedNames.add(name);
            }
            if (mounted) {
              setState(() {
                _refreshText();
                _info = 'Engine: ${j['engine']}\nLanguage: ${j['language']}\nGreeting found: ${j['greeting_found']}';
              });
            }
            continue;
          } catch (e) {
            netOk = false;
            _online = false;
            _serverBadUntil = DateTime.now().add(const Duration(seconds: 40));
            _lastErr = e.toString().replaceFirst('Exception: ', '');
          }
        }
        // no network: rough on-device text so the words are visible right away
        if (_asr.ready && !_pieceText.containsKey(name)) {
          try {
            final t = await _asr.transcribe(f.path, _offlineLang(sess));
            _pieceText[name] = t;
            _rough.add(name);
            if (_bubbleSession && !_talk && sess == _sess && t.trim().isNotEmpty) {
              if (await _typeInto(_style.apply(t))) _typedNames.add(name);
            }
            if (mounted) setState(_refreshText);
          } catch (_) {}
        }
      }
      final left = d.listSync().where((f) => f.path.endsWith('.wav')).length;
      // pieces of this session that still have no text at all (rough text counts as handled)
      final waiting = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.wav') && _name(f).startsWith(_sess.toString().padLeft(14, '0')) && !_pieceText.containsKey(_name(f)))
          .length;
      if ((_bubbleSession || _talk) && !_recording && waiting > 0 && (!netOk || (_serverBadUntil != null && DateTime.now().isBefore(_serverBadUntil!))) && !_asr.ready) {
        // server is out and the phone-only engine is not on this phone yet: do not hang
        _bubbleSession = false;
        _awaitingReply = false;
        if (mounted) setState(() => _info = 'The server cannot help right now and the offline model is not downloaded yet. Your words are saved and will be typed when it works.');
        _tellBubble('idle');
      }
      if (_bubbleSession && !_recording && waiting == 0 && _text.isNotEmpty) {
        // started from the bubble: type whatever was not typed live, else leave it on the clipboard
        _bubbleSession = false;
        final rest = _pieceText.keys
            .where((n) => n.startsWith(_sess.toString().padLeft(14, '0')) && !_typedNames.contains(n))
            .toList()
          ..sort();
        final restText = _style.apply(rest.map((n) => _pieceText[n]!).where((t) => t.trim().isNotEmpty).join(' '));
        var typed = true;
        if (restText.isNotEmpty) typed = await _typeInto(restText);
        if (!typed) await Clipboard.setData(ClipboardData(text: _text));
        if (mounted) {
          setState(() => _info = typed ? 'Typed into the text box.' : 'Copied. Paste it (turn on typing in settings to skip this).');
        }
        if (_readBack) await _sayBack(_text, _sessLang[_shownSess]);
        _tellBubble('done');
        Future.delayed(const Duration(seconds: 3), () => _tellBubble('idle'));
      }
      if (_bubbleSession && !_recording && waiting == 0 && _text.isEmpty) {
        _bubbleSession = false;
        if (mounted) setState(() => _info = 'I did not hear any words. Try again, a little closer to the mic.');
        _tellBubble('idle');
      }
      if (_talk && _awaitingReply && !_recording && waiting == 0) {
        _awaitingReply = false;
        if (_text.trim().isEmpty) {
          if (++_emptyTurns >= 2) {
            _emptyTurns = 0;
            await _endTalk('Nobody spoke, so I closed.');
          } else {
            await _start();
          }
        } else {
          _emptyTurns = 0;
          unawaited(_agentTurn());
        }
      }
      if (left > 0 && mounted) {
        setState(() => _info =
            '${_recording ? 'Recording. ' : ''}$left piece(s) saved on your phone, will retry. ${_asr.ready ? 'Showing a rough offline version. ' : ''}Last problem: ${_lastErr.isEmpty ? 'none yet' : _lastErr}');
      }
    } finally {
      _flushing = false;
      if (_flushAgain) {
        _flushAgain = false;
        unawaited(_flush());
      }
    }
  }

  Future<void> _downloadModel() async {
    setState(() => _dl = 0);
    try {
      await _asr.download((p) => mounted ? setState(() => _dl = p) : null);
      setState(() => _info = 'Offline model ready.');
    } catch (e) {
      setState(() => _info = 'Model download failed: $e');
    } finally {
      setState(() => _dl = null);
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    _wakeT?.cancel();
    _live.stop();
    _recorder.dispose();
    _textCtl.dispose();
    _textFocus.dispose();
    _url.dispose();
    _tick.dispose();
    _svcT?.cancel();
    super.dispose();
  }

  Future<void> _openSettings() async {
    if (Platform.isAndroid) {
      try {
        _nativeOn = await _native.invokeMethod<bool>('enabled') ?? false;
      } catch (_) {}
    }
    if (!mounted) return;
    Widget section(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
          child: Text(t, style: const TextStyle(color: kSub, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
        );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: kBg,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 4), child: Text('Settings', style: TextStyle(color: kInk, fontSize: 26, fontWeight: FontWeight.w800))),
              section('YOU'),
              TildaCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('My languages'),
                    subtitle: Text(_style.myLangs.map((c) => _targets[c] ?? c).join(', ')),
                    trailing: TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _style.setupDone = false;
                        setState(() {});
                      },
                      child: const Text('Change'),
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('How I call Tilda'),
                    subtitle: Text(_style.callWords.map(CallWords.label).join(', ')),
                    trailing: TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _style.callDone = false;
                        setState(() {});
                      },
                      child: const Text('Change'),
                    ),
                  ),
                ]),
              ),
              if (Platform.isAndroid) ...[
                section('TYPING IN OTHER APPS'),
                TildaCard(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Column(children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(_nativeOn ? 'Voice bubble is on' : 'Voice bubble is off'),
                      subtitle: Text(_nativeOn ? 'A mic bubble appears when you tap a text box.' : 'Turn on "Tilda typing" in Accessibility. If it is greyed out: App info, three dots, Allow restricted settings.'),
                      trailing: TextButton(onPressed: () => _native.invokeMethod('settings'), child: Text(_nativeOn ? 'Manage' : 'Turn on')),
                    ),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Only show on text boxes'),
                      value: _autoBubble,
                      onChanged: (v) {
                        setSheet(() => _autoBubble = v);
                        _native.invokeMethod('auto', v).catchError((_) {});
                      },
                    ),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Type words as I say them'),
                      subtitle: const Text('Uses the phone\'s own speech engine. Free.'),
                      value: _liveOn,
                      onChanged: (v) => setSheet(() => _liveOn = v),
                    ),
                    if (_liveOn)
                      DropdownButton<String>(
                        isExpanded: true,
                        value: _targets.containsKey(_liveBase()) ? _liveBase() : 'en-IN',
                        items: [for (final e in _targets.entries) DropdownMenuItem(value: e.key, child: Text('Language: ${e.value}'))],
                        onChanged: (v) => setSheet(() => _liveLang = v ?? _liveLang),
                      ),
                    const Divider(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Read it back to me'),
                      subtitle: const Text('Speaks the typed text so you can check it by ear.'),
                      value: _readBack,
                      onChanged: (v) => setSheet(() => _readBack = v),
                    ),
                  ]),
                ),
              ],
              section('CONNECTION'),
              TildaCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Slow internet mode'),
                  subtitle: const Text('Sends less data and uses the phone\'s voice. Tilda also turns it on by herself when the network is slow.'),
                  value: Api.saver,
                  onChanged: (v) => setSheet(() => Api.saver = v),
                ),
              ),
              section('PRIVACY'),
              TildaCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use my word list as a hint'),
                    subtitle: Text('Your own names and words help the engines. Sent with each recording only, never stored. ${_style.vocab.length} word(s).'),
                    value: _style.shareHints,
                    onChanged: (v) async {
                      setSheet(() => _style.shareHints = v);
                      await _style.save();
                      setState(() {});
                    },
                  ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Learn my voice on this phone'),
                    subtitle: const Text('Keeps the recordings you review, only on this phone.'),
                    value: _style.keepAudio,
                    onChanged: (v) async {
                      setSheet(() => _style.keepAudio = v);
                      await _style.save();
                      setState(() {});
                    },
                  ),
                  const Divider(),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () async {
                        await _style.forget();
                        setState(() {
                          _refreshText();
                          _info = 'Forgot everything it learned about you.';
                        });
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Forget everything learned about me'),
                    ),
                  ),
                ]),
              ),
              section('ADVANCED'),
              TildaCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Theme(
                  data: Theme.of(ctx).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text('For testing'),
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Remove Notes demo limit'),
                        subtitle: Text('Notes stops after ${Api.demoMinutes} minutes to protect the free credits. Turn this on for long recordings. It switches off again when the app restarts.'),
                        value: Api.noLimit,
                        onChanged: (v) => setSheet(() => Api.noLimit = v),
                      ),
                      TextField(controller: _url, decoration: const InputDecoration(labelText: 'Server address')),
                      if (!_asr.ready)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton(
                            onPressed: _dl == null ? _downloadModel : null,
                            child: Text(_dl == null ? 'Download offline model (about 150 MB, once)' : 'Downloading ${(_dl! * 100).round()}%'),
                          ),
                        ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Test screen'),
                        subtitle: const Text('The first version, for checking things.'),
                        trailing: TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _openClassic();
                          },
                          child: const Text('Open'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// One screen, no scrolling: everything a screenshot needs is visible at once.
  Widget _classicBuild(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Tilda test screen'),
          actions: [IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings)],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Listener(
                onPointerDown: (_) {
                  if (_recording) {
                    _downAt = 0;
                    _stop(); // tap mode: second tap stops
                  } else {
                    _downAt = DateTime.now().millisecondsSinceEpoch;
                    _start();
                  }
                },
                onPointerUp: (_) {
                  if (_downAt == 0) return;
                  final held = DateTime.now().millisecondsSinceEpoch - _downAt >= _holdMs;
                  _downAt = 0;
                  if (held) _stop(); // hold mode: release stops; a quick tap keeps recording
                },
                child: Container(
                  height: 84,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _recording ? Colors.red : Colors.teal,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _recording ? 'Recording... tap or release to stop' : 'Tap or hold to record',
                    style: const TextStyle(color: Colors.white, fontSize: 20),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _textCtl,
                  focusNode: _textFocus,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: Theme.of(context).textTheme.titleLarge,
                  decoration: const InputDecoration(
                      hintText: 'Your words appear here. Fix anything wrong, then tap "Save my correction".',
                      border: OutlineInputBorder()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: FilledButton.icon(
                  onPressed: _toggleTalk,
                  icon: Icon(_talk ? Icons.stop : Icons.record_voice_over),
                  label: Text(_talk ? 'Stop talking' : 'Talk to Tilda'),
                ),
              ),
              if (!_style.firstDone)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('First time:\n1. Tap the gear and tick the languages you speak.\n2. Tap the green button and say "namaste tilda", then one sentence.\n3. Your words appear in the box.\nThe other buttons show up after your first success.'),
                ),
              if (_style.firstDone) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: () async {
                      final n = await _style.learn(_text, _textCtl.text);
                      if (_style.keepAudio) {
                        final prefix = _shownSess.toString().padLeft(14, '0');
                        for (final e in _kept.entries.where((e) => e.key.startsWith(prefix)).toList()) {
                          await _style.addTrainingPiece(e.value, _style.apply(_pieceText[e.key] ?? ''));
                          try {
                            await e.value.delete();
                          } catch (_) {}
                          _kept.remove(e.key);
                        }
                      }
                      _textFocus.unfocus();
                      setState(() {
                        _refreshText();
                        _info = n > 0
                            ? 'Learned $n correction(s). Kept only on this phone.'
                            : 'Nothing new to learn from that edit.';
                      });
                    },
                    child: const Text('Save my correction'),
                  ),
                ),
                if (Platform.isAndroid) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _toggleBubble,
                      child: Text(_bubbleOn ? 'Hide bubble' : 'Show bubble'),
                    ),
                  ),
                ],
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _source,
                    items: [
                      const DropdownMenuItem(value: 'auto', child: Text('From: Auto-detect')),
                      for (final e in _targets.entries) DropdownMenuItem(value: e.key, child: Text('From: ${e.value}'))
                    ],
                    onChanged: (v) => setState(() => _source = v ?? _source),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _target,
                    items: [
                      for (final e in _targets.entries) DropdownMenuItem(value: e.key, child: Text('To: ${e.value}'))
                    ],
                    onChanged: (v) => setState(() => _target = v ?? _target),
                  ),
                ),
              ]),
              Row(children: [
                const Spacer(),
                FilledButton(onPressed: _translating ? null : _translate, child: Text(_translating ? '...' : 'Translate')),
                IconButton(icon: const Icon(Icons.volume_up), onPressed: _speak),
              ]),
              Expanded(
                flex: 2,
                child: SingleChildScrollView(
                  child: Text(_translation.isEmpty ? 'The translation appears here.' : _translation,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ),
              ],
              const Divider(height: 8),
              Row(children: [
                const Text('Status'),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy all'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _statusText()));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied. Paste it in the chat.')));
                    }
                  },
                ),
              ]),
              Expanded(
                flex: 3,
                child: Scrollbar(
                  child: SingleChildScrollView(
                    child: SelectableText(_statusText(), style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );

  String _statusText() => '$_info\n\nTyping into other apps: ${_nativeOn ? 'ON' : 'OFF (settings > Accessibility > Tilda typing)'}\n\nLearned: ${_style.count} fix(es) · words: ${_style.vocab.length} · '
      'voice data: ${(_style.trainedSeconds / 60).toStringAsFixed(1)}/60 min · '
      'offline model: ${_asr.ready ? 'ready' : 'not downloaded'}'
      '${_dl != null ? ' (${(_dl! * 100).round()}%)' : ''}';
}
