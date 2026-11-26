import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'personal_style.dart';
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
  final _mic = Mic();
  Timer? _cut;
  bool _on = false;
  bool _quiet = false;
  bool _letters = false; // also in the notes language's letters
  bool _meaning = false; // also the meaning in the notes language
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

  String get _nl => widget.style.notesLang;
  String get _nlName => kLangs[_nl] ?? 'Hindi';

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
    final ok = await _mic.start(_onLevel);
    if (!ok) {
      _set(() => _status = 'Please allow the microphone for Tilda.');
      return;
    }
    await _service(true); // after the microphone is allowed: Android refuses a mic service before that
    _lastLoud = DateTime.now();
    _cut = Timer.periodic(const Duration(seconds: 2), (_) => _slice());
    _set(() {
      _on = true;
      _quiet = false;
      _summary = '';
      _status = 'Listening. Notes are being written.';
    });
  }

  void _onLevel(double l) {
    _lvl = l;
    if (l > 0.006) _lastLoud = DateTime.now();
    final q = DateTime.now().difference(_lastLoud).inSeconds > 15;
    if (q != _quiet && mounted) {
      setState(() {
        _quiet = q;
        _status = q ? 'I cannot hear anything. Is the video playing, and the volume up?' : 'Listening. Notes are being written.';
      });
    }
  }

  /// Every 10 to 20 seconds (waiting for a pause in the talking) the recording so far is sent off and a new one starts.
  Future<void> _slice() async {
    if (!_mic.on || _rotating) return;
    final t = _mic.seconds;
    if (t < 10 || (t < 20 && _lvl > 0.03)) return;
    _rotating = true;
    try {
      final b = await _mic.rotate();
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
          final j = await Api.transcribe(wav, 'auto', widget.style.myLangs.toList(), fast: true, ext: _mic.ext);
          _waiting.removeAt(0);
          final text = ((j['text'] ?? '') as String).trim();
          final lang = (j['language'] ?? 'auto') as String;
          if (lang != 'unknown') _src = lang;
          if (text.isEmpty) continue;
          _set(() => _spoken = _spoken.isEmpty ? text : '$_spoken $text');
          unawaited(_extras(text));
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

  Future<void> _extras(String text) async {
    if (_letters) {
      try {
        final t = await Api.translit(text, _src, _nl);
        _set(() => _lettersText = _lettersText.isEmpty ? t : '$_lettersText $t');
      } catch (_) {}
    }
    if (_meaning) {
      try {
        final t = await Api.translate(text, _src == 'auto' ? 'auto' : _src, _nl);
        _set(() => _meaningText = _meaningText.isEmpty ? t : '$_meaningText $t');
      } catch (_) {}
    }
  }

  /// Changing the extra language right here: redo the extras that are switched on, in the new language.
  void _pickLang(String? v) {
    if (v == null || v == _nl) return;
    widget.style.notesLang = v;
    unawaited(widget.style.save());
    _set(() {
      _lettersText = '';
      _meaningText = '';
    });
    if (_letters) unawaited(_catchUp(letters: true));
    if (_meaning) unawaited(_catchUp(letters: false));
  }

  /// Turning an extra on halfway: write out everything said so far as well.
  Future<void> _catchUp({required bool letters}) async {
    if (_spoken.isEmpty) return;
    try {
      if (letters) {
        final t = await Api.translit(_spoken, _src, _nl);
        _set(() => _lettersText = t);
      } else {
        final t = await Api.translate(_spoken, _src, _nl);
        _set(() => _meaningText = t);
      }
    } catch (_) {}
  }

  Future<void> _stop() async {
    _cut?.cancel();
    final rest = await _mic.stop();
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
    try {
      final s = await Api.summary(_spoken, _nl);
      _set(() {
        _summary = s;
        _status = 'Your notes are ready.';
      });
    } catch (_) {
      _set(() => _status = 'Could not make the summary just now. Your full notes are saved below.');
    } finally {
      _set(() => _summarising = false);
    }
  }

  Future<void> _toBackground() async {
    try {
      await _native.invokeMethod('toBack');
    } catch (_) {}
  }

  String get _shown => _tab == 0 ? _spoken : (_tab == 1 ? _lettersText : _meaningText);

  List<(int, String)> get _tabs => [
        (0, 'As spoken'),
        if (_letters) (1, 'In $_nlName letters'),
        if (_meaning) (2, '$_nlName meaning'),
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

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (!tabs.any((t) => t.$1 == _tab)) _tab = 0;
    return Scaffold(
      backgroundColor: kNavy,
      appBar: AppBar(backgroundColor: kNavy, foregroundColor: Colors.white, elevation: 0, title: const Text('Take notes')),
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
                  Row(children: [
                    const Text('Extra notes in', style: TextStyle(color: Colors.white70)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        isDense: true,
                        dropdownColor: kCard,
                        underline: const SizedBox.shrink(),
                        value: kLangs.containsKey(_nl) ? _nl : 'hi-IN',
                        style: const TextStyle(color: kTeal, fontSize: 17, fontWeight: FontWeight.w700),
                        items: [for (final e in kLangs.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                        onChanged: _pickLang,
                      ),
                    ),
                  ]),
                  _toggle('Also in $_nlName letters', 'Same words, written in $_nlName script', _letters, (v) {
                    _set(() => _letters = v);
                    if (v) unawaited(_catchUp(letters: true));
                  }),
                  _toggle('Also translate to $_nlName', 'The meaning of the whole class', _meaning, (v) {
                    _set(() => _meaning = v);
                    if (v) unawaited(_catchUp(letters: false));
                  }),
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
                      _summary.isNotEmpty && !_on ? '$_summary\n\n---\n\n$_shown' : (_shown.isEmpty ? '' : _shown),
                      style: const TextStyle(color: Colors.white, fontSize: 17, height: 1.4),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(_status, textAlign: TextAlign.center, style: TextStyle(color: _quiet ? Colors.amberAccent : Colors.white70)),
              const SizedBox(height: 8),
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
                    onPressed: () => Clipboard.setData(ClipboardData(text: _summary.isNotEmpty ? '$_summary\n\n$_shown' : _shown)),
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
