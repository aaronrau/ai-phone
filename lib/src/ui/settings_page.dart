import 'package:flutter/material.dart';

import '../config.dart';
import '../runtime.dart';

/// Edits the complete receptionist configuration: prompts, greetings, tools,
/// contacts, screening rules and audio routing.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _editor = TextEditingController(text: widget.runtime.config.encode());
  List<String> _problems = const [];
  String? _saved;

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problems = await widget.runtime.saveConfig(_editor.text);
    setState(() {
      _problems = problems;
      _saved = problems.isEmpty ? 'Saved.' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Configuration', style: text.titleMedium),
        Text(
          'Prompts ("workflows"), greetings, enabled tools, custom tools, contacts, blocked numbers, '
          'screening rules and call audio. Placeholders: {owner_name}, {assistant_name}, {caller_name}, '
          '{caller_first_name}, {caller_details}, {number}.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _editor,
          maxLines: null,
          minLines: 18,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        for (final problem in _problems)
          Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_saved != null) Text(_saved!),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(onPressed: _save, child: const Text('Save')),
            OutlinedButton(
              onPressed: () => setState(() {
                _editor.text = widget.runtime.config.encode();
                _problems = const [];
                _saved = null;
              }),
              child: const Text('Revert'),
            ),
            OutlinedButton(
              onPressed: () => setState(() {
                _editor.text = ReceptionistConfig.defaults().encode();
                _saved = 'Defaults loaded; save to apply.';
              }),
              child: const Text('Load defaults'),
            ),
          ],
        ),
      ],
    );
  }
}
