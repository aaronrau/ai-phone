import 'package:flutter/material.dart';

import '../contacts.dart';
import '../intents.dart';
import '../runtime.dart';
import '../store.dart';
import '../tasks.dart';
import 'callout_page.dart';
import 'common.dart';
import 'contact_picker.dart';
import 'home_page.dart' show shortTime;

/// Tasks for the assistant: what to do when specific people call, and calls
/// to make for the owner.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  List<ActivityEntry> _callOuts = [];

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final activity = await widget.runtime.store?.activity(limit: 300) ?? const <ActivityEntry>[];
    if (mounted) setState(() => _callOuts = activity.where((e) => e.kind == 'callout').toList());
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    final inbound = [...runtime.tasks.inbound]..sort((a, b) {
        if (a.done != b.done) return a.done ? 1 : -1;
        return b.created.compareTo(a.created);
      });
    final active = runtime.callOuts.where((t) => t.status != 'done').toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
      children: [
        Text('When they call', style: text.titleMedium),
        const Muted('The assistant gives your message, asks your question, or puts them through to you.'),
        if (inbound.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('No tasks.', style: text.bodyMedium)),
        for (final task in inbound)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(_icon(task.action), size: 20),
            title: Text(task.topic.isNotEmpty
                    ? 'Anyone about ${task.topic}'
                    : displayName(task.name.isEmpty ? task.number : task.name),
                style: task.done ? text.titleSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant) : text.titleSmall),
            subtitle: Muted(
              [
                task.action == InboundAction.transfer ? 'Transfer to me' : '${task.action.label}: ${task.text}',
                task.done
                    ? 'Done · ${task.result}'
                    : (task.topic.isNotEmpty ? 'Every call about this topic' : 'Waiting for their call'),
              ].join('\n'),
              maxLines: 3,
            ),
            trailing: IconButton(
              tooltip: 'Delete task',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => runtime.deleteTask(task),
            ),
          ),
        const SizedBox(height: 16),
        Text('Calls to make', style: text.titleMedium),
        if (active.isEmpty && _callOuts.isEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('No calls yet.', style: text.bodyMedium)),
        for (final task in active)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.support_agent, size: 20),
            title: Text(displayName(task.contactName.isEmpty ? task.number : task.contactName), style: text.titleSmall),
            subtitle: Muted('${task.objective}\nNow: ${task.status}', maxLines: 2),
          ),
        for (final entry in _callOuts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.support_agent, size: 20),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                      displayName((entry.data['contact'] ?? '').toString().isEmpty
                          ? (entry.data['number'] ?? '').toString()
                          : entry.data['contact'].toString()),
                      style: text.titleSmall),
                ),
                Muted(shortTime(entry.time)),
              ],
            ),
            subtitle: Muted('${entry.data['objective'] ?? ''}\n${entry.data['outcome'] ?? ''}', maxLines: 2),
          ),
      ],
    );
  }

  static IconData _icon(InboundAction action) => switch (action) {
        InboundAction.tell => Icons.campaign_outlined,
        InboundAction.ask => Icons.help_outline,
        InboundAction.transfer => Icons.phone_forwarded_outlined,
      };
}

/// Choose what kind of task to create.
void showNewTaskSheet(BuildContext context, ReceptionistRuntime runtime) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.call_received),
            title: const Text('When someone calls'),
            subtitle: const Text('Give them a message, ask them something, or transfer them to you'),
            onTap: () {
              Navigator.of(sheet).pop();
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => InboundTaskPage(runtime: runtime)));
            },
          ),
          ListTile(
            leading: const Icon(Icons.support_agent),
            title: const Text('Call someone for me'),
            subtitle: const Text('The assistant calls and handles it'),
            onTap: () {
              Navigator.of(sheet).pop();
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CallOutPage(runtime: runtime)));
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// A task for the next call from a person or number.
class InboundTaskPage extends StatefulWidget {
  const InboundTaskPage({super.key, required this.runtime, this.number = '', this.name = ''});
  final ReceptionistRuntime runtime;
  final String number;
  final String name;

