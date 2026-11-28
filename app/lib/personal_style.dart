import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A private correction memory. When the user fixes the transcript, we remember
/// "heard X, meant Y" and apply it to later transcripts. It lives only in a file on
/// this device: nothing here is ever sent to the server.
class PersonalStyle {
  final Map<String, String> fixes = {}; // lower-case heard text -> what the user meant
  final Set<String> vocab = {}; // the user's own words and names (what they corrected to)
  bool shareHints = false; // send the word list as a hint with each recording (off by default)
  bool keepAudio = false; // keep reviewed recordings on this phone for later personal training (off by default)
  final Set<String> myLangs = {'hi-IN', 'od-IN', 'en-IN'}; // languages the user speaks; guides detection
  bool setupDone = false; // the first-run language question has been answered
  String copyLang = ''; // Notes: second copy of what was said, in this language's script ('' = off)
  String meaningLang = ''; // Notes: translation into this language ('' = off)
  String notesLang = 'hi-IN'; // the language notes are also written or translated into
  final Set<String> callWords = {'hey'}; // how this person likes to call Tilda: hey, ae, oye, o, arre, suno, ok
  final Set<String> callHeard = {}; // how the phone's speech engine actually wrote their calls (learned in practice)
  final Set<String> callTrained = {}; // call-words practised three times: these will work
  bool callDone = false; // the call-word choice and practice has been done or skipped
  bool firstDone = false; // the first successful dictation has happened
  double trainedSeconds = 0; // reviewed speech collected so far
  File? _file;
  Directory? _dataDir;

  int get count => fixes.length;

  Future<File> _f() async {
    if (_file != null) return _file!;
    final d = await getApplicationDocumentsDirectory();
    return _file = File('${d.path}/personal_style.json');
  }

