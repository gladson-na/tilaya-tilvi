import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
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

  static Future<void> wake() async {
    try {
      await http.get(Uri.parse('$base/health')).timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  /// Speech to text. [lang] is a code like hi-IN, or 'auto' to let the server find the language.
  static Future<Map<String, dynamic>> transcribe(Uint8List wav, String lang, List<String> mine, {bool fast = false}) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/transcribe'))
      ..fields['lang'] = lang
      ..fields['mine'] = mine.join(',')
      ..fields['piece'] = 'n${DateTime.now().microsecondsSinceEpoch}'
      ..files.add(http.MultipartFile.fromBytes('audio', wav, filename: 'a.wav'));
    if (fast) req.fields['fast'] = '1';
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 45)));
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
  static Future<Uint8List?> speak(String text, String lang) async {
    try {
      final res = await http
          .post(Uri.parse('$base/speak'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'text': text, 'lang': lang}))
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
      ..body = jsonEncode({'messages': messages, 'lang': lang, if (lat != null) 'lat': lat, if (lon != null) 'lon': lon});
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

/// A microphone that reports how loud it is and hands back finished recordings as WAV.
class Mic {
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final _buf = BytesBuilder(copy: false);
  bool get on => _sub != null;
  int get bytes => _buf.length;

  /// Loudness of a 16-bit mono chunk, 0 (silent) to 1.
  static double level(Uint8List c) {
    final n = c.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.sublistView(c);
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      final v = bd.getInt16(i * 2, Endian.little);
      s += v * v;
    }
    return math.sqrt(s / n) / 32768;
  }

  Future<bool> start(void Function(double level) onLevel) async {
    if (on) return true;
    if (!await _rec.hasPermission()) return false;
    _buf.clear();
    final s = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1));
    _sub = s.listen((c) {
      _buf.add(c);
      onLevel(level(c));
    });
    return true;
  }

  /// What has been recorded so far as a WAV; recording carries on.
  Uint8List take() {
    final b = _buf.takeBytes();
    return pcmToWav(b);
  }

  Future<Uint8List> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _rec.stop();
    } catch (_) {}
    return take();
  }

  Future<void> dispose() async {
    await stop();
    await _rec.dispose();
  }
}
