import 'package:flutter/material.dart';

import '../runtime.dart';
import '../store.dart';
import 'calendar_page.dart';
import 'settings_page.dart';
import 'setup_page.dart';
import 'test_page.dart';
import 'topics_page.dart';

/// Every advanced control, one level below the simple main screens.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.runtime, this.embedded = false});
  final ReceptionistRuntime runtime;

  /// Shown as a main tab: no header of its own.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    Widget scaffold(String title, Widget body) =>
        Scaffold(appBar: AppBar(title: Text(title)), body: SafeArea(child: body));
    final list = ListenableBuilder(
          listenable: runtime,
          builder: (context, _) {
            final issues = setupIssues(runtime);
            return ListView(
              padding: const EdgeInsets.only(top: 8),
              children: [
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('Setup and permissions'),
                  trailing: issues.isEmpty ? null : Text('${issues.length} to finish'),
                  onTap: () => open(SetupPage(runtime: runtime)),
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: const Text('Calendar and availability'),
                  onTap: () => open(scaffold('Calendar and availability', CalendarPage(runtime: runtime))),
                ),
                ListTile(
                  leading: const Icon(Icons.topic_outlined),
                  title: const Text('Topics and intents'),
                  onTap: () => open(TopicsPage(runtime: runtime)),
                ),
                ListTile(
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: const Text('Test the assistant'),
                  onTap: () => open(scaffold('Test the assistant', TestPage(runtime: runtime))),
                ),
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: const Text('Assistant wording'),
                  onTap: () => open(WordingPage(runtime: runtime)),
                ),
                ListTile(
                  leading: const Icon(Icons.memory),
                  title: const Text('Models and diagnostics'),
                  onTap: () => open(ModelsPage(runtime: runtime)),
                ),
                ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: const Text('Activity log'),
                  onTap: () => open(ActivityLogPage(runtime: runtime)),
                ),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('Advanced configuration'),
                  onTap: () => open(scaffold('Advanced configuration', SettingsPage(runtime: runtime))),
                ),
              ],
            );
          },
        );
    if (embedded) return list;
    return Scaffold(appBar: AppBar(title: const Text('Settings')), body: SafeArea(child: list));
  }
}

/// The fixed lines the assistant speaks, with an option to restyle them.
class WordingPage extends StatefulWidget {
  const WordingPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<WordingPage> createState() => _WordingPageState();
}

class _WordingPageState extends State<WordingPage> {
  bool _busy = false;
  String? _result;

  Future<void> _rewrite() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result = await widget.runtime.authorPhrases();
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _result = 'Could not rewrite: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    final greetings = [runtime.config.known.greeting, runtime.config.screen.greeting];
    return Scaffold(
      appBar: AppBar(title: const Text('Assistant wording')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Assistant name: ${runtime.config.assistantName}', style: text.bodyMedium),
            const SizedBox(height: 12),
            Text('Greetings', style: text.titleSmall),
            for (final greeting in greetings) Text(greeting, style: text.bodySmall),
            const SizedBox(height: 12),
            Text('Replies during calls', style: text.titleSmall),
            for (final entry in runtime.phrases.values.entries)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.key.replaceAll('_', ' '), style: text.labelMedium),
                    Text(entry.value, style: text.bodyMedium),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text('Names and greetings are edited in Advanced configuration.', style: text.bodySmall),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: _busy ? null : _rewrite,
                child: Text(_busy ? 'Rewriting…' : 'Rewrite replies with Gemma'),
              ),
            ),
            if (_result != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_result!, style: text.bodySmall)),
          ],
        ),
      ),
    );
  }
}

/// The complete raw activity log, including transcripts.
class ActivityLogPage extends StatefulWidget {
  const ActivityLogPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<ActivityLogPage> createState() => _ActivityLogPageState();
}

class _ActivityLogPageState extends State<ActivityLogPage> {
  List<ActivityEntry> _activity = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final activity = await widget.runtime.store?.activity(limit: 200) ?? const <ActivityEntry>[];
    if (mounted) setState(() => _activity = activity);
  }

  String _time(DateTime t) =>
      '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity log')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [for (final entry in _activity) _ActivityTile(entry: entry, time: _time(entry.time))],
          ),
        ),
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.entry, required this.time});
  final ActivityEntry entry;
  final String time;

  @override
  Widget build(BuildContext context) {
    final data = entry.data;
    final lines = data['lines'] as List?;
    final summary = lines != null
        ? lines.map((l) => '${l['speaker']}: ${l['text']}').join('\n')
        : data.entries.where((e) => e.key != 'lines').map((e) => '${e.key}: ${e.value}').join(' · ');
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(entry.kind.replaceAll('_', ' ')),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText(summary)),
        ),
      ],
    );
  }
}