  @override
  State<InboundTaskPage> createState() => _InboundTaskPageState();
}

class _InboundTaskPageState extends State<InboundTaskPage> {
  late final _number = TextEditingController(text: widget.number);
  final _text = TextEditingController();
  late String _name = widget.name;
  InboundAction _action = InboundAction.tell;

  /// Who the task is for: one person (number) or anyone calling about a topic.
  bool _byTopic = false;
  String? _topic;
  String? _error;

  @override
  void dispose() {
    _number.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final number = _byTopic ? '' : _number.text.trim();
    final text = _text.text.trim();
    if (_byTopic && _topic == null) return setState(() => _error = 'Pick a topic.');
    if (!_byTopic && number.isEmpty) return setState(() => _error = 'Pick a contact or enter a number.');
    if (_action != InboundAction.transfer && text.isEmpty) {
      return setState(() => _error = _action == InboundAction.tell ? 'Write the message.' : 'Write the question.');
    }
    await widget.runtime.addTask(InboundTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      number: number,
      name: _byTopic ? '' : (_name.isNotEmpty ? _name : (widget.runtime.contacts.find(number)?.label ?? '')),
      topic: _byTopic ? _topic! : '',
      action: _action,
      text: _action == InboundAction.transfer ? '' : text,
    ));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    final people = [
      ...runtime.contacts.byStatus(ContactStatus.known),
      ...runtime.contacts.byStatus(ContactStatus.screened),
    ].where((c) => c.numbers.isNotEmpty).take(12).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('When they call')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('A person')),
                ButtonSegment(value: true, label: Text('A topic')),
              ],
              selected: {_byTopic},
              onSelectionChanged: (s) => setState(() => _byTopic = s.first),
            ),
            const SizedBox(height: 12),
            if (_byTopic)
              DropdownButtonFormField<String>(
                initialValue: _topic,
                decoration: const InputDecoration(labelText: 'Anyone calling about', border: OutlineInputBorder()),
                items: [
                  for (final i in runtime.config.intents.where((i) => i.kind == IntentKind.reason))
                    DropdownMenuItem(value: i.name, child: Text(i.name)),
                ],
                onChanged: (v) => setState(() => _topic = v),
              )
            else
            TextField(
              controller: _number,
              // Start typing right away; from a contact the number is already set.
              autofocus: widget.number.isEmpty,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Phone number',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Choose contact',
                  icon: const Icon(Icons.person_search_outlined),
                  onPressed: () async {
                    final picked = await pickContact(context, runtime, title: 'Who is this task for?');
                    if (picked != null) {
                      setState(() {
                        _number.text = picked.number;
                        _name = picked.name;
                      });
                    }
                  },
                ),
              ),
              onChanged: (_) => _name = '',
            ),
            if (!_byTopic && people.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in people)
                    ChoiceChip(
                      label: Text(c.label),
                      selected: _name == c.label,
                      onSelected: (_) => setState(() {
                        _number.text = c.numbers.first;
                        _name = c.label;
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text('The assistant should', style: text.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<InboundAction>(
              segments: [
                for (final a in InboundAction.values) ButtonSegment(value: a, label: Text(a.label)),
              ],
              selected: {_action},
              onSelectionChanged: (s) => setState(() => _action = s.first),
            ),
            const SizedBox(height: 12),
            if (_action != InboundAction.transfer)
              TextField(
                controller: _text,
                autofocus: widget.number.isNotEmpty,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: _action == InboundAction.tell ? 'Message for them' : 'Question to ask',
                  hintText: _action == InboundAction.tell ? 'Dinner moved to 7 PM' : 'Which day works for the delivery?',
                  border: const OutlineInputBorder(),
                ),
              )
            else
              const Muted('When they call, the assistant asks them to hold and lets you pick up.'),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Save task')),
          ],
        ),
      ),
    );
  }
}
