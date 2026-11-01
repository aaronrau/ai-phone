import 'package:flutter/material.dart';

import '../contacts.dart';
import '../outbound.dart';
import '../runtime.dart';
import 'contact_picker.dart';
import 'test_page.dart';

/// Tell the assistant to call someone and pursue an objective, e.g. booking an
/// appointment or finding a time, with a live transcript and the outcome.
class CallOutPage extends StatefulWidget {
  const CallOutPage({super.key, required this.runtime, this.number = '', this.name = ''});
  final ReceptionistRuntime runtime;

  /// Pre-filled from a contact.
  final String number;
  final String name;

  @override
  State<CallOutPage> createState() => _CallOutPageState();
}

class _CallOutPageState extends State<CallOutPage> {
  late final _number = TextEditingController(text: widget.number);
  final _objective = TextEditingController();
  final _message = TextEditingController();
  final _day = TextEditingController();
  double _hold = 10;
  String? _error;
  late String _contact = widget.name;

  static const _examples = [
    'book a haircut on Friday afternoon',
    'find a time for a 30-minute call next week',
    'schedule a dental cleaning',
    'reach the billing department about my last invoice',
  ];

  @override
  void dispose() {
    _number.dispose();
    _objective.dispose();
    _message.dispose();
    _day.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_number.text.trim().isEmpty || _objective.text.trim().isEmpty) {
      setState(() => _error = 'Enter a number and what the assistant should do.');
      return;
    }
    final objective = _objective.text.trim().replaceFirst(RegExp(r'^(please |i want you to |to )', caseSensitive: false), '');
    final task = OutboundTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      number: _number.text.trim(),
      objective: objective,
      contactName: _contact,
      message: _message.text.trim(),
      preferredDay: _day.text.trim(),
      maxHoldMinutes: _hold.round(),
    );
    final error = await widget.runtime.startCallOut(task);
    if (mounted) setState(() => _error = error);
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Call for me')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: runtime,
          builder: (context, _) {
            final session = runtime.session;
            final active = runtime.callOuts.where((t) => t.status != 'done').firstOrNull;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Who should the assistant call?', style: text.titleMedium),
                const SizedBox(height: 8),
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
                        final picked = await pickContact(context, runtime, title: 'Who should it call?');
                        if (picked != null) {
                          setState(() {
                            _number.text = picked.number;
                            _contact = picked.name;
                          });
                        }
                      },
                    ),
                  ),
                  onChanged: (_) => _contact = '',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final contact in runtime.contacts.byStatus(ContactStatus.known).take(8))
                      ActionChip(
                        label: Text(contact.label),
                        onPressed: () => setState(() {
                          _number.text = contact.numbers.first;
                          _contact = contact.label;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('What should it do?', style: text.titleMedium),
                Text('Finish the sentence "I\'m calling to …"', style: text.bodySmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _objective,
                  autofocus: widget.number.isNotEmpty,
                  decoration: const InputDecoration(labelText: 'Objective', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final example in _examples)
                      ActionChip(label: Text(example), onPressed: () => setState(() => _objective.text = example)),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _message,
                  decoration: const InputDecoration(
                      labelText: 'Anything to tell them (optional)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _day,
                  decoration: const InputDecoration(
                      labelText: 'Earliest day to offer (optional, e.g. Friday)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Text('Wait on hold up to ${_hold.round()} minutes', style: text.bodySmall),
                Slider(value: _hold, min: 2, max: 30, divisions: 14, onChanged: (v) => setState(() => _hold = v)),
                FilledButton.icon(
                  onPressed: active == null ? _start : null,
                  icon: const Icon(Icons.call),
                  label: const Text('Start call'),
                ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
                if (active != null) ...[
                  const SizedBox(height: 16),
                  Text('Now: ${active.status}', style: text.titleSmall),
                  if (session != null && session.callId != null) TranscriptView(session: session),
                ],
                const Divider(height: 32),
                Text('Recent call-outs', style: text.titleMedium),
                for (final task in runtime.callOuts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(task.contactName.isEmpty ? task.number : task.contactName),
                    subtitle: Text('${task.objective}\n${task.status == 'done' ? task.outcome : task.status}'),
                    isThreeLine: true,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
