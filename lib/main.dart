import 'package:flutter/material.dart';

import 'src/native.dart';
import 'src/runtime.dart';
import 'src/ui/call_screen.dart';
import 'src/ui/contact_picker.dart';
import 'src/ui/contacts_page.dart';
import 'src/ui/home_page.dart';
import 'src/ui/messages_page.dart';
import 'src/ui/callout_page.dart';
import 'src/ui/settings_screen.dart';
import 'src/ui/tasks_page.dart';
import 'src/ui/transfer_screen.dart';

/// Runs headless inside the foreground service, and also backs the UI when the
/// activity attaches to the same engine.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final runtime = ReceptionistRuntime(NativeApi.instance);
  runtime.init();
  runApp(ReceptionistApp(runtime: runtime));
}

class ReceptionistApp extends StatelessWidget {
  const ReceptionistApp({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness brightness) => ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF5B6B7A),
            brightness: brightness,
            dynamicSchemeVariant: DynamicSchemeVariant.neutral,
          ),
          useMaterial3: true,
        );
    return MaterialApp(
      title: 'AI Phone',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomeShell(runtime: runtime),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.runtime,
      builder: (context, _) {
        final runtime = widget.runtime;
        final transfer = runtime.transfer;
        if (transfer != null) return TransferScreen(runtime: runtime, request: transfer);
        final callId = runtime.focusCallId;
        if (callId != null && runtime.calls.containsKey(callId)) {
          return CallScreen(runtime: runtime, callId: callId);
        }
        if (runtime.dialNumber != null) return DialPad(runtime: runtime);
        _openRequestedConversation(context, runtime);
        final pages = [
          HomePage(runtime: runtime),
          MessagesPage(runtime: runtime),
          TasksPage(runtime: runtime),
          ContactsPage(runtime: runtime),
          SettingsScreen(runtime: runtime, embedded: true),
        ];
        return Scaffold(
          body: SafeArea(child: pages[_tab]),
          floatingActionButton: switch (_tab) {
            1 => FloatingActionButton.extended(
                onPressed: () => _newText(context, runtime),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Text'),
              ),
            2 => FloatingActionButton.extended(
                onPressed: () => showNewTaskSheet(context, runtime),
                icon: const Icon(Icons.add_task),
                label: const Text('New task'),
              ),
            4 => null,
            _ => FloatingActionButton.extended(
                onPressed: () => _chooseCall(context, runtime),
                icon: const Icon(Icons.call),
                label: const Text('Call'),
              ),
          },
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (value) => setState(() => _tab = value),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Messages'),
              NavigationDestination(
                  icon: Icon(Icons.task_alt_outlined), selectedIcon: Icon(Icons.task_alt), label: 'Tasks'),
              NavigationDestination(icon: Icon(Icons.contacts_outlined), selectedIcon: Icon(Icons.contacts), label: 'Contacts'),
              NavigationDestination(
                  icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }

  /// Opens a conversation asked for by a notification or an sms: link, once.
  void _openRequestedConversation(BuildContext context, ReceptionistRuntime runtime) {
    final thread = runtime.openThreadId;
    final number = runtime.composeNumber;
    if (thread == null && number == null) return;
    final draft = runtime.composeBody;
    runtime.openThreadId = null;
    runtime.composeNumber = null;
    runtime.composeBody = '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      setState(() => _tab = 1);
      if (thread != null) {
        openThread(context, runtime, thread, const []);
      } else if (number!.isEmpty) {
        _newText(context, runtime);
      } else {
        openThreadFor(context, runtime, number.split(',').first, draft: draft);
      }
    });
  }

  /// New text: pick someone (or type a number), then open the conversation.
  Future<void> _newText(BuildContext context, ReceptionistRuntime runtime) async {
    final picked = await pickContact(context, runtime, title: 'New message', useLabel: 'Text');
    if (picked != null && context.mounted) await openThreadFor(context, runtime, picked.number);
  }

  /// The bottom Call button: the assistant calls for you, or you dial.
  void _chooseCall(BuildContext context, ReceptionistRuntime runtime) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.support_agent),
              title: const Text('Call for me'),
              subtitle: const Text('The assistant calls and handles it'),
              onTap: () {
                Navigator.of(sheet).pop();
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CallOutPage(runtime: runtime)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_search_outlined),
              title: const Text('Call someone'),
              subtitle: const Text('Search your contacts by name or number'),
              onTap: () async {
                Navigator.of(sheet).pop();
                final picked = await pickContact(context, runtime, title: 'Call', useLabel: 'Call');
                if (picked != null) await runtime.api.call('placeCall', {'number': picked.number});
              },
            ),
            ListTile(
              leading: const Icon(Icons.dialpad),
              title: const Text('Dial pad'),
              subtitle: const Text('Make the call yourself'),
              onTap: () {
                Navigator.of(sheet).pop();
                runtime.dialNumber = '';
                runtime.changed();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
