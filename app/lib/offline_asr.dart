import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Rough on-device transcription (Whisper base, int8) used only while the network is down.
/// When the network returns, the server's better engines replace this text.
class OfflineAsr {
  static const _repo = 'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/main';
  static const _files = ['base-encoder.int8.onnx', 'base-decoder.int8.onnx', 'base-tokens.txt'];

  Directory? _dir;
  bool ready = false;

  Future<Directory> _modelDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    return _dir = await Directory('${base.path}/whisper-base').create(recursive: true);
  }

  Future<void> check() async {
    final d = await _modelDir();
    ready = _files.every((f) => File('${d.path}/$f').existsSync());
  }

  /// Downloads the model once (about 150 MB). onProgress gets 0..1.
  Future<void> download(void Function(double) onProgress) async {
    final d = await _modelDir();
    final client = http.Client();
    try {
      for (var i = 0; i < _files.length; i++) {
        final target = File('${d.path}/${_files[i]}');
        if (target.existsSync()) continue;
        final res = await client.send(http.Request('GET', Uri.parse('$_repo/${_files[i]}')));
        if (res.statusCode != 200) throw Exception('download failed (${res.statusCode})');
        final total = res.contentLength ?? 0;
        var got = 0;
        final tmp = File('${target.path}.part');
        final sink = tmp.openWrite();
        await for (final chunk in res.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress((i + got / total) / _files.length);
        }
        await sink.close();
        await tmp.rename(target.path);
      }
    } finally {
      client.close();
    }
    await check();
  }

  /// Rough text for one saved 16 kHz mono WAV piece. [lang] is a 2-letter code like "hi", or "" to auto-detect.
  Future<String> transcribe(String wavPath, String lang) async {
    final d = await _modelDir();
    final dir = d.path;
    return Isolate.run(() {
      sherpa.initBindings();
      final bytes = File(wavPath).readAsBytesSync();
      final pcm = bytes.buffer.asInt16List(bytes.offsetInBytes + 44, (bytes.length - 44) ~/ 2);
      final samples = Float32List(pcm.length);
      for (var i = 0; i < pcm.length; i++) {
        samples[i] = pcm[i] / 32768.0;
      }
      final recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: '$dir/base-encoder.int8.onnx',
            decoder: '$dir/base-decoder.int8.onnx',
            language: lang,
            task: 'transcribe',
          ),
          tokens: '$dir/base-tokens.txt',
          modelType: 'whisper',
          numThreads: 2,
        ),
      ));
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      stream.free();
      recognizer.free();
      return text;
    });
  }
}
