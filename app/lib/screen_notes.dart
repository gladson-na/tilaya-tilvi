import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'personal_style.dart';
import 'screen_saved.dart';
import 'store.dart';
import 'widgets.dart';

const _native = MethodChannel('tilda/native');

/// Listens to a class or video and writes it down as spoken, with two optional extras.
class NotesScreen extends StatefulWidget {
  final PersonalStyle style;
  const NotesScreen({super.key, required this.style});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _mic = Mic(clean: false);
  bool _internal = false; // recording the phone's own sound instead of the microphone
  DateTime _capT0 = DateTime.now();
  Timer? _lvlT;
  Timer? _cut;
  bool _on = false;
  bool _quiet = false;
  int _tab = 0;
  String _spoken = '', _lettersText = '', _meaningText = '', _summary = '';
  String _src = 'auto';
  String _status = 'Tap start, then play your class or video.';
  DateTime _lastLoud = DateTime.now();
  final _waiting = <Uint8List>[]; // recordings not yet turned into text (kept if the network drops)
  bool _working = false;
  bool _rotating = false;
  double _lvl = 0;
  bool _summarising = false;
  String _id = Store.newId(); // this note's place in the saved list

  String get _l2 => widget.style.copyLang; // second copy ('' = off)
  String get _l3 => widget.style.meaningLang; // translation ('' = off)
  String _name(String c) => kLangs[c] ?? c;

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  @override
  void initState() {
    super.initState();
    unawaited(Api.wake());
  }

  @override
  void dispose() {
    _cut?.cancel();
    _lvlT?.cancel();
    _mic.dispose();
    if (_on) _service(false);
    super.dispose();
  }

