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

import 'offline_asr.dart';
import 'personal_style.dart';

void main() => runApp(const TildaApp());

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
        }[_state] ??
        Colors.teal;
    final icon = {
          'recording': Icons.stop,
          'working': Icons.hourglass_top,
          'done': Icons.check,
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
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.teal,
            brightness: Brightness.dark,
            useMaterial3: true),
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
const _targets = {
  'en-IN': 'English', 'hi-IN': 'Hindi', 'te-IN': 'Telugu', 'ta-IN': 'Tamil', 'kn-IN': 'Kannada',
  'ml-IN': 'Malayalam', 'mr-IN': 'Marathi', 'gu-IN': 'Gujarati', 'bn-IN': 'Bengali', 'pa-IN': 'Punjabi',
  'od-IN': 'Odia', 'as-IN': 'Assamese', 'ur-IN': 'Urdu', 'ne-IN': 'Nepali', 'kok-IN': 'Konkani',
  'mai-IN': 'Maithili', 'doi-IN': 'Dogri', 'ks-IN': 'Kashmiri', 'sd-IN': 'Sindhi', 'sa-IN': 'Sanskrit',
  'sat-IN': 'Santali', 'mni-IN': 'Manipuri', 'brx-IN': 'Bodo',
};

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
  String _lastErr = '';  // why the last upload failed, shown instead of a vague 'no network'
  final _asr = OfflineAsr();
  final _style = PersonalStyle();
  final _tts = FlutterTts();
  String _target = 'en-IN';
  String _translation = '';
  bool _translating = false;
  final _textCtl = TextEditingController();
  final _textFocus = FocusNode();
  final _pieceText = <String, String>{}; // piece file name -> text
  final _kept = <String, File>{}; // pieces held for personal training until you review them
  final _rough = <String>{}; // pieces whose text is still the rough offline guess
  final _sessLang = <int, String>{};
  bool _online = true;
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
        if (e is Map && e['cmd'] == 'toggle') {
          if (_recording) {
            _stop();
          } else {
            _bubbleSession = true;
            _start();
          }
        }
      });
    }
    if (Platform.isAndroid) {
      _native.setMethodCallHandler((c) async {
        if (c.method == 'toggle') {
          if (_recording) {
            _stop();
          } else {
            _bubbleSession = true;
            _start();
          }
        }
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
    _style.load().then((_) => mounted ? setState(() {}) : null);
    _asr.check().then((_) => mounted ? setState(() {}) : null);
    _flush();
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
    final pcm = _buf.takeBytes();
    final d = await _dir();
    final name = '${_sess.toString().padLeft(14, '0')}_${(_seq++).toString().padLeft(5, '0')}.wav';
    await File('${d.path}/$name').writeAsBytes(_wav(pcm), flush: true);
    unawaited(_flush());
  }

  Future<void> _start() async {
    if (_recording) return;
    if (!await _recorder.hasPermission()) {
      setState(() => _info = 'Microphone permission is needed.');
      return;
    }
    _sess = DateTime.now().millisecondsSinceEpoch;
    _seq = 0;
    _shownSess = _sess;
    _buf.clear();
    final stream = await _recorder.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1));
    _sub = stream.listen((chunk) {
      _buf.add(chunk);
      if (_buf.length >= _pieceSeconds * _bytesPerSecond) _savePiece();
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
              body: jsonEncode({'text': text, 'source': _sessLang[_shownSess] ?? 'auto', 'target': _target}))
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
        if (j['error'] != null) _lastErr = '${j['error']}';
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
    if (_flushing) return;
    _flushing = true;
    try {
      final d = await _dir();
      final files = d.listSync().whereType<File>().where((f) => f.path.endsWith('.wav')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      var netOk = true;
      for (final f in files) {
        final name = _name(f);
        final sess = int.tryParse(name.split('_').first) ?? 0;
        if (netOk) {
          try {
            final req = http.MultipartRequest('POST', Uri.parse('${_url.text.trim()}/transcribe'))
              ..fields['lang'] = _sessLang[sess] ?? 'auto'
              ..fields['mine'] = _style.myLangs.join(',')
              ..fields['piece'] = name
              ..fields.addAll(_style.hints().isEmpty ? {} : {'hints': _style.hints()})
              ..files.add(await http.MultipartFile.fromPath('audio', f.path));
            final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 70)));
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
            _lastErr = e.toString().replaceFirst('Exception: ', '');
          }
        }
        // no network: rough on-device text so the words are visible right away
        if (_asr.ready && !_pieceText.containsKey(name)) {
          try {
            final t = await _asr.transcribe(f.path, _whisper[_sessLang[sess]] ?? '');
            _pieceText[name] = t;
            _rough.add(name);
            if (mounted) setState(_refreshText);
          } catch (_) {}
        }
      }
      final left = d.listSync().where((f) => f.path.endsWith('.wav')).length;
      if (_bubbleSession && !_recording && left == 0 && _text.isNotEmpty) {
        // started from the bubble: put the finished text on the clipboard, ready to paste
        _bubbleSession = false;
        final typed = await _typeInto(_text);
        if (!typed) await Clipboard.setData(ClipboardData(text: _text));
        if (mounted) {
          setState(() => _info = typed ? 'Typed into the text box.' : 'Copied. Paste it (turn on typing in settings to skip this).');
        }
        if (_readBack) await _sayBack(_text, _sessLang[_shownSess]);
        _tellBubble('done');
        Future.delayed(const Duration(seconds: 3), () => _tellBubble('idle'));
      }
      if (_talk && _awaitingReply && !_recording && left == 0) {
        _awaitingReply = false;
        if (_text.trim().isEmpty) {
          await _start();
        } else {
          unawaited(_agentTurn());
        }
      }
      if (left > 0 && mounted) {
        setState(() => _info =
            '${_recording ? 'Recording. ' : ''}$left piece(s) saved on your phone, will retry. ${_asr.ready ? 'Showing a rough offline version. ' : ''}Last problem: ${_lastErr.isEmpty ? 'none yet' : _lastErr}');
      }
    } finally {
      _flushing = false;
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
    _recorder.dispose();
    _textCtl.dispose();
    _textFocus.dispose();
    _url.dispose();
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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: _url, decoration: const InputDecoration(labelText: 'Server address')),
              if (Platform.isAndroid) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_nativeOn ? 'Typing into other apps: on' : 'Typing into other apps: off'),
                  subtitle: const Text('Turn on "Tilda typing" in Accessibility. If it is greyed out: App info, three dots, Allow restricted settings.'),
                  trailing: TextButton(
                    onPressed: () => _native.invokeMethod('settings'),
                    child: const Text('Open'),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Bubble only on text boxes'),
                  subtitle: const Text('Shows when you tap a text box in any app, hides after.'),
                  value: _autoBubble,
                  onChanged: (v) {
                    setSheet(() => _autoBubble = v);
                    _native.invokeMethod('auto', v).catchError((_) {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Read it back to me'),
                  subtitle: const Text('Speaks the typed text aloud so you can check it by ear.'),
                  value: _readBack,
                  onChanged: (v) => setSheet(() => _readBack = v),
                ),
              ],
              const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(top: 12, bottom: 4), child: Text('Languages I speak'))),
              Wrap(spacing: 8, children: [
                for (final e in const {
                  'hi-IN': 'Hindi', 'od-IN': 'Odia', 'en-IN': 'English', 'bn-IN': 'Bengali', 'te-IN': 'Telugu',
                  'ta-IN': 'Tamil', 'kn-IN': 'Kannada', 'ml-IN': 'Malayalam', 'mr-IN': 'Marathi',
                  'gu-IN': 'Gujarati', 'pa-IN': 'Punjabi'
                }.entries)
                  FilterChip(
                    label: Text(e.value),
                    selected: _style.myLangs.contains(e.key),
                    onSelected: (v) async {
                      setSheet(() => v ? _style.myLangs.add(e.key) : _style.myLangs.remove(e.key));
                      await _style.save();
                    },
                  ),
              ]),
              if (!_asr.ready)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    onPressed: _dl == null ? _downloadModel : null,
                    child: Text(_dl == null
                        ? 'Download offline model (about 150 MB, once)'
                        : 'Downloading ${(_dl! * 100).round()}%'),
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send my word list as a hint'),
                subtitle: Text('Your own names and words help the engines. Sent with each recording only, never stored. ${_style.vocab.length} word(s).'),
                value: _style.shareHints,
                onChanged: (v) async {
                  setSheet(() => _style.shareHints = v);
                  await _style.save();
                  setState(() {});
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Train a private model of my voice'),
                subtitle: const Text('Keeps the recordings you review, only on this phone.'),
                value: _style.keepAudio,
                onChanged: (v) async {
                  setSheet(() => _style.keepAudio = v);
                  await _style.save();
                  setState(() {});
                },
              ),
              TextButton(
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
            ]),
          ),
        ),
      ),
    );
  }

  /// One screen, no scrolling: everything a screenshot needs is visible at once.
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Tilda'),
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
                    value: _target,
                    items: [
                      for (final e in _targets.entries) DropdownMenuItem(value: e.key, child: Text('Translate to ${e.value}'))
                    ],
                    onChanged: (v) => setState(() => _target = v ?? _target),
                  ),
                ),
                const SizedBox(width: 8),
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
