import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'api.dart';
import 'personal_style.dart';
import 'screen_saved.dart';
import 'store.dart';
import 'widgets.dart';

/// A live camera inside Tilda. Point it at a sign, a medicine strip or a bill, tap the big button,
/// and Tilda reads the words, translates them into the language you pick, and says them out loud.
class CaptureScreen extends StatefulWidget {
  final PersonalStyle style;
  final bool autoStart; // opened by voice; the camera is live either way
  const CaptureScreen({super.key, required this.style, this.autoStart = false});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with WidgetsBindingObserver {
  final _player = AudioPlayer();
  final _tts = FlutterTts();
  CameraController? _cam;
  String _camError = '';
  OrbState _orb = OrbState.idle;
  String _lang = 'en-IN';
  String _text = '', _original = '', _error = '';
  Uint8List? _photo;
  bool _busy = false;
  bool _flash = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final mine = widget.style.myLangs.where(kLangs.containsKey).toList();
    _lang = mine.isNotEmpty ? mine.first : 'en-IN';
    Api.wake().ignore(); // the free server sleeps when idle: wake it while the camera opens
    _openCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cam?.dispose();
    _player.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive) {
      _cam?.dispose();
      _cam = null;
    } else if (s == AppLifecycleState.resumed && _cam == null && _photo == null) {
      _openCamera();
    }
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  Future<void> _openCamera() async {
    try {
      final all = await availableCameras();
      if (all.isEmpty) {
        _set(() => _camError = 'This phone has no camera Tilda can use.');
        return;
      }
      final back = all.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => all.first);
      final c = CameraController(back, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await c.initialize();
      try {
        await c.setFocusMode(FocusMode.auto);
      } catch (_) {}
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _cam = c;
        _camError = '';
      });
    } on CameraException catch (e) {
      _set(() => _camError = e.code.contains('Denied') || e.code.contains('Access')
          ? 'Please allow the camera for Tilda: Settings, Apps, Tilda, Permissions.'
          : 'The camera could not start. Please close other camera apps and try again.');
    } catch (_) {
      _set(() => _camError = 'The camera could not start. Please try again.');
    }
  }

  Future<void> _toggleFlash() async {
    final c = _cam;
    if (c == null) return;
    try {
      await c.setFlashMode(_flash ? FlashMode.off : FlashMode.torch);
      _set(() => _flash = !_flash);
    } catch (_) {}
  }

  Future<void> _shoot() async {
    final c = _cam;
    if (_busy || c == null || !c.value.isInitialized) return;
    _busy = true;
    try {
      await _player.stop();
      await _tts.stop();
      final x = await c.takePicture();
      final bytes = await x.readAsBytes();
      if (_flash) {
        try {
          await c.setFlashMode(FlashMode.off);
        } catch (_) {}
        _flash = false;
      }
      _set(() {
        _photo = bytes;
        _text = '';
        _original = '';
        _error = '';
        _orb = OrbState.reading;
      });
      Map<String, dynamic> j;
      try {
        try {
          j = await Api.readPhoto(base64Encode(bytes), _lang);
        } catch (_) {
          // the server may have been asleep: wake it and try once more before giving up
          await Api.wake();
          j = await Api.readPhoto(base64Encode(bytes), _lang);
        }
      } catch (e) {
        // No internet or the reader is busy: read the words on the phone itself, and say why
        await _readOffline(x.path, bytes, why: _why(e));
        return;
      }
      final t = (j['text'] ?? '') as String;
      final o = (j['original'] ?? '') as String;
      _set(() {
        _text = t;
        _original = o;
        _error = t.isEmpty ? 'I could not find any words. Move the phone closer, hold it steady, and use more light.' : '';
        _orb = t.isEmpty ? OrbState.idle : OrbState.speaking;
      });
      if (t.isNotEmpty) await _keep(bytes, t, o);
      await _say(t.isEmpty ? _error : t);
    } catch (_) {
      _set(() => _error = 'I could not read that just now. Please check the internet and try again.');
    } finally {
      _busy = false;
      _set(() => _orb = OrbState.idle);
    }
  }

  Future<void> _keep(Uint8List bytes, String text, String original) async {
    try {
      final id = Store.newId();
      final name = await Store.savePhoto(id, bytes);
      final first = text.trim().split(RegExp(r'\s+')).take(7).join(' ');
      await Store.put(SavedItem(id: id, kind: 'photo', title: first, lang: _lang, photo: name, parts: {'text': text, 'original': original}));
    } catch (_) {}
  }

  /// A short, plain reason for a failed online read.
  String _why(Object e) {
    final m = e.toString();
    if (m.contains('SocketException') || m.contains('Failed host lookup') || m.contains('ClientException')) return 'no internet';
    if (m.contains('Timeout')) return 'the server was too slow';
    if (m.contains('key not set')) return 'the reader is not switched on';
    return 'the online reader is busy';
  }

  Future<void> _readOffline(String path, Uint8List bytes, {String why = 'no internet'}) async {
    final rec = TextRecognizer(script: TextRecognitionScript.devanagiri);
    try {
      final r = await rec.processImage(InputImage.fromFilePath(path));
      final t = r.text.trim();
      final deva = RegExp(r'[ऀ-ॿ]').hasMatch(t);
      _set(() {
        _text = t;
        _original = '';
        _error = t.isEmpty
            ? 'The online reader did not answer ($why), and I could not read any words on the phone. Move the phone closer, hold it steady, and use more light.'
            : 'The online reader did not answer ($why). Reading the words as written, without translation.';
        _orb = t.isEmpty ? OrbState.idle : OrbState.speaking;
      });
      if (t.isNotEmpty) {
        await _keep(bytes, t, '');
        await _tts.setLanguage(deva ? 'hi-IN' : 'en-IN');
        await _tts.speak(t.length > 700 ? t.substring(0, 700) : t);
      }
    } finally {
      await rec.close();
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

  void _again() {
    _player.stop();
    _tts.stop();
    _set(() {
      _photo = null;
      _text = _original = _error = '';
      _orb = OrbState.idle;
    });
    if (_cam == null) _openCamera();
  }

  Widget _langRow() => SizedBox(
        height: 44,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final e in kLangs.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(e.value, style: TextStyle(fontSize: 16, color: _lang == e.key ? Colors.black : Colors.white)),
                selected: _lang == e.key,
                selectedColor: kTeal,
                backgroundColor: Colors.black54,
                side: BorderSide.none,
                showCheckmark: false,
                onSelected: (_) => _set(() => _lang = e.key),
              ),
            ),
        ]),
      );

  Widget _live() {
    final c = _cam;
    if (_camError.isNotEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_camError, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 20, height: 1.4))));
    }
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator());
    return Center(child: CameraPreview(c));
  }

  Widget _result() => Column(children: [
        if (_photo != null)
          SizedBox(height: 150, width: double.infinity, child: Image.memory(_photo!, fit: BoxFit.cover)),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_orb == OrbState.reading) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
              if (_text.isNotEmpty) SelectableText(_text, style: const TextStyle(color: Colors.white, fontSize: 28, height: 1.35, fontWeight: FontWeight.w600)),
              if (_error.isNotEmpty) Text(_error, style: const TextStyle(color: Colors.white70, fontSize: 20, height: 1.35)),
              if (_original.isNotEmpty && _text.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(_original, style: const TextStyle(color: Colors.white38, fontSize: 15)),
              ],
            ]),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final showing = _photo != null;
    return Scaffold(
      backgroundColor: kNavy,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Capture', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (!showing && _cam != null) IconButton(icon: Icon(_flash ? Icons.flash_on : Icons.flash_off), onPressed: _toggleFlash),
          IconButton(icon: const Icon(Icons.folder_open), onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedScreen()))),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          const SizedBox(height: 4),
          _langRow(),
          const SizedBox(height: 6),
          Expanded(child: showing ? _result() : ClipRRect(borderRadius: BorderRadius.circular(20), child: _live())),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            child: showing
                ? Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _again,
                        icon: const Icon(Icons.photo_camera, size: 28),
                        label: const Text('New photo', style: TextStyle(fontSize: 20)),
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
                  ])
                : GestureDetector(
                    onTap: _shoot,
                    child: Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                      padding: const EdgeInsets.all(6),
                      child: const DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white)),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
