import 'package:flutter/material.dart';

import 'api.dart';
import 'personal_style.dart';
import 'screen_saved.dart';
import 'widgets.dart';

/// First run: which languages do you speak? Nothing is ticked for you.
class SetupScreen extends StatefulWidget {
  final PersonalStyle style;
  final VoidCallback onDone;
  final VoidCallback? onBack; // null on the very first run: there is nothing to go back to
  const SetupScreen({super.key, required this.style, required this.onDone, this.onBack});

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
    _picked.addAll(widget.style.myLangs);
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
              if (widget.onBack != null)
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back, color: kInk, size: 28),
                  tooltip: 'Back',
                  padding: EdgeInsets.zero,
                  alignment: Alignment.centerLeft,
                )
              else
                const SizedBox(height: 4),
              const Text('Speak your language', style: TextStyle(color: kInk, fontSize: 28, fontWeight: FontWeight.w800, height: 1.15)),
              const SizedBox(height: 4),
              const Text('Choose all that you use. You can change this later.', style: TextStyle(color: kSub, fontSize: 16)),
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
              const Text('Write my notes in', style: TextStyle(color: kInk, fontSize: 17, fontWeight: FontWeight.w700)),
              DropdownButton<String>(
                isExpanded: true,
                dropdownColor: Colors.white,
                value: _notes,
                style: const TextStyle(color: kInk, fontSize: 17),
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

/// Home: one clear way to start talking, then the other things Tilda does.
class HomeScreen extends StatelessWidget {
  final VoidCallback onTalk, onCapture, onNotes, onTranslate, onSettings;
  const HomeScreen({super.key, required this.onTalk, required this.onCapture, required this.onNotes, required this.onTranslate, required this.onSettings});

  Widget _row(IconData icon, String title, String sub, VoidCallback f) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          button: true,
          label: '$title. $sub',
          child: Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: kLine)),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: f,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [
                  Icon(icon, color: kInk, size: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, style: const TextStyle(color: kInk, fontSize: 18, fontWeight: FontWeight.w700)),
                        Text(sub, style: const TextStyle(color: kSub, fontSize: 14)),
                      ]),
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: kSub),
                ]),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('Tilda', style: TextStyle(color: kInk, fontSize: 30, fontWeight: FontWeight.w800)),
                const Spacer(),
                IconButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedScreen())),
                    icon: const Icon(Icons.bookmark_border, color: kInk, size: 28),
                    tooltip: 'Saved'),
                IconButton(onPressed: onSettings, icon: const Icon(Icons.settings_outlined, color: kInk, size: 28), tooltip: 'Settings'),
              ]),
              const SizedBox(height: 4),
              const Text('What can I help with?', style: TextStyle(color: kInk, fontSize: 26, fontWeight: FontWeight.w800, height: 1.15)),
              const SizedBox(height: 12),
              TildaCard(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                child: Column(children: [
                  const TildaOrb(state: OrbState.idle, size: 96),
                  const SizedBox(height: 8),
                  const Text('Talk to Tilda', style: TextStyle(color: kInk, fontSize: 22, fontWeight: FontWeight.w800)),
                  const Text('Ask a question. Say it naturally.', style: TextStyle(color: kSub, fontSize: 15)),
                  const SizedBox(height: 10),
                  Semantics(
                    button: true,
                    label: 'Start talking to Tilda',
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(onPressed: onTalk, icon: const Icon(Icons.mic, size: 26), label: const Text('Start talking')),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              const Text('Explore', style: TextStyle(color: kInk, fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              _row(Icons.photo_camera_outlined, 'Capture', 'Read text from a photo', onCapture),
              _row(Icons.notes, 'Take notes', 'Turn speech into notes', onNotes),
              _row(Icons.translate, 'Translate', 'Two people, two languages', onTranslate),
            ],
          ),
          ),
        ),
      );
}
