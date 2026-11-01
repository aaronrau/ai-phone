import 'package:flutter/material.dart';

import '../runtime.dart';
import '../voice_session.dart';

/// Speaker mode (talk to the receptionist through the phone's own mic and
/// speaker) and an SMS simulator. Neither places a call or sends a text.
class TestPage extends StatefulWidget {
  const TestPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  final _number = TextEditingController(text: '+15555550123');
  final _sms = TextEditingController();
  final List<(String, String)> _smsLog = [];
  String? _message;
  bool _sending = false;

  @override
  void dispose() {
    _number.dispose();
    _sms.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _message = null);
    final error = await widget.runtime.startSpeakerTest(_number.text.trim());
    if (mounted) setState(() => _message = error);
  }

  Future<void> _sendSms() async {
    final body = _sms.text.trim();
    if (body.isEmpty) return;
    setState(() {
      _sending = true;
      _smsLog.add(('them', body));
      _sms.clear();
    });
    final reply = await widget.runtime.handleSms(_number.text.trim(), body, simulate: true);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _smsLog.add(('assistant', reply == null || reply.isEmpty ? '(no reply)' : reply));
    });
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    final session = runtime.session;
    final speakerSession = session != null && session.callId == null ? session : null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Pretend caller', style: text.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _number,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Caller number', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final contact in runtime.config.contacts)
              if (contact.numbers.isNotEmpty)
                ActionChip(
                  label: Text(contact.name),
                  onPressed: () => setState(() => _number.text = contact.numbers.first),
                ),
            ActionChip(
              label: const Text('Unknown caller'),
              onPressed: () => setState(() => _number.text = '+15555550123'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Speaker mode', style: text.titleMedium),
        Text('Talk to the receptionist through this phone. No call is placed.', style: text.bodySmall),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: speakerSession == null && session == null ? _start : null,
              icon: const Icon(Icons.mic),
              label: const Text('Start conversation'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: speakerSession == null ? null : () => speakerSession.stop(silenceNow: true),
              child: const Text('Stop'),
            ),
          ],
        ),
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
        if (speakerSession != null) TranscriptView(session: speakerSession),
        const Divider(height: 32),
        Text('Text message simulator', style: text.titleMedium),
        Text('Runs the SMS workflow for the number above without sending anything.', style: text.bodySmall),
        const SizedBox(height: 8),
        for (final (who, body) in _smsLog)
          Align(
            alignment: who == 'them' ? Alignment.centerLeft : Alignment.centerRight,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.all(12),
              constraints: const BoxConstraints(maxWidth: 300),
              decoration: BoxDecoration(
                color: who == 'them'
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(body),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _sms,
                decoration: const InputDecoration(labelText: 'Incoming text', border: OutlineInputBorder()),
                onSubmitted: (_) => _sendSms(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _sending ? null : _sendSms, child: Text(_sending ? 'Thinking…' : 'Send')),
          ],
        ),
      ],
    );
  }
}

class TranscriptView extends StatelessWidget {
  const TranscriptView({super.key, required this.session});
  final VoiceSession session;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            'Status: ${session.state}'
            '${session.levelDb == null ? '' : ' · mic ${session.levelDb!.toStringAsFixed(0)} dB'}',
            style: text.bodySmall,
          ),
          for (final line in session.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '${line.speaker}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: line.text),
              ])),
            ),
        ],
      ),
    );
  }
}
