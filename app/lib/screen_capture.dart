import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'api.dart';
import 'live_stt.dart';
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
  final _stt = LiveStt();
  bool _asking = false; // listening for a question about the product
  String _asked = ''; // the question being asked right now
  final List<List<String>> _qa = []; // every question and its answer, kept for this photo
  String? _keptId, _keptPhoto;
  CameraController? _cam;
  String _camError = '';
  OrbState _orb = OrbState.idle;
  String _lang = 'en-IN';
  String _text = '', _original = '', _error = '';
  Uint8List? _photo;
  bool _busy = false;
  List<String> _paras = []; // the text split into paragraphs, for choosing what to hear
  int _sel = -1;
  int _rg = 0; // bumped to stop a long read-out
  bool _flash = false;
  bool _paused = false; // the read-out is paused, not stopped
  bool _viaPlayer = false; // the current piece plays from the server voice (can pause), not the phone voice
  String _cur = '';

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
    _stt.stop();
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
        _paras = [];
        _sel = -1;
        _text = '';
        _original = '';
        _error = '';
        _asked = '';
        _qa.clear();
        _keptId = _keptPhoto = null;
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
        _paras = _split(t);
        _sel = -1;
        _error = t.isEmpty ? 'I could not find any words. Move the phone closer, hold it steady, and use more light.' : '';
        _orb = t.isEmpty ? OrbState.idle : OrbState.speaking;
      });
      if (t.isNotEmpty) await _keep(bytes, t, o);
      // a long page (a newspaper, a leaflet): do not read it all at once, let the person choose what to hear
      if (_paras.length < 3) await _say(t.isEmpty ? _error : t);
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
      _keptId = id;
      _keptPhoto = name;
      final ok = await Store.put(SavedItem(id: id, kind: 'photo', title: first, lang: _lang, photo: name, parts: {'text': text, 'original': original}));
      if (!ok) _set(() => _error = Store.lastError ?? 'Could not save this photo.');
    } catch (_) {}
  }

  /// Saves the photo again with what is on screen now: the words in the chosen language, and every question with its answer.
  Future<void> _resave() async {
    final id = _keptId;
    if (id == null || _text.isEmpty) return;
    try {
      final first = _text.trim().split(RegExp(r'\s+')).take(7).join(' ');
      final qa = _qa.map((e) => 'Q: ${e[0]}\n${e[1]}').join('\n\n');
      await Store.put(SavedItem(id: id, kind: 'photo', title: first, lang: _lang, photo: _keptPhoto,
          parts: {'text': _text, 'original': _original, if (qa.isNotEmpty) 'questions': qa}));
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
    _cur = spoken;
    if (_paused) _set(() => _paused = false);
    try {
      final b = await Api.speak(spoken, _lang);
      if (b != null) {
        _viaPlayer = true;
        final done = _player.onPlayerComplete.first;
        await _player.play(BytesSource(b));
        await done.timeout(const Duration(minutes: 5));
        return;
      }
      _viaPlayer = false;
      await _tts.setLanguage(_lang == 'od-IN' ? 'or-IN' : _lang);
      await _tts.speak(spoken);
    } catch (_) {}
  }

  /// Pause the read-out where it is, or carry on from there.
  Future<void> _togglePause() async {
    if (_paused) {
      _set(() => _paused = false);
      if (_viaPlayer) {
        await _player.resume();
      } else {
        await _tts.speak(_cur);
      }
    } else {
      _set(() => _paused = true);
      if (_viaPlayer) {
        await _player.pause();
      } else {
        await _tts.stop();
      }
    }
  }

  /// A new language was picked after the photo: translate the words, show them, and read them out.
  Future<void> _retranslate() async {
    final src = _original.isNotEmpty ? _original : _text;
    if (src.trim().isEmpty || _busy) return;
    final my = ++_rg;
    await _player.stop();
    await _tts.stop();
    final lang = _lang;
    _set(() {
      _orb = OrbState.reading;
      _error = '';
    });
    try {
      final t = (await Api.relabel(src, lang)).trim();
      if (t.isEmpty) throw Exception('empty');
      if (my != _rg || !mounted) return;
      _set(() {
        _text = t;
        _paras = _split(t);
        _sel = -1;
        _orb = OrbState.idle;
      });
      unawaited(_resave());
      if (_paras.length < 3) await _say(t);
    } catch (_) {
      if (my != _rg || !mounted) return;
      _set(() {
        _orb = OrbState.idle;
        _error = 'I could not translate it into ${kLangs[lang] ?? lang} just now. Please check the internet and tap the language again.';
      });
    }
  }

  /// Tap the mic, say a question about the product, and hear a short answer from the web.
  Future<void> _ask() async {
    if (_asking) {
      await _stt.stop();
      _set(() => _asking = false);
      return;
    }
    await _player.stop();
    await _tts.stop();
    _rg++;
    _set(() {
      _asking = true;
      _asked = '';
      _error = '';
    });
    final ok = await _stt.start(
      locale: _lang == 'od-IN' ? 'or-IN' : _lang,
      onPartial: (t) => _set(() => _asked = t),
      onPhrase: (t) async {
        await _stt.stop();
        if (!mounted) return;
        _set(() {
          _asking = false;
          _asked = t;
          _orb = OrbState.reading;
        });
        try {
          final a = (await Api.ask(t, _original.isNotEmpty ? _original : _text, _lang)).trim();
          if (!mounted) return;
          _set(() {
            if (a.isNotEmpty) _qa.add([t, a]);
            _asked = '';
            _orb = OrbState.speaking;
          });
          unawaited(_resave());
          await _say(a);
        } catch (_) {
          if (mounted) _set(() => _error = 'I could not find that just now. Please check the internet and ask again.');
        }
        if (mounted) _set(() => _orb = OrbState.idle);
      },
      onEnd: (why) {
        if (!mounted) return;
        _set(() {
          _asking = false;
          if (_asked.isEmpty) _error = 'I did not hear a question. Tap the mic and try again.';
        });
      },
    );
    if (!ok && mounted) _set(() {
      _asking = false;
      _error = 'Speech is not ready on this phone.';
    });
  }

  List<String> _split(String t) => t.split(RegExp(r'\n\s*\n')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// Reads the chosen pieces one after another, and stops if the person chooses something else.
  Future<void> _sayParts(List<String> parts, {int? mark}) async {
    final my = ++_rg;
    await _player.stop();
    await _tts.stop();
    for (var i = 0; i < parts.length; i++) {
      if (my != _rg || !mounted) return;
      _set(() {
        _orb = OrbState.speaking;
        if (mark != null) _sel = mark + i;
      });
      await _say(parts[i]);
    }
    if (my == _rg) _set(() => _orb = OrbState.idle);
  }

  Future<void> _summarise() async {
    final my = ++_rg;
    await _player.stop();
    await _tts.stop();
    _set(() {
      _orb = OrbState.reading;
      _sel = -1;
    });
    String s = '';
    try {
      s = await Api.summary(_text, _lang);
    } catch (_) {}
    if (my != _rg || !mounted) return;
    if (s.trim().isEmpty) {
      _set(() {
        _orb = OrbState.idle;
        _error = 'I could not make a short version just now. Please try again.';
      });
      return;
    }
    _set(() => _error = '');
    await _sayParts([s.trim()]);
  }

  Future<void> _listenAgain() async {
    if (_text.isEmpty) return;
    if (_paras.length >= 3) {
      await _sayParts(_paras, mark: 0);
      return;
    }
    _set(() => _orb = OrbState.speaking);
    await _say(_text);
    _set(() => _orb = OrbState.idle);
  }

  void _again() {
    _rg++;
    _paused = false;
    _player.stop();
    _tts.stop();
    _set(() {
      _paras = [];
      _sel = -1;
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
                label: Text(e.value, style: TextStyle(fontSize: 16, color: _lang == e.key ? Colors.white : kInk)),
                selected: _lang == e.key,
                selectedColor: kPrimary,
                backgroundColor: kMint,
                side: BorderSide.none,
                showCheckmark: false,
                onSelected: (_) {
                _set(() => _lang = e.key);
                _retranslate();
              },
              ),
            ),
        ]),
      );

  Widget _live() {
    final c = _cam;
    if (_camError.isNotEmpty) {
      return Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_camError, textAlign: TextAlign.center, style: const TextStyle(color: kSub, fontSize: 20, height: 1.4))));
    }
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator());
    return Stack(alignment: Alignment.topCenter, children: [
      Center(child: CameraPreview(c)),
      Positioned(
        top: 10,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
          child: const Text('Hold steady, fill the screen with the words', style: TextStyle(color: Colors.white, fontSize: 15)),
        ),
      ),
    ]);
  }

  Widget _result() => Column(children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_photo != null)
                ClipRRect(borderRadius: BorderRadius.circular(16), child: SizedBox(height: 150, width: double.infinity, child: Image.memory(_photo!, fit: BoxFit.cover))),
              const SizedBox(height: 14),
              for (final qa in _qa)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: kMint, borderRadius: BorderRadius.circular(14), border: Border.all(color: kPrimary)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(qa[0], style: const TextStyle(color: kSub, fontSize: 16)),
                    const SizedBox(height: 8),
                    SelectableText(qa[1], style: const TextStyle(color: kInk, fontSize: 21, height: 1.35, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    const Text('From the web. Prices and details can change.', style: TextStyle(color: kSub, fontSize: 14)),
                  ]),
                ),
              if (_asking || _asked.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: kMint, borderRadius: BorderRadius.circular(14), border: Border.all(color: kPrimary)),
                  child: Text(_asking && _asked.isEmpty ? 'Listening… ask about this product' : _asked, style: const TextStyle(color: kSub, fontSize: 16)),
                ),
              if (_orb == OrbState.reading) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
              if (_text.isNotEmpty && _paras.length < 3) SelectableText(_text, style: const TextStyle(color: kInk, fontSize: 28, height: 1.35, fontWeight: FontWeight.w700)),
              if (_paras.length >= 3) ...[
                const Text('This is a long page. What do you want to hear?', style: TextStyle(color: kInk, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25)),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  ActionChip(label: const Text('Read it all', style: TextStyle(fontSize: 17)), onPressed: () => _sayParts(_paras, mark: 0)),
                  ActionChip(label: const Text('Headline', style: TextStyle(fontSize: 17)), onPressed: () => _sayParts([_paras.first], mark: 0)),
                  ActionChip(label: const Text('Short summary', style: TextStyle(fontSize: 17)), onPressed: _summarise),
                  ActionChip(avatar: const Icon(Icons.stop, size: 18), label: const Text('Stop', style: TextStyle(fontSize: 17)), onPressed: () {
                    _rg++;
                    _player.stop();
                    _tts.stop();
                    _set(() => _orb = OrbState.idle);
                  }),
                ]),
                const SizedBox(height: 12),
                const Text('Or tap a paragraph:', style: TextStyle(color: kSub, fontSize: 15)),
                const SizedBox(height: 6),
                for (var i = 0; i < _paras.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Semantics(
                      button: true,
                      label: 'Read paragraph ${i + 1}',
                      child: Material(
                        color: i == _sel ? kMint : Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: i == _sel ? kPrimary : kLine)),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => _sayParts([_paras[i]], mark: i),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${i + 1}', style: const TextStyle(color: kPrimary, fontSize: 20, fontWeight: FontWeight.w800)),
                              const SizedBox(width: 12),
                              Expanded(child: Text(_paras[i], style: const TextStyle(color: kInk, fontSize: 19, height: 1.35))),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
              if (_error.isNotEmpty) Text(_error, style: const TextStyle(color: kSub, fontSize: 19, height: 1.35)),
              if (_original.isNotEmpty && _text.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(_original, style: const TextStyle(color: kSub, fontSize: 15)),
              ],
              if (_text.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: kMint, borderRadius: BorderRadius.circular(14)),
                  child: const Text('Small print can be misread. Check important names and numbers against the original.', style: TextStyle(color: kInk, fontSize: 15, height: 1.35)),
                ),
              ],
            ]),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final showing = _photo != null;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('Capture'),
        actions: [
          if (!showing && _cam != null) IconButton(icon: Icon(_flash ? Icons.flash_on : Icons.flash_off), tooltip: 'Light', onPressed: _toggleFlash),
          IconButton(icon: const Icon(Icons.bookmark_border), tooltip: 'Saved', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedScreen()))),
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
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64)),
                      ),
                    ),
                    if (_text.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      IconButton.filled(
                        onPressed: _busy ? null : _ask,
                        icon: Icon(_asking ? Icons.graphic_eq : Icons.mic, size: 30),
                        tooltip: 'Ask about this',
                        style: IconButton.styleFrom(minimumSize: const Size(64, 64), backgroundColor: _asking ? const Color(0xFFB3261E) : kPrimary, foregroundColor: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        onPressed: (_orb == OrbState.speaking || _paused) ? _togglePause : _listenAgain,
                        icon: Icon(_paused ? Icons.play_arrow : (_orb == OrbState.speaking ? Icons.pause : Icons.volume_up), size: 30),
                        tooltip: _paused ? 'Play' : (_orb == OrbState.speaking ? 'Pause' : 'Listen again'),
                        style: IconButton.styleFrom(minimumSize: const Size(64, 64), backgroundColor: kMint, foregroundColor: kPrimary),
                      ),
                    ],
                  ])
                : Semantics(
                    button: true,
                    label: 'Take a photo',
                    child: GestureDetector(
                      onTap: _shoot,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kPrimary, width: 4)),
                        padding: const EdgeInsets.all(6),
                        child: const DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: kPrimary)),
                      ),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}
