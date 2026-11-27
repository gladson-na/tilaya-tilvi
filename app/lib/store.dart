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

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File('${(await _d()).path}/tilda_saved.json');
      if (!f.existsSync()) return;
      final l = jsonDecode(await f.readAsString()) as List;
      items
        ..clear()
        ..addAll(l.map((e) => SavedItem.fromJson(e as Map<String, dynamic>)));
      items.sort((a, b) => b.id.compareTo(a.id));
    } catch (_) {}
  }

  static Future<void> _write() async {
    try {
      final f = File('${(await _d()).path}/tilda_saved.json');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
      await tmp.rename(f.path); // a half-written file never replaces a good one
    } catch (_) {}
  }

  static String newId() => '${DateTime.now().millisecondsSinceEpoch}';

  /// Adds the item, or replaces the one with the same id (notes are saved again after every new sentence).
  static Future<void> put(SavedItem it) async {
    await load();
    final i = items.indexWhere((e) => e.id == it.id);
    if (i >= 0) {
      items[i] = it;
    } else {
      items.insert(0, it);
    }
    await _write();
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
