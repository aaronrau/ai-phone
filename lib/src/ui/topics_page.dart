import 'dart:convert';

import 'package:flutter/material.dart';

import '../intents.dart';
import '../runtime.dart';
import 'common.dart';

/// Topics and intents the assistant recognises in what callers say, matched
/// on the phone with a small sentence-embedding model.
class TopicsPage extends StatefulWidget {
  const TopicsPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends State<TopicsPage> {
  final _sample = TextEditingController();
  List<IntentMatch> _ranked = [];
  bool _checking = false;
  late double _threshold = widget.runtime.config.intentThreshold;

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  Future<void> _save(List<IntentDef> intents, {double? threshold}) async {
    final json = (jsonDecode(widget.runtime.config.encode()) as Map).cast<String, dynamic>()
      ..['intents'] = [for (final i in intents) i.toJson()]
      ..['intent_threshold'] = threshold ?? widget.runtime.config.intentThreshold;
    await widget.runtime.saveConfig(const JsonEncoder.withIndent('  ').convert(json));
    if (mounted) setState(() => _ranked = []);
  }

  Future<void> _check() async {
    final detector = widget.runtime.intentDetector;
    if (detector == null || _sample.text.trim().isEmpty) return;
    setState(() => _checking = true);
    try {
      final ranked = await detector.rank(_sample.text);
      if (mounted) setState(() => _ranked = ranked.take(3).toList());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _edit(IntentDef? existing) async {
    final intents = [...widget.runtime.config.intents];
    final edited = await showDialog<IntentDef>(
      context: context,
      builder: (_) => _TopicDialog(existing: existing),
    );
    if (edited == null) return;
    final index = existing == null ? -1 : intents.indexOf(existing);
    if (index >= 0) {
      intents[index] = edited;
    } else {
      intents.add(edited);
    }
    await _save(intents);
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Topics and intents')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Add topic'),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: runtime,
          builder: (context, _) {
            final intents = runtime.config.intents;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
              children: [
                Muted('Detection on this phone: ${runtime.intentStatus}'),
                const Muted('A valid reason lets a caller through to a warm transfer; vague answers make the '
                    'assistant keep asking; tasks can target any topic.'),
                const SizedBox(height: 12),
                Text('Match threshold ${_threshold.toStringAsFixed(2)}', style: text.titleSmall),
                Slider(
                  value: _threshold,
                  min: 0.5,
                  max: 0.95,
                  divisions: 45,
                  onChanged: (v) => setState(() => _threshold = v),
                  onChangeEnd: (v) => _save(runtime.config.intents, threshold: v),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _sample,
                        decoration: const InputDecoration(
                            labelText: 'Try a sentence', hintText: 'Is he free for dinner tonight?',
                            border: OutlineInputBorder()),
                        onSubmitted: (_) => _check(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: runtime.intentDetector == null || _checking ? null : _check,
                      child: const Text('Check'),
                    ),
                  ],
                ),
                for (final m in _ranked)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${m.intent.name} · ${m.intent.kind.label} · ${m.score.toStringAsFixed(2)}'
                      '${m.score >= _threshold ? '' : ' (below threshold)'}',
                      style: text.bodyMedium,
                    ),
                  ),
                for (final kind in IntentKind.values) ...[
                  const SizedBox(height: 16),
                  Text(kind.label, style: text.titleMedium),
                  for (final intent in intents.where((i) => i.kind == kind))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(intent.name, style: text.titleSmall),
                      subtitle: Muted(intent.examples.join(' · '), maxLines: 2),
                      onTap: () => _edit(intent),
                      trailing: IconButton(
                        tooltip: 'Delete topic',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => _save([...intents]..remove(intent)),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TopicDialog extends StatefulWidget {
  const _TopicDialog({this.existing});
  final IntentDef? existing;

  @override
  State<_TopicDialog> createState() => _TopicDialogState();
}

class _TopicDialogState extends State<_TopicDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _examples = TextEditingController(text: widget.existing?.examples.join('\n') ?? '');
  late IntentKind _kind = widget.existing?.kind ?? IntentKind.reason;

  @override
  void dispose() {
    _name.dispose();
    _examples.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New topic' : 'Edit topic'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<IntentKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Kind'),
              items: [for (final k in IntentKind.values) DropdownMenuItem(value: k, child: Text(k.label))],
              onChanged: (k) => setState(() => _kind = k ?? _kind),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _examples,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(labelText: 'Example phrases (one per line)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final examples = _examples.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            if (_name.text.trim().isEmpty || examples.isEmpty) return;
            Navigator.pop(context, IntentDef(name: _name.text.trim(), kind: _kind, examples: examples));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
