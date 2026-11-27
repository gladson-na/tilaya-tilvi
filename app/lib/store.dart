import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Everything Tilda makes for you stays on this phone: notes (with their copies and summary) and Capture photos.
/// One small file for the list, one folder for the pictures. Nothing here is sent anywhere.
class SavedItem {
  final String id; // time in milliseconds, also the sort order
  String kind; // 'note' or 'photo'
  String title;
  Map<String, String> parts; // note: spoken, letters, meaning, summary. photo: text, original
  String lang;
  String? photo; // file name inside the pictures folder
  SavedItem({required this.id, required this.kind, required this.title, Map<String, String>? parts, this.lang = '', this.photo})
      : parts = parts ?? {};

  DateTime get when => DateTime.fromMillisecondsSinceEpoch(int.tryParse(id) ?? 0);

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind, 'title': title, 'parts': parts, 'lang': lang, 'photo': photo};

  static SavedItem fromJson(Map<String, dynamic> j) => SavedItem(
        id: '${j['id']}',
        kind: '${j['kind'] ?? 'note'}',
        title: '${j['title'] ?? ''}',
        parts: ((j['parts'] ?? {}) as Map).map((k, v) => MapEntry('$k', '$v')),
        lang: '${j['lang'] ?? ''}',
        photo: j['photo'] as String?,
      );
}

class Store {
  static final List<SavedItem> items = [];
  static bool _loaded = false;
  static Directory? _dir;

  static Future<Directory> _d() async => _dir ??= await getApplicationDocumentsDirectory();

  /// Set when the last save failed (full storage, for example), so the screens can say so instead of showing a false "Saved".
  static String? lastError;
  static Future<void> _chain = Future.value();
  static int _lastId = 0;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = File('${(await _d()).path}/tilda_saved.json');
    try {
      if (!f.existsSync()) return;
      final l = jsonDecode(await f.readAsString()) as List;
      items
        ..clear()
        ..addAll(l.map((e) => SavedItem.fromJson(e as Map<String, dynamic>)));
      items.sort((a, b) => b.id.compareTo(a.id));
    } catch (_) {
      // an unreadable list is kept aside, never overwritten by the next save
      try {
        f.renameSync('${f.path}.damaged');
      } catch (_) {}
    }
  }

  /// Saves go one after the other, so two quick saves cannot write over each other.
  static Future<bool> _write() {
    final done = Completer<bool>();
    _chain = _chain.then((_) async {
      try {
        final f = File('${(await _d()).path}/tilda_saved.json');
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()), flush: true);
        await tmp.rename(f.path); // a half-written file never replaces a good one
        lastError = null;
        done.complete(true);
      } catch (e) {
        lastError = 'Could not save on this phone. Free some space and try again.';
        done.complete(false);
      }
    });
    return done.future;
  }

  /// Ids are the time in milliseconds, but never the same twice, even for two saves in one millisecond.
  static String newId() {
    var n = DateTime.now().millisecondsSinceEpoch;
    if (n <= _lastId) n = _lastId + 1;
    _lastId = n;
    return '$n';
  }

  /// Adds the item, or replaces the one with the same id (notes are saved again after every new sentence).
  static Future<bool> put(SavedItem it) async {
    await load();
    final i = items.indexWhere((e) => e.id == it.id);
    if (i >= 0) {
      items[i] = it;
    } else {
      items.insert(0, it);
    }
    return _write();
  }

  static Future<String> savePhoto(String id, Uint8List bytes) async {
    final dir = Directory('${(await _d()).path}/tilda_photos');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final name = '$id.jpg';
    await File('${dir.path}/$name').writeAsBytes(bytes, flush: true);
    return name;
  }

  static Future<File?> photoFile(SavedItem it) async {
    if (it.photo == null) return null;
    final f = File('${(await _d()).path}/tilda_photos/${it.photo}');
    return f.existsSync() ? f : null;
  }

  static Future<void> remove(SavedItem it) async {
    items.removeWhere((e) => e.id == it.id);
    final f = await photoFile(it);
    if (f != null) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    await _write();
  }
}
