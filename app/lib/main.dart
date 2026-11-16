import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'offline_asr.dart';
import 'personal_style.dart';

void main() => runApp(const TildaApp());

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
  final _asr = OfflineAsr();
  final _style = PersonalStyle();
  final _textCtl = TextEditingController();
  final _textFocus = FocusNode();
  final _pieceText = <String, String>{}; // piece file name -> text
  final _kept = <String, File>{}; // pieces held for personal training until you review them
  final _rough = <String>{}; // pieces whose text is still the rough offline guess
  final _sessLang = <int, String>{};
  bool _online = true;
  double? _dl; // model download progress
  String _text = '';
  int _shownSess = 0;
  String _info = 'Say a greeting and the name first, e.g. "Namaskaram Tilda".';

  @override
  void initState() {
    super.initState();
    _retry = Timer.periodic(const Duration(seconds: 10), (_) => _flush());
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
    setState(() {
      _recording = true;
      _text = '';
      _info = 'Recording. Pieces are saved on your phone as you speak.';
    });
  }

  Future<void> _stop() async {
    if (!_recording) return;
    await _recorder.stop();
    await _sub?.cancel();
    await _savePiece();
    setState(() => _recording = false);
    await _flush();
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
              ..fields.addAll(_style.hints().isEmpty ? {} : {'hints': _style.hints()})
              ..files.add(await http.MultipartFile.fromPath('audio', f.path));
            final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 15)));
            final j = jsonDecode(res.body) as Map<String, dynamic>;
            if (j['error'] != null) throw Exception(j['error']);
            final lang = j['language'] as String?;
            if (lang != null && lang != 'unknown' && !_sessLang.containsKey(sess)) _sessLang[sess] = lang;
            if (_style.keepAudio) {
              // held on the phone until you review the text and tap "Save my correction"
              final keep = File('${d.path}/../kept_$name');
              await f.copy(keep.path);
              _kept[name] = keep;
            }
            await f.delete();
            _rough.remove(name);
            _pieceText[name] = (j['text'] ?? '') as String;
            _online = true;
            if (mounted) {
              setState(() {
                _refreshText();
                _info = 'Engine: ${j['engine']}\nLanguage: ${j['language']}\nGreeting found: ${j['greeting_found']}';
              });
            }
            continue;
          } catch (_) {
            netOk = false;
            _online = false;
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
      if (left > 0 && mounted) {
        setState(() => _info =
            '${_recording ? 'Recording. ' : ''}No network: $left piece(s) saved on your phone. ${_asr.ready ? 'Showing a rough offline version; ' : ''}the real text replaces it when the network returns.');
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tilda')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(labelText: 'Server address'),
            ),
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
            const SizedBox(height: 16),
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
                height: 96,
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
            const SizedBox(height: 16),
            TextField(
              controller: _textCtl,
              focusNode: _textFocus,
              maxLines: null,
              style: Theme.of(context).textTheme.headlineSmall,
              decoration: const InputDecoration(
                  hintText: 'Your words appear here. Fix anything wrong and tap "Save my correction".',
                  border: InputBorder.none),
            ),
            Row(children: [
              FilledButton.tonal(
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
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  await _style.forget();
                  setState(() {
                    _refreshText();
                    _info = 'Forgot everything it learned about you.';
                  });
                },
                child: const Text('Forget all'),
              ),
            ]),
            Text('Learned on this phone: ${_style.count} correction(s). Never sent anywhere.',
                style: Theme.of(context).textTheme.bodySmall),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Send my word list as a hint'),
              subtitle: Text('Your own names and words help the engines. Sent with each recording only, never stored. ${_style.vocab.length} word(s).'),
              value: _style.shareHints,
              onChanged: (v) async {
                setState(() => _style.shareHints = v);
                await _style.save();
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Train a private model of my voice'),
              subtitle: Text(
                  'Keeps the recordings you review, only on this phone. Collected: ${(_style.trainedSeconds / 60).toStringAsFixed(1)} of about 60 minutes needed to start.'),
              value: _style.keepAudio,
              onChanged: (v) async {
                setState(() => _style.keepAudio = v);
                await _style.save();
              },
            ),
            LinearProgressIndicator(value: (_style.trainedSeconds / 3600).clamp(0.0, 1.0)),
            const SizedBox(height: 12),
            Text(_info),
          ]),
        ),
      );
}