  Future<void> _service(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _native.invokeMethod(on ? 'notesOn' : 'notesOff');
    } catch (_) {}
  }

  Future<void> _start() async {
    if (!await _mic.permit()) {
      _set(() => _status = 'Please allow the microphone for Tilda.');
      return;
    }
    // First choice: the phone's own sound (works with the volume down, on Bluetooth, anywhere).
    _internal = false;
    if (Platform.isAndroid) {
      try {
        _internal = (await _native.invokeMethod('captureStart')) == true;
      } catch (_) {}
    }
    if (_internal) {
      _capT0 = DateTime.now();
      _lvlT = Timer.periodic(const Duration(milliseconds: 250), (_) async {
        try {
          final v = await _native.invokeMethod('captureLevel');
          if (v is num) _onLevel(v.toDouble());
        } catch (_) {}
      });
    } else {
      // Fallback: the microphone, which only hears what the speaker plays.
      if (!await _mic.start(_onLevel)) {
        _set(() => _status = 'Please allow the microphone for Tilda.');
        return;
      }
      await _service(true); // after the microphone is allowed: Android refuses a mic service before that
    }
    if (_spoken.isNotEmpty) {
      _id = Store.newId();
      _spoken = _lettersText = _meaningText = '';
    }
    _lastLoud = DateTime.now();
    _cut = Timer.periodic(const Duration(seconds: 2), (_) => _slice());
    _set(() {
      _on = true;
      _quiet = false;
      _summary = '';
      _tab = 0;
      _status = _internal ? 'Listening to the phone\'s sound. Notes are being written.' : 'Listening with the microphone. Notes are being written.';
    });
  }

  double get _secs => _internal ? DateTime.now().difference(_capT0).inMilliseconds / 1000 : _mic.seconds;

  Future<Uint8List> _rotate() async {
    if (!_internal) return _mic.rotate();
    _capT0 = DateTime.now();
    final p = await _native.invokeMethod<Uint8List>('captureTake');
    return p == null || p.length < 3200 ? Uint8List(0) : pcmToWav(p);
  }

  void _onLevel(double l) {
    _lvl = l;
    if (l > 0.006) _lastLoud = DateTime.now();
    final q = DateTime.now().difference(_lastLoud).inSeconds > 15;
    if (q != _quiet && mounted) {
      setState(() {
        _quiet = q;
        _status = q ? (_internal ? 'Nothing is playing. Start the video.' : 'I cannot hear anything. Is the video playing, and the volume up?') : 'Listening. Notes are being written.';
      });
    }
  }

  /// Every 10 to 20 seconds (waiting for a pause in the talking) the recording so far is sent off and a new one starts.
  Future<void> _slice() async {
    if (!(_internal || _mic.on) || _rotating) return;
    final t = _secs;
    if (t < 10 || (t < 20 && _lvl > 0.03)) return;
    _rotating = true;
    try {
      final b = await _rotate();
      if (b.length > 600) {
        _waiting.add(b);
        unawaited(_work());
      }
    } finally {
      _rotating = false;
    }
  }

  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (_waiting.isNotEmpty && mounted) {
        final wav = _waiting.first;
        try {
          final j = await Api.transcribe(wav, 'auto', widget.style.myLangs.toList(), fast: true, ext: (wav.length > 4 && wav[0] == 0x52 && wav[1] == 0x49) ? 'wav' : _mic.ext);
          _waiting.removeAt(0);
          final text = ((j['text'] ?? '') as String).trim();
          final lang = (j['language'] ?? 'auto') as String;
          if (lang != 'unknown') _src = lang;
          if (text.isEmpty) continue;
          _set(() => _spoken = _spoken.isEmpty ? text : '$_spoken $text');
          _keep();
          unawaited(_extras(text).then((_) => _keep()));
        } catch (_) {
          _set(() => _status = 'Waiting for the network. Your recording is kept.');
          if (_waiting.length > 40) _waiting.removeAt(0);
          break;
        }
      }
    } finally {
      _working = false;
    }
  }

  /// Saved after every new sentence, so leaving the screen never loses anything.
  void _keep() {
    if (_spoken.trim().isEmpty) return;
    final first = _spoken.trim().split(RegExp(r'\s+')).take(7).join(' ');
    unawaited(Store.put(SavedItem(
      id: _id,
      kind: 'note',
      title: first,
      lang: _src,
      parts: {'spoken': _spoken, 'letters': _lettersText, 'meaning': _meaningText, 'summary': _summary},
    )));
  }

  Future<void> _extras(String text) async {
    if (_l2.isNotEmpty) {
      try {
        final t = await Api.translit(text, _src, _l2);
        _set(() => _lettersText = _lettersText.isEmpty ? t : '$_lettersText $t');
      } catch (_) {}
    }
    if (_l3.isNotEmpty) {
      try {
        final t = await Api.translate(text, _src == 'auto' ? 'auto' : _src, _l3);
        _set(() => _meaningText = _meaningText.isEmpty ? t : '$_meaningText $t');
      } catch (_) {}
    }
  }

  /// Picking a language for the second copy or the translation ('' switches it off). Everything said so far is redone.
  void _pick(bool copy, String v) {
    if (copy) {
      widget.style.copyLang = v;
    } else {
      widget.style.meaningLang = v;
    }
    unawaited(widget.style.save());
    _set(() {
      if (copy) {
        _lettersText = '';
      } else {
        _meaningText = '';
      }
    });
    if (v.isNotEmpty) unawaited(_catchUp(letters: copy));
  }

  Future<void> _catchUp({required bool letters}) async {
    if (_spoken.isEmpty) return;
    try {
      if (letters) {
        final t = await Api.translit(_spoken, _src, _l2);
        _set(() => _lettersText = t);
      } else {
        final t = await Api.translate(_spoken, _src, _l3);
        _set(() => _meaningText = t);
      }
    } catch (_) {}
  }

  Future<void> _stop() async {
    _cut?.cancel();
    _lvlT?.cancel();
    final rest = _internal ? await _rotate() : await _mic.stop();
    await _service(false);
    if (rest.length > 600) _waiting.add(rest);
    _set(() {
      _on = false;
      _quiet = false;
      _summarising = true;
      _status = 'Making your notes...';
    });
    await _work();
    if (_spoken.trim().length < 20) {
      _set(() {
        _summarising = false;
        _status = 'Not enough was heard to make notes.';
      });
      return;
    }
    await _makeSummary();
  }

  Future<void> _makeSummary() async {
    _set(() {
      _summarising = true;
      _status = 'Making your notes...';
    });
    try {
      String? s;
      for (var i = 0; i < 3 && s == null; i++) {
        try {
          s = await Api.summary(_spoken, _l3.isNotEmpty ? _l3 : (_src == 'auto' ? 'en-IN' : _src));
        } catch (_) {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      if (s == null || s.trim().isEmpty) throw Exception('no summary');
      _set(() {
        _summary = s!;
        _tab = 3;
        _status = 'Your notes are ready and saved.';
      });
      _keep();
    } catch (_) {
      _set(() => _status = 'Could not make the summary just now. Your full notes are saved. Tap Make summary to try again.');
    } finally {
      _set(() => _summarising = false);
    }
  }

  Future<void> _toBackground() async {
    try {
      await _native.invokeMethod('toBack');
    } catch (_) {}
  }

  String get _shown => _tab == 0 ? _spoken : (_tab == 1 ? _lettersText : (_tab == 2 ? _meaningText : _summary));

  List<(int, String)> get _tabs => [
        (0, 'As spoken'),
        if (_l2.isNotEmpty) (1, 'In ${_name(_l2)}'),
        if (_l3.isNotEmpty) (2, '${_name(_l3)} meaning'),
        if (_summary.isNotEmpty) (3, 'Summary'),
      ];

  Widget _toggle(String label, String sub, bool v, void Function(bool) f) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        activeColor: kTeal,
        title: Text(label, style: const TextStyle(color: Colors.white)),
        subtitle: Text(sub, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        value: v,
        onChanged: f,
      );

  Widget _picker(String label, String value, void Function(String) f) => Row(children: [
        SizedBox(width: 150, child: Text(label, style: const TextStyle(color: Colors.white70))),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            isDense: true,
            dropdownColor: kCard,
            underline: const SizedBox.shrink(),
            value: value.isEmpty || !kLangs.containsKey(value) ? '' : value,
            style: const TextStyle(color: kTeal, fontSize: 17, fontWeight: FontWeight.w700),
            items: [
              const DropdownMenuItem(value: '', child: Text('Off', style: TextStyle(color: Colors.white54))),
              for (final e in kLangs.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => f(v ?? ''),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (!tabs.any((t) => t.$1 == _tab)) _tab = 0;
    return Scaffold(
      backgroundColor: kNavy,
      appBar: AppBar(backgroundColor: kNavy, foregroundColor: Colors.white, elevation: 0, title: const Text('Take notes'), actions: [IconButton(icon: const Icon(Icons.folder_open), tooltip: 'Saved', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedScreen())))]),
      body: GlowFrame(
        on: _on,
        quiet: _quiet,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16)),
                child: Column(children: [
                  Row(children: [
                    Icon(Icons.fiber_manual_record, size: 14, color: _on ? (_quiet ? Colors.grey : Colors.redAccent) : Colors.white38),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Written as spoken, in any language', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                  ]),
                  _picker('2nd copy, written in', _l2, (v) => _pick(true, v)),
                  _picker('Translation in', _l3, (v) => _pick(false, v)),
                ]),
              ),
              const SizedBox(height: 8),
              if (tabs.length > 1)
                Wrap(spacing: 8, children: [
                  for (final t in tabs) ChoiceChip(label: Text(t.$2), selected: _tab == t.$1, onSelected: (_) => _set(() => _tab = t.$1)),
                ]),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: kCard.withOpacity(0.7), borderRadius: BorderRadius.circular(16)),
                  child: SingleChildScrollView(
                    reverse: _on,
                    child: SelectableText(
                      _shown,
                      style: const TextStyle(color: Colors.white, fontSize: 17, height: 1.4),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(_status, textAlign: TextAlign.center, style: TextStyle(color: _quiet ? Colors.amberAccent : Colors.white70)),
              const SizedBox(height: 8),
              if (!_on && !_summarising && _spoken.trim().length >= 20 && _summary.isEmpty)
                TextButton.icon(onPressed: _makeSummary, icon: const Icon(Icons.auto_awesome), label: const Text('Make summary')),
              if (_on)
                OutlinedButton.icon(
                  onPressed: _toBackground,
                  icon: const Icon(Icons.ondemand_video),
                  label: const Text('Go watch my video (notes keep running)'),
                ),
              const SizedBox(height: 8),
              Row(children: [
                if (_summary.isNotEmpty || _spoken.isNotEmpty)
                  IconButton(
                    onPressed: () => Clipboard.setData(ClipboardData(text: _shown)),
                    icon: const Icon(Icons.copy, color: Colors.white70),
                    tooltip: 'Copy',
                  ),
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _on ? Colors.redAccent : kTeal, foregroundColor: Colors.black),
                      onPressed: _summarising ? null : (_on ? _stop : _start),
                      child: Text(_on ? 'Stop and make notes' : (_spoken.isEmpty ? 'Start notes' : 'Start again'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
