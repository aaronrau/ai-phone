import 'package:flutter/material.dart';

import '../runtime.dart';
import 'test_page.dart';

/// In-call screen for every call, since this app is the default phone app.
class CallScreen extends StatelessWidget {
  const CallScreen({super.key, required this.runtime, required this.callId});
  final ReceptionistRuntime runtime;
  final String callId;

  Future<void> _call(String method, [Map<String, dynamic>? args]) =>
      runtime.api.call(method, {'callId': callId, ...?args});

  @override
  Widget build(BuildContext context) {
    final info = runtime.calls[callId]!;
    final text = Theme.of(context).textTheme;
    final session = runtime.session?.callId == callId ? runtime.session : null;
    final ringing = info.state == 'ringing';
    final who = info.disposition?.name ?? (info.number.isEmpty ? 'Unknown caller' : info.number);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text(who, style: text.headlineSmall, textAlign: TextAlign.center),
              if (info.disposition?.name != null)
                Text(info.number, style: text.bodyMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                '${info.state}${info.aiHandled ? ' · receptionist answering' : ''}'
                '${info.disposition == null ? '' : ' · ${info.disposition!.workflow.name}'}',
                style: text.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: session == null
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(reverse: true, child: TranscriptView(session: session)),
              ),
              if (ringing)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(onPressed: () => _call('callReject'), child: const Text('Decline')),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          info.aiHandled = false;
                          _call('callAnswer');
                        },
                        child: const Text('Answer'),
                      ),
                    ),
                  ],
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => runtime.api.call('callSpeaker', {'on': !info.speaker}),
                        icon: Icon(info.speaker ? Icons.volume_up : Icons.volume_down),
                        label: Text(info.speaker ? 'Speaker on' : 'Speaker off'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => runtime.api.call('callMute', {'on': !info.muted}),
                        icon: Icon(info.muted ? Icons.mic_off : Icons.mic),
                        label: Text(info.muted ? 'Muted' : 'Mute'),
                      ),
                    ),
                  ],
                ),
                if (session != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: () => runtime.takeOver(callId), child: const Text('Take over call')),
                ],
                const SizedBox(height: 8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () => _call('callHangup'),
                  child: const Text('Hang up'),
                ),
              ],
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  runtime.focusCallId = null;
                  runtime.changed();
                },
                child: const Text('Back to app'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DialPad extends StatefulWidget {
  const DialPad({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<DialPad> createState() => _DialPadState();
}

class _DialPadState extends State<DialPad> {
  late String _number = widget.runtime.dialNumber ?? '';

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close dial pad',
          icon: const Icon(Icons.close),
          onPressed: () {
            widget.runtime.dialNumber = null;
            widget.runtime.changed();
          },
        ),
        title: const Text('Call'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(_number.isEmpty ? ' ' : _number, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 3,
                  childAspectRatio: 1.6,
                  children: [
                    for (final key in keys)
                      TextButton(
                        onPressed: () => setState(() => _number += key),
                        child: Text(key, style: Theme.of(context).textTheme.headlineSmall),
                      ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _number.isEmpty
                          ? null
                          : () => setState(() => _number = _number.substring(0, _number.length - 1)),
                      child: const Text('Delete'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _number.isEmpty
                          ? null
                          : () {
                              widget.runtime.api.call('placeCall', {'number': _number});
                              widget.runtime.dialNumber = null;
                              widget.runtime.changed();
                            },
                      child: const Text('Call'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
