import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

void main() => runApp(const TildaApp());

class TildaApp extends StatelessWidget {
  const TildaApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tilda',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.teal,
            brightness: Brightness.dark,
            useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _recorder = AudioRecorder();
  final _url = TextEditingController(text: 'http://10.0.2.2:8000');
  bool _recording = false;
  bool _busy = false;
  String _text = '';
  String _info = 'Say a greeting and the name first, e.g. "Namaskaram Tilda".';

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _info = 'Microphone permission is needed.');
      return;
    }
    final dir = await getTemporaryDirectory();
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
      path: '${dir.path}/clip.wav',
    );
    setState(() => _recording = true);
  }

  Future<void> _stop() async {
    final path = await _recorder.stop();
    setState(() {
      _recording = false;
      _busy = true;
      _info = 'Working...';
      _text = '';
    });
    if (path == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final req = http.MultipartRequest('POST', Uri.parse('${_url.text.trim()}/transcribe'))
        ..fields['lang'] = 'auto'
        ..files.add(await http.MultipartFile.fromPath('audio', path));
      final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 40)));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final log = (j['log'] as List? ?? []).map((e) => '${e[0]}: ${e[1]}').join('\n');
      setState(() {
        _text = (j['text'] ?? '') as String;
        _info = j['error'] != null
            ? 'FAILED: ${j['error']}\n\nTried:\n$log'
            : 'Engine: ${j['engine']}\nLanguage: ${j['language']}\nGreeting found: ${j['greeting_found']}\n\nTried:\n$log';
      });
    } catch (e) {
      setState(() => _info = 'Error: $e');
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
      setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _recorder.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Tilda')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(labelText: 'Server address'),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTapDown: _busy ? null : (_) => _start(),
              onTapUp: (_) => _recording ? _stop() : null,
              onTapCancel: () => _recording ? _stop() : null,
              child: Container(
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _recording ? Colors.red : Colors.teal,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _recording ? 'Recording... release to send' : 'Hold to record',
                  style: const TextStyle(color: Colors.white, fontSize: 20),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(_text, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(_info),
          ]),
        ),
      );
}
