import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Word-by-word listening with the phone's own speech recogniser. Free, no server, no credits.
/// Words arrive as you say them. If nothing is said for a few seconds it stops by itself.
class LiveStt {
  final SpeechToText _stt = SpeechToText();
  bool _ready = false;
  bool active = false;
  bool _gotText = false;
  String _pending = '';
  void Function(String text)? _onPartial;
  void Function(String text)? _onPhrase;
  void Function(String why)? _onEnd;
  String _locale = 'hi_IN';

  /// [locale] like "hi-IN". onPartial: the words of the phrase so far. onPhrase: a finished phrase.
  /// onEnd: it stopped by itself ("quiet" when nobody spoke).
  Future<bool> start({
    required String locale,
    required void Function(String) onPartial,
    required void Function(String) onPhrase,
    required void Function(String) onEnd,
  }) async {
    if (!_ready) {
      _ready = await _stt.initialize(onError: _error, onStatus: _status);
    }
    if (!_ready) return false;
    _locale = locale.replaceAll('-', '_');
    _onPartial = onPartial;
    _onPhrase = onPhrase;
    _onEnd = onEnd;
    active = true;
    await _listen();
    return true;
  }

  Future<void> _listen() async {
    if (!active) return;
    _gotText = false;
    _pending = '';
    try {
      await _stt.listen(
        onResult: (r) {
          if (!active || r.recognizedWords.isEmpty) return;
          _gotText = true;
          if (r.finalResult) {
            _pending = '';
            _onPhrase?.call(r.recognizedWords);
          } else {
            _pending = r.recognizedWords;
            _onPartial?.call(r.recognizedWords);
          }
        },
        localeId: _locale,
        listenFor: const Duration(seconds: 90),
        pauseFor: const Duration(seconds: 4),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: false,
        ),
      );
    } catch (_) {
      active = false;
      _onEnd?.call('error');
    }
  }

  void _status(String s) {
    if (!active) return;
    if (s == 'done' || s == 'notListening') {
      if (_pending.isNotEmpty) {
        // the recogniser stopped before sending the final text: keep what it had
        final t = _pending;
        _pending = '';
        _gotText = true;
        _onPhrase?.call(t);
      }
      if (_gotText) {
        Future.delayed(const Duration(milliseconds: 120), _listen);
      } else {
        _quiet();
      }
    }
  }

  void _error(SpeechRecognitionError e) {
    if (!active) return;
    if (e.errorMsg == 'error_no_match' || e.errorMsg == 'error_speech_timeout') {
      _quiet();
    } else if (e.permanent) {
      active = false;
      _onEnd?.call(e.errorMsg);
    } else {
      // busy / client / network hiccup: the engine stopped but we did not, so try again shortly
      Future.delayed(const Duration(milliseconds: 900), () async {
        if (!active) return;
        if (!_stt.isListening) await _listen();
      });
    }
  }

  void _quiet() {
    if (!active) return;
    active = false;
    _onEnd?.call('quiet');
  }

  Future<void> stop() async {
    active = false;
    try {
      await _stt.stop();
    } catch (_) {}
  }
}
