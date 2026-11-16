import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A private correction memory. When the user fixes the transcript, we remember
/// "heard X, meant Y" and apply it to later transcripts. It lives only in a file on
/// this device: nothing here is ever sent to the server.
class PersonalStyle {
  final Map<String, String> fixes = {}; // lower-case heard text -> what the user meant
  File? _file;

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
    } catch (_) {}
  }

  Future<void> _save() async {
    final f = await _f();
    await f.writeAsString(jsonEncode({'fixes': fixes}), flush: true);
  }

  /// Delete everything that was learned.
  Future<void> forget() async {
    fixes.clear();
    final f = await _f();
    if (f.existsSync()) await f.delete();
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
    if (learned > 0) await _save();
    return learned;
  }

  int _remember(String heard, String meant) {
    if (heard.isEmpty || meant.isEmpty || heard == meant.toLowerCase() && heard == meant) return 0;
    if (fixes.length >= 2000 && !fixes.containsKey(heard)) return 0;
    final isNew = fixes[heard] != meant;
    fixes[heard] = meant;
    return isNew ? 1 : 0;
  }
}
