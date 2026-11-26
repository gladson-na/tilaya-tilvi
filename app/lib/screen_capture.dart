import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';

import 'api.dart';
import 'personal_style.dart';
import 'widgets.dart';

/// Point the phone at a sign, a medicine strip or a bill: Tilda reads it, translates it and says it out loud.
class CaptureScreen extends StatefulWidget {
  final PersonalStyle style;
  final bool autoStart; // opened by voice ("read this"): the camera opens at once
  const CaptureScreen({super.key, required this.style, this.autoStart = false});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  static const _names = {
    'en-IN': 'English', 'hi-IN': 'हिन्दी', 'od-IN': 'ଓଡ଼ିଆ', 'bn-IN': 'বাংলা', 'te-IN': 'తెలుగు', 'ta-IN': 'தமிழ்',
    'kn-IN': 'ಕನ್ನಡ', 'ml-IN': 'മലയാളം', 'mr-IN': 'मराठी', 'gu-IN': 'ગુજરાતી', 'pa-IN': 'ਪੰਜਾਬੀ',
  };

  final _player = AudioPlayer();
  final _tts = FlutterTts();
  OrbState _orb = OrbState.idle;
  String _lang = 'en-IN';
  String _text = '', _original = '', _error = '';
  Uint8List? _photo;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final mine = widget.style.myLangs.where(_names.containsKey).toList();
    _lang = mine.isNotEmpty ? mine.first : 'en-IN';
    if (widget.autoStart) WidgetsBinding.instance.addPostFrameCallback((_) => _take());
  }

  @override
  void dispose() {
    _player.dispose();
    _tts.stop();
    super.dispose();
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  Future<void> _take() async {
    if (_busy) return;
    _busy = true;
    try {
      await _player.stop();
      await _tts.stop();
      final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1400, imageQuality: 72);
      if (x == null) {
        _set(() => _orb = OrbState.idle);
        return;
      }
      final bytes = await x.readAsBytes();
      _set(() {
        _photo = bytes;
        _text = '';
        _original = '';
        _error = '';
        _orb = OrbState.reading;
      });
      final j = await Api.readPhoto(base64Encode(bytes), _lang);
      final t = (j['text'] ?? '') as String;
      _set(() {
        _text = t;
        _original = (j['original'] ?? '') as String;
        _error = t.isEmpty ? 'I could not find any words in that photo. Please try again, closer and in good light.' : '';
        _orb = t.isEmpty ? OrbState.idle : OrbState.speaking;
      });
      await _say(t.isEmpty ? _error : t);
    } catch (_) {
      _set(() => _error = 'I could not read that just now. Please check the internet and try again.');
    } finally {
      _busy = false;
      _set(() => _orb = OrbState.idle);
    }
  }

  Future<void> _say(String text) async {
    if (text.isEmpty) return;
    final spoken = text.length > 700 ? text.substring(0, 700) : text;
    try {
      final b = await Api.speak(spoken, _lang);
      if (b != null) {
        final done = _player.onPlayerComplete.first;
        await _player.play(BytesSource(b));
        await done.timeout(const Duration(seconds: 90));
        return;
      }
      await _tts.setLanguage(_lang == 'od-IN' ? 'or-IN' : _lang);
      await _tts.speak(spoken);
    } catch (_) {}
  }

  Future<void> _listenAgain() async {
    if (_text.isEmpty) return;
    _set(() => _orb = OrbState.speaking);
    await _say(_text);
    _set(() => _orb = OrbState.idle);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kNavy,
        appBar: AppBar(
          backgroundColor: kNavy,
          foregroundColor: Colors.white,
          elevation: 0,
          title: const Text('Capture', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Column(children: [
              SizedBox(
                height: 46,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final l in widget.style.myLangs.where(_names.containsKey))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_names[l]!, style: const TextStyle(fontSize: 16)),
                        selected: _lang == l,
                        onSelected: (_) => _set(() => _lang = l),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(children: [
                    if (_photo != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.memory(_photo!, height: 170, width: double.infinity, fit: BoxFit.cover),
                      ),
                    const SizedBox(height: 10),
                    if (_orb == OrbState.reading) const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator()),
                    if (_text.isNotEmpty)
                      SelectableText(_text, style: const TextStyle(color: Colors.white, fontSize: 28, height: 1.35, fontWeight: FontWeight.w600)),
                    if (_error.isNotEmpty)
                      Text(_error, style: const TextStyle(color: Colors.white70, fontSize: 20, height: 1.35)),
                    if (_original.isNotEmpty && _text.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(_original, style: const TextStyle(color: Colors.white38, fontSize: 15)),
                    ],
                    if (_photo == null && _error.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 60),
                        child: Icon(Icons.photo_camera, color: Colors.white24, size: 120),
                      ),
                  ]),
                ),
              ),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _take,
                    icon: const Icon(Icons.photo_camera, size: 30),
                    label: Text(_photo == null ? 'Take photo' : 'Again', style: const TextStyle(fontSize: 20)),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64), backgroundColor: kBlue),
                  ),
                ),
                if (_text.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  IconButton.filled(
                    onPressed: _listenAgain,
                    icon: const Icon(Icons.volume_up, size: 30),
                    style: IconButton.styleFrom(minimumSize: const Size(64, 64), backgroundColor: kTeal, foregroundColor: Colors.black),
                  ),
                ],
              ]),
            ]),
          ),
        ),
      );
}
