import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Every language the server can work with.
const kLangs = {
  'en-IN': 'English', 'hi-IN': 'Hindi', 'te-IN': 'Telugu', 'ta-IN': 'Tamil', 'kn-IN': 'Kannada',
  'ml-IN': 'Malayalam', 'mr-IN': 'Marathi', 'gu-IN': 'Gujarati', 'bn-IN': 'Bengali', 'pa-IN': 'Punjabi',
  'od-IN': 'Odia', 'as-IN': 'Assamese', 'ur-IN': 'Urdu', 'ne-IN': 'Nepali', 'kok-IN': 'Konkani',
  'mai-IN': 'Maithili', 'doi-IN': 'Dogri', 'ks-IN': 'Kashmiri', 'sd-IN': 'Sindhi', 'sa-IN': 'Sanskrit',
  'sat-IN': 'Santali', 'mni-IN': 'Manipuri', 'brx-IN': 'Bodo',
};

/// The one place the server address lives. Settings can change it.
class Api {
  static String base = 'https://tilda-backend-opfj.onrender.com';

  /// Slow internet: switched on by hand in Settings, or by itself when uploads take too long (2G).
  static bool saver = false;
  static bool slowSeen = false;
  static bool get slow => saver || slowSeen;

  /// Called with how long a small upload took, to notice a slow network and to notice it getting better.
  static void noteSpeed(Duration d) {
    if (d.inSeconds > 12) {
      slowSeen = true;
    } else if (d.inSeconds < 4) {
      slowSeen = false;
    }
  }

  static Future<void> wake() async {
    try {
      await http.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  /// Speech to text. [lang] is a code like hi-IN, or 'auto' to let the server find the language.
  static Future<Map<String, dynamic>> transcribe(Uint8List wav, String lang, List<String> mine, {bool fast = false, String ext = 'wav'}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/transcribe'))
      ..fields['lang'] = lang
      ..fields['mine'] = mine.join(',')
      ..fields['piece'] = 'n${DateTime.now().microsecondsSinceEpoch}'
      ..files.add(http.MultipartFile.fromBytes('audio', wav, filename: 'a.$ext'));
    if (fast) req.fields['fast'] = '1';
    final t0 = DateTime.now();
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 60)));
    noteSpeed(DateTime.now().difference(t0));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (j['error'] != null) throw Exception('${j['error']}');
    return j;
  }

  static Future<String> translate(String text, String source, String target) async {
    final res = await http
        .post(Uri.parse('$base/translate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': text, 'source': source, 'target': target}))
        .timeout(const Duration(seconds: 25));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (j['error'] != null) throw Exception('${j['error']}');
    return (j['text'] ?? '') as String;
  }

  static Future<String> translit(String text, String source, String target) async {
    final res = await http
        .post(Uri.parse('$base/translit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': text, 'source': source, 'target': target}))
        .timeout(const Duration(seconds: 25));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (j['error'] != null) throw Exception('${j['error']}');
    return (j['text'] ?? '') as String;
  }

  static Future<String> summary(String text, String lang) async {
    final res = await http
        .post(Uri.parse('$base/summary'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'text': text, 'lang': lang}))
        .timeout(const Duration(seconds: 60));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (j['error'] != null) throw Exception('${j['error']}');
    return (j['text'] ?? '') as String;
  }

  /// Sarvam voice as audio bytes, or null if the server voice is not available.
  static Future<Uint8List?> speak(String text, String lang, {String? pan}) async {
    if (slow) return null; // slow internet: the phone's own voice, nothing to download
    try {
      final res = await http
          .post(Uri.parse('$base/speak'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'text': text, 'lang': lang, if (pan != null) 'pan': pan}))
          .timeout(const Duration(seconds: 40));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final a = j['audio'] as String?;
      return a == null ? null : base64Decode(a);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> sendFeedback(String kind, String text, String lang) async {
    try {
      final res = await http
          .post(Uri.parse('$base/feedback'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'kind': kind, 'text': text, 'lang': lang}))
          .timeout(const Duration(seconds: 20));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// One conversation turn, streamed: each event is {text, audio?, intent?, error?}.
  static Stream<Map<String, dynamic>> talk(List<Map<String, String>> messages, String lang, {double? lat, double? lon}) async* {
    final req = http.Request('POST', Uri.parse('$base/talk'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'messages': messages, 'lang': lang, 'voice': !slow, if (lat != null) 'lat': lat, if (lon != null) 'lon': lon});
    final resp = await http.Client().send(req).timeout(const Duration(seconds: 60));
    await for (final line in resp.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      yield jsonDecode(line) as Map<String, dynamic>;
    }
  }
}

Uint8List pcmToWav(Uint8List pcm) {
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
  h.setUint32(28, 32000, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...pcm]);
}

