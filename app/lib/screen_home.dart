import 'package:flutter/material.dart';

import 'api.dart';
import 'personal_style.dart';
import 'screen_saved.dart';
import 'widgets.dart';

/// First run: which languages do you speak? Nothing is ticked for you.
class SetupScreen extends StatefulWidget {
  final PersonalStyle style;
  final VoidCallback onDone;
  const SetupScreen({super.key, required this.style, required this.onDone});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _picked = <String>{};
  String _notes = 'hi-IN';

  @override
  void initState() {
    super.initState();
    _notes = widget.style.notesLang;
  }

  Future<void> _go() async {
    final s = widget.style;
    s.myLangs
      ..clear()
      ..addAll(_picked);
    s.notesLang = _notes;
    s.setupDone = true;
    await s.save();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kNavy,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Center(child: TildaOrb(state: OrbState.idle, size: 120)),
              const SizedBox(height: 8),
              const Text('Which languages can you speak?', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text('Pick all that you speak. You can change this later.', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final e in kLangs.entries)
                      FilterChip(
                        label: Text(e.value),
                        selected: _picked.contains(e.key),
                        showCheckmark: true,
                        onSelected: (v) => setState(() => v ? _picked.add(e.key) : _picked.remove(e.key)),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Write my notes in', style: TextStyle(color: Colors.white70)),
              DropdownButton<String>(
                isExpanded: true,
                dropdownColor: kCard,
                value: _notes,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                items: [for (final e in kLangs.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => setState(() => _notes = v ?? _notes),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  onPressed: _picked.isEmpty ? null : _go,
                  child: Text(_picked.isEmpty ? 'Pick at least one language' : 'Continue', style: const TextStyle(fontSize: 18)),
                ),
              ),
            ]),
          ),
        ),
      );
}

/// Three big buttons. That is the whole app.
class HomeScreen extends StatelessWidget {
  final VoidCallback onTalk, onCapture, onNotes, onTranslate, onSettings;
  const HomeScreen({super.key, required this.onTalk, required this.onCapture, required this.onNotes, required this.onTranslate, required this.onSettings});

  Widget _big(IconData icon, String title, String sub, Color c, VoidCallback f) => Expanded(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Material(
            color: kCard,
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: f,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(color: c.withOpacity(0.18), shape: BoxShape.circle),
                    child: Icon(icon, color: c, size: 34),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(sub, style: const TextStyle(color: Colors.white60, fontSize: 14)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white38),
                ]),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kNavy,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Column(children: [
              Row(children: [
                const SizedBox(width: 8),
                const Text('Tilda', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                const Spacer(),
                IconButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedScreen())), icon: const Icon(Icons.folder_open, color: Colors.white70), tooltip: 'Saved'),
                IconButton(onPressed: onSettings, icon: const Icon(Icons.settings, color: Colors.white70)),
              ]),
              const SizedBox(height: 4),
              const TildaOrb(state: OrbState.idle, size: 110),
              const SizedBox(height: 8),
              _big(Icons.graphic_eq, 'Talk to Tilda', 'Ask anything, out loud', kBlue, onTalk),
              _big(Icons.photo_camera, 'Capture', 'Read a sign, bill or medicine', kPink, onCapture),
              _big(Icons.edit_note, 'Take notes', 'Listens to a class or video', kTeal, onNotes),
              _big(Icons.translate, 'Translate', 'Two people, two languages', kOrange, onTranslate),
            ]),
          ),
        ),
      );
}
