import 'package:flutter/material.dart';

import '../runtime.dart';

/// Short descriptions of setup steps that still need attention, in the order
/// the owner should fix them. Empty when the assistant is fully ready.
List<String> setupIssues(ReceptionistRuntime runtime) {
  final status = runtime.status;
  if (status.isEmpty) return const [];
  final permissions = (status['permissions'] as Map?)?.cast<String, dynamic>() ?? const {};
  return [
    if (permissions.values.any((granted) => granted != true)) 'grant permissions',
    if (status['dialerRole'] != true) 'make it the default phone app',
    if (status['callAudioHelper'] != true) 'start the call audio helper',
    if (status['batteryExempt'] != true) 'allow it to run in the background',
    if (status['overlayAllowed'] == false) 'allow full speed during calls',
    if (runtime.modelState == 'failed') 'reload the models',
  ];
}

/// Phone permissions and roles the assistant needs, each with one action.
class SetupPage extends StatelessWidget {
  const SetupPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Setup and permissions')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: runtime,
          builder: (context, _) {
            final status = runtime.status;
            final permissions = (status['permissions'] as Map?)?.cast<String, dynamic>() ?? const {};
            final missing =
                permissions.entries.where((e) => e.value != true).map((e) => e.key.split('.').last).toList();
            return RefreshIndicator(
              onRefresh: runtime.refreshStatus,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _SetupRow(
                    label: 'Permissions',
                    done: missing.isEmpty,
                    detail: missing.isEmpty ? 'All granted' : 'Missing: ${missing.join(', ')}',
                    action: 'Grant',
                    onPressed: () => runtime.api.call('requestPermissions'),
                  ),
                  _SetupRow(
                    label: 'Default phone app',
                    done: status['dialerRole'] == true,
                    detail: 'Needed to answer calls for you.',
                    action: 'Set',
                    onPressed: () => runtime.api.call('requestRole', {'role': 'dialer'}),
                  ),
                  _SetupRow(
                    label: 'Default messaging app',
                    done: status['smsRole'] == true,
                    detail: 'Read and send texts here; the assistant decides which texts notify you.',
                    action: 'Set',
                    onPressed: () => runtime.api.call('requestRole', {'role': 'sms'}),
                  ),
                  _SetupRow(
                    label: 'Call screening',
                    done: status['screeningRole'] == true || status['dialerRole'] == true,
                    detail: 'Silently blocks callers who are not allowed.',
                    action: 'Set',
                    onPressed: () => runtime.api.call('requestRole', {'role': 'screening'}),
                  ),
                  _SetupRow(
                    label: 'Call audio helper',
                    done: status['callAudioHelper'] == true,
                    detail: 'Hears the caller and speaks into the call. Start it from a computer with '
                        'tool/start_call_audio_helper.sh, again after a reboot or app update.',
                    action: 'Check',
                    onPressed: runtime.refreshStatus,
                  ),
                  _SetupRow(
                    label: 'Run in background',
                    done: status['batteryExempt'] == true,
                    detail: 'Keeps the assistant ready while the app is closed.',
                    action: 'Allow',
                    onPressed: () => runtime.api.call('requestBatteryExemption'),
                  ),
                  _SetupRow(
                    label: 'Full speed during calls',
                    done: status['overlayAllowed'] != false,
                    detail: 'Some phones slow down apps with nothing on screen, so the assistant '
                        'pauses mid-sentence. "Display over other apps" lets it keep an invisible '
                        'one-pixel window during its calls.',
                    action: 'Allow',
                    onPressed: () => runtime.api.call('requestOverlay'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Model state, reload, and the call audio probe.
class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  static String _ok(Object? value) => value == true ? 'ready' : 'missing';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Models and diagnostics')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: runtime,
          builder: (context, _) {
            final status = runtime.status;
            final gemma = (status['gemma'] as List?)?.join(', ') ?? '';
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('On-device models', style: text.titleMedium),
                const SizedBox(height: 8),
                Text('State: ${runtime.modelState}${runtime.modelError == null ? '' : ' — ${runtime.modelError}'}'),
                Text('Responder: ${runtime.config.responder} · decision model ${runtime.decisionReady ? 'ready' : 'not loaded'}',
                    style: text.bodySmall),
                Text('Decision model: ${runtime.config.decisionModel}', style: text.bodySmall),
                Text('Gemma: ${runtime.config.gemmaModel}${gemma.isEmpty ? ' (no model files found)' : ''}',
                    style: text.bodySmall),
                Text('Speech: ${runtime.config.sttModel} ${_ok(status['parakeet'])} · Silero VAD ${_ok(status['vad'])} · '
                    'Pocket TTS ${_ok(status['pocket'])}', style: text.bodySmall),
                Text('Model folder: ${status['modelsDir'] ?? '…'}', style: text.bodySmall),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: runtime.modelState.startsWith('loading') ? null : runtime.loadModels,
                    icon: const Icon(Icons.memory),
                    label: const Text('Reload models'),
                  ),
                ),
                const Divider(height: 32),
                Text('Diagnostics', style: text.titleMedium),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Audio probe on next call'),
                  subtitle: const Text('Answers the next incoming call, tests each microphone source and playback '
                      'route, then hangs up.'),
                  value: runtime.probeNextCall,
                  onChanged: (value) {
                    runtime.probeNextCall = value;
                    runtime.changed();
                  },
                ),
                for (final result in runtime.probeResults)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      result.entries.map((e) => '${e.key}=${e.value}').join('  '),
                      style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.label,
    required this.done,
    required this.detail,
    required this.action,
    required this.onPressed,
  });

  final String label;
  final bool done;
  final String detail;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked),
      title: Text(label),
      subtitle: Text(done ? 'Done' : detail),
      trailing: done ? null : OutlinedButton(onPressed: onPressed, child: Text(action)),
    );
  }
}