/// 8-bit, 8 kHz copy of a 16-bit, 16 kHz WAV: a quarter of the size, for very slow networks.
Uint8List slimWav(Uint8List wav) {
  if (wav.length <= 44) return wav;
  int mulaw(int s) {
    const bias = 0x84, clip = 32635;
    var sign = 0;
    if (s < 0) {
      s = -s;
      sign = 0x80;
    }
    if (s > clip) s = clip;
    s += bias;
    var exp = 7;
    for (var mask = 0x4000; (s & mask) == 0 && exp > 0; mask >>= 1) {
      exp--;
    }
    final mant = (s >> (exp + 3)) & 0x0F;
    return (~(sign | (exp << 4) | mant)) & 0xFF;
  }

  final bd = ByteData.sublistView(wav, 44);
  final n = (wav.length - 44) ~/ 2;
  final out = Uint8List(n ~/ 2);
  for (var i = 0; i + 1 < n; i += 2) {
    final a = bd.getInt16(i * 2, Endian.little), b = bd.getInt16((i + 1) * 2, Endian.little);
    out[i ~/ 2] = mulaw((a + b) ~/ 2);
  }
  final h = ByteData(46);
  void tag(int o, String t) {
    for (var k = 0; k < 4; k++) {
      h.setUint8(o + k, t.codeUnitAt(k));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 38 + out.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 18, Endian.little);
  h.setUint16(20, 7, Endian.little); // G.711 mu-law
  h.setUint16(22, 1, Endian.little);
  h.setUint32(24, 8000, Endian.little);
  h.setUint32(28, 8000, Endian.little);
  h.setUint16(32, 1, Endian.little);
  h.setUint16(34, 8, Endian.little);
  h.setUint16(36, 0, Endian.little);
  tag(38, 'data');
  h.setUint32(42, out.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...out]);
}

/// A microphone that records small compressed audio (Opus, about 2 KB per second, ten times smaller
/// than plain WAV) and reports how loud it is. Small recordings are what make Tilda work on 2G.
class Mic {
  Mic({this.clean = true});

  /// Echo and noise cancelling help when you talk to the phone, but they would also remove a video's sound, so Notes turns them off.
  final bool clean;
  final _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _amp;
  String? _path;
  DateTime _t0 = DateTime.now();
  bool _on = false;
  void Function(double)? _lv;

  /// File type of what comes out: ogg (Opus) or m4a on older phones.
  String ext = 'ogg';
  bool get on => _on;
  double get seconds => _on ? DateTime.now().difference(_t0).inMilliseconds / 1000 : 0;

  /// dB below full scale (as the recorder reports it) to a loudness between 0 and 1.
  static double level(double db) => db.isFinite ? math.pow(10, db / 20).toDouble() : 0.0;

  Future<bool> permit() => _rec.hasPermission();

  Future<bool> start(void Function(double level) onLevel) async {
    if (_on) return true;
    if (!await _rec.hasPermission()) return false;
    _lv = onLevel;
    await _begin();
    return true;
  }

  Future<void> _begin() async {
    final dir = await getTemporaryDirectory();
    final opus = await _rec.isEncoderSupported(AudioEncoder.opus);
    ext = opus ? 'ogg' : 'm4a';
    final path = '${dir.path}/tilda_${DateTime.now().microsecondsSinceEpoch}.$ext';
    await _rec.start(
        RecordConfig(encoder: opus ? AudioEncoder.opus : AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1, bitRate: 20000, echoCancel: clean, noiseSuppress: clean, autoGain: clean, audioInterruption: AudioInterruptionMode.none),
        path: path);
    _path = path;
    _t0 = DateTime.now();
    _on = true;
    await _amp?.cancel();
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) => _lv?.call(level(a.current)));
  }

  Future<Uint8List> _end() async {
    await _amp?.cancel();
    _amp = null;
    String? p;
    try {
      p = await _rec.stop();
    } catch (_) {}
    p ??= _path;
    _on = false;
    if (p == null) return Uint8List(0);
    final f = File(p);
    try {
      final b = await f.readAsBytes();
      await f.delete();
      return b;
    } catch (_) {
      return Uint8List(0);
    }
  }

  Future<Uint8List> stop() async {
    if (!_on) return Uint8List(0);
    return _end();
  }

  /// Hands back everything recorded so far and carries on recording (Notes does this every few seconds).
  Future<Uint8List> rotate() async {
    final b = await _end();
    await _begin();
    return b;
  }

  Future<void> dispose() async {
    await stop();
    await _rec.dispose();
  }
}
