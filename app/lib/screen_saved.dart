import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'store.dart';
import 'widgets.dart';

/// Every note and every Capture photo, newest first, kept on this phone.
class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    Store.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  String _when(DateTime d) {
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${d.day} ${m[d.month - 1]}, $h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    final items = Store.items;
    return Scaffold(
      backgroundColor: kNavy,
      appBar: AppBar(title: const Text('Saved')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('Nothing saved yet. Your notes and Capture photos will appear here.',
                        textAlign: TextAlign.center, style: TextStyle(color: kSub, fontSize: 18, height: 1.4)),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final it = items[i];
                    return Material(
                      color: kMint,
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SavedDetail(item: it)));
                          if (mounted) setState(() {});
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(children: [
                            Icon(it.kind == 'photo' ? Icons.photo_camera_outlined : Icons.notes, color: kPrimary, size: 28),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(it.title.isEmpty ? (it.kind == 'photo' ? 'Photo' : 'Notes') : it.title,
                                    maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kInk, fontSize: 18, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                Text(_when(it.when), style: const TextStyle(color: kSub, fontSize: 14)),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class SavedDetail extends StatefulWidget {
  final SavedItem item;
  const SavedDetail({super.key, required this.item});

  @override
  State<SavedDetail> createState() => _SavedDetailState();
}

class _SavedDetailState extends State<SavedDetail> {
  File? _photo;
  late String _tab;

  static const _names = {'spoken': 'As spoken', 'letters': 'Second copy', 'meaning': 'Meaning', 'summary': 'Summary', 'text': 'Text', 'original': 'Original'};

  @override
  void initState() {
    super.initState();
    final keys = widget.item.parts.entries.where((e) => e.value.trim().isNotEmpty).map((e) => e.key).toList();
    _tab = keys.contains('summary') ? 'summary' : (keys.isNotEmpty ? keys.first : '');
    Store.photoFile(widget.item).then((f) {
      if (mounted) setState(() => _photo = f);
    });
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.item.parts.entries.where((e) => e.value.trim().isNotEmpty).map((e) => e.key).toList();
    final text = widget.item.parts[_tab] ?? '';
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: Text(widget.item.kind == 'photo' ? 'Photo' : 'Notes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy',
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Delete this?'),
                  content: const Text('It will be removed from this phone.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await Store.remove(widget.item);
                if (context.mounted) Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_photo != null)
              ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(_photo!, height: 170, fit: BoxFit.cover)),
            if (keys.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(spacing: 8, children: [
                  for (final k in keys) ChoiceChip(label: Text(_names[k] ?? k), selected: _tab == k, onSelected: (_) => setState(() => _tab = k)),
                ]),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(16)),
                child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(color: kInk, fontSize: 19, height: 1.45))),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
