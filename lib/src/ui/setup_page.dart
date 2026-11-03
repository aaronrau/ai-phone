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
                  _helperRow(context, status),
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

extension on SetupPage {
  /// The call-audio helper: set up once on the phone, then started automatically.
  Widget _helperRow(BuildContext context, Map<String, dynamic> status) {
    final setup = (status['helperSetup'] as Map?)?.cast<String, dynamic>() ?? const {};
    final message = setup['message']?.toString();
    final paired = setup['paired'] == true;
    final busy = setup['busy'] == true;
    final String detail;
    if (setup['supported'] == false) {
      detail = 'Hears the caller and speaks into the call. On this Android version it must be started from a '
          'computer with tool/start_call_audio_helper.sh.';
    } else if (paired) {
      detail = busy ? 'Starting…' : 'Hears the caller and speaks into the call. ${message ?? 'Not running.'}';
    } else {
      detail = 'Hears the caller and speaks into the call. One-time setup on this phone with Wireless debugging; '
          'after that the app starts it by itself, also after a reboot or update.';
    }
    return _SetupRow(
      label: 'Call audio helper',
      done: status['callAudioHelper'] == true,
      detail: detail,
      action: paired ? 'Start' : 'Set up',
      onPressed: busy
          ? null
          : paired
              ? () => runtime.api.call('helperStart')
              : () => _showHelperSetup(context, setup),
    );
  }

  Future<void> _showHelperSetup(BuildContext context, Map<String, dynamic> setup) {
    final developer = setup['developerOptions'] == true;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set up the call audio helper'),
        content: SingleChildScrollView(
          child: Text([
            if (!developer)
              '1. Turn on Developer options: Settings → About phone → tap "Build number" seven times.',
            '${developer ? 1 : 2}. Tap Continue. In Developer options, open Wireless debugging and turn it on. '
                'Tick "Always allow on this network" so the app can restart the helper after a reboot.',
            '${developer ? 2 : 3}. Tap "Pair device with pairing code". Pull down the notification from this app '
                'and type the six-digit code into it.',
            'Some phones (nubia, Xiaomi, Oppo and others) block apps at startup: also allow Auto-start for AI Phone '
                'in the phone\'s battery or app-launch settings, or the helper cannot restart after a reboot.',
            'The app keeps USB debugging on so the helper survives Wi-Fi changes, and turns Wireless debugging '
                'on only while it starts the helper. Nothing leaves the phone.',
          ].join('\n\n')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              runtime.api.call('helperPair');
            },
            child: const Text('Continue'),
          ),
        ],
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
  final VoidCallback? onPressed;

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