  Future<void> load() async {
    try {
      final f = await _f();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      fixes
        ..clear()
        ..addAll((j['fixes'] as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String)));
      vocab
        ..clear()
        ..addAll(((j['vocab'] ?? []) as List).cast<String>());
      shareHints = j['shareHints'] == true;
      keepAudio = j['keepAudio'] == true;
      if (j['myLangs'] is List) {
        myLangs
          ..clear()
          ..addAll((j['myLangs'] as List).cast<String>());
      }
      firstDone = j['firstDone'] == true;
      callDone = j['callDone'] == true;
      if (j['callWords'] is List) {
        callWords
          ..clear()
          ..addAll((j['callWords'] as List).cast<String>());
      }
      if (j['callTrained'] is List) {
        callTrained
          ..clear()
          ..addAll((j['callTrained'] as List).cast<String>());
      }
      if (j['callHeard'] is List) {
        callHeard
          ..clear()
          ..addAll((j['callHeard'] as List).cast<String>());
      }
      setupDone = j['setupDone'] == true;
      if (j['notesLang'] is String) notesLang = j['notesLang'] as String;
      if (j['copyLang'] is String) copyLang = j['copyLang'] as String;
      if (j['meaningLang'] is String) meaningLang = j['meaningLang'] as String;
      trainedSeconds = ((j['trainedSeconds'] ?? 0) as num).toDouble();
    } catch (_) {}
  }

  Future<void> save() async {
    final f = await _f();
    await f.writeAsString(
        jsonEncode({
          'fixes': fixes,
          'vocab': vocab.toList(),
          'shareHints': shareHints,
          'keepAudio': keepAudio,
          'myLangs': myLangs.toList(),
          'firstDone': firstDone,
          'callDone': callDone,
          'callWords': callWords.toList(),
          'callHeard': callHeard.toList(),
          'callTrained': callTrained.toList(),
          'setupDone': setupDone,
          'notesLang': notesLang,
          'copyLang': copyLang,
          'meaningLang': meaningLang,
          'trainedSeconds': trainedSeconds,
        }),
        flush: true);
  }

  /// Short comma-separated word list for the speech engines. Empty unless the user allowed it.
  String hints() {
    if (!shareHints || vocab.isEmpty) return '';
    final out = <String>[];
    var len = 0;
    for (final w in vocab.toList().reversed) {
      if (len + w.length > 380) break;
      out.add(w);
      len += w.length + 2;
    }
    return out.join(', ');
  }

  Future<Directory> dataDir() async {
    if (_dataDir != null) return _dataDir!;
    final d = await getApplicationDocumentsDirectory();
    return _dataDir = await Directory('${d.path}/personal_data/audio').create(recursive: true);
  }

  /// Keeps a reviewed recording and its text, only on this phone, for later private training.
  /// Skips a piece that is already stored.
  Future<void> addTrainingPiece(File wav, String text) async {
    if (text.trim().isEmpty) return;
    final dir = await dataDir();
    final name = wav.uri.pathSegments.last;
    final manifest = File('${dir.parent.path}/manifest.jsonl');
    final seen = manifest.existsSync() ? await manifest.readAsString() : '';
    if (seen.contains('"audio":"audio/$name"')) return;
    final seconds = (await wav.length() - 44) / 32000.0;
    final target = File('${dir.path}/$name');
    if (wav.path != target.path) await wav.copy(target.path);
    await manifest.writeAsString(
        '${jsonEncode({'audio': 'audio/$name', 'text': text, 'seconds': seconds})}\n',
        mode: FileMode.append,
        flush: true);
    trainedSeconds += seconds;
    await save();
  }

  /// Delete everything that was learned.
  Future<void> forget() async {
    fixes.clear();
    vocab.clear();
    trainedSeconds = 0;
    final f = await _f();
    if (f.existsSync()) await f.delete();
    final d = await getApplicationDocumentsDirectory();
    final data = Directory('${d.path}/personal_data');
    if (data.existsSync()) await data.delete(recursive: true);
    _dataDir = null;
  }

  static final _edge = RegExp(r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$', unicode: true);

  /// Splits one word into (punctuation before, the word, punctuation after).
  static List<String> _parts(String token) {
    final lead = RegExp(r'^[\p{P}\p{S}]*', unicode: true).stringMatch(token) ?? '';
    final trail = RegExp(r'[\p{P}\p{S}]*$', unicode: true).stringMatch(token.substring(lead.length)) ?? '';
    return [lead, token.substring(lead.length, token.length - trail.length), trail];
  }

  static List<String> _words(String text) =>
      text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  static String _core(String token) => token.replaceAll(_edge, '').toLowerCase();

  /// Applies what was learned. Longest phrase (up to 3 words) wins.
  String apply(String text) {
    if (fixes.isEmpty || text.isEmpty) return text;
    final words = _words(text);
    final out = <String>[];
    var i = 0;
    while (i < words.length) {
      var done = false;
      for (var n = 3; n >= 1 && !done; n--) {
        if (i + n > words.length) continue;
        final key = words.sublist(i, i + n).map(_core).join(' ');
        final fix = fixes[key];
        if (fix != null && key.isNotEmpty) {
          out.add('${_parts(words[i])[0]}$fix${_parts(words[i + n - 1])[2]}');
          i += n;
          done = true;
        }
      }
      if (!done) out.add(words[i++]);
    }
    return out.join(' ');
  }

  /// Compares the text we showed with what the user changed it to, and remembers the swaps.
  /// Returns how many new corrections were learned.
  Future<int> learn(String shown, String corrected) async {
    final a = _words(shown), b = _words(corrected);
    final ac = a.map(_core).toList(), bc = b.map(_core).toList();
    // longest common subsequence of the two word lists
    final lcs = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (var i = a.length - 1; i >= 0; i--) {
      for (var j = b.length - 1; j >= 0; j--) {
        lcs[i][j] = ac[i] == bc[j] ? lcs[i + 1][j + 1] + 1 : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    var learned = 0;
    var i = 0, j = 0;
    while (i < a.length || j < b.length) {
      if (i < a.length && j < b.length && ac[i] == bc[j]) {
        i++;
        j++;
        continue;
      }
      final si = i, sj = j;
      while ((i < a.length || j < b.length) && !(i < a.length && j < b.length && ac[i] == bc[j])) {
        if (j >= b.length || (i < a.length && lcs[i + 1][j] >= lcs[i][j + 1])) {
          i++;
        } else {
          j++;
        }
      }
      final wrong = a.sublist(si, i), right = b.sublist(sj, j);
      if (wrong.isEmpty || right.isEmpty) continue; // pure delete or insert: nothing to learn
      if (wrong.length == right.length) {
        for (var k = 0; k < wrong.length; k++) {
          learned += _remember(_core(wrong[k]), right[k].replaceAll(_edge, ''));
        }
      } else if (wrong.length <= 3) {
        learned += _remember(wrong.map(_core).join(' '), right.map((w) => w.replaceAll(_edge, '')).join(' '));
      }
    }
    if (learned > 0) await save();
    return learned;
  }

  int _remember(String heard, String meant) {
    if (heard.isEmpty || meant.isEmpty || heard == meant.toLowerCase() && heard == meant) return 0;
    if (fixes.length >= 2000 && !fixes.containsKey(heard)) return 0;
    final isNew = fixes[heard] != meant;
    fixes[heard] = meant;
    if (meant.length > 1) vocab.add(meant);
    return isNew ? 1 : 0;
  }
}
