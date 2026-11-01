import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../runtime.dart';
import '../texting.dart';
import 'common.dart';
import 'home_page.dart' show shortTime;

/// Names for phone numbers: the receptionist's contact book first, then the
/// phone's contacts. Cached for the life of the app.
class _Names {
  static final Map<String, String> _cache = {};

  static String now(ReceptionistRuntime runtime, String number) =>
      displayName(runtime.contacts.find(number)?.label ?? _cache[number] ?? number);

  static Future<void> load(ReceptionistRuntime runtime, Iterable<String> numbers) async {
    for (final number in numbers) {
      if (_cache.containsKey(number) || runtime.contacts.find(number) != null) continue;
      _cache[number] = await runtime.api.lookupContact(number) ?? number;
    }
  }
}

/// All conversations, newest first.
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  List<TextThread> _threads = [];
  bool _loaded = false;
  int _version = -1;

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_maybeReload);
    _load();
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_maybeReload);
    super.dispose();
  }

  void _maybeReload() {
    if (widget.runtime.textsVersion != _version) _load();
  }

  Future<void> _load() async {
    final runtime = widget.runtime;
    _version = runtime.textsVersion;
    try {
      final threads = await runtime.texting.threads();
      await _Names.load(runtime, threads.expand((t) => t.addresses));
      if (mounted) setState(() => _threads = threads);
    } catch (_) {
      // Without the messaging role or permission the list stays empty.
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    final isDefault = runtime.status['smsRole'] == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
        children: [
          if (!isDefault)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: const Text('Set as your messaging app to read and send texts here.'),
              trailing: TextButton(
                onPressed: () => runtime.api.call('requestRole', {'role': 'sms'}),
                child: const Text('Set'),
              ),
            ),
          if (_loaded && _threads.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No conversations.', style: text.bodyMedium),
            ),
          for (final thread in _threads)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Row(
                children: [
                  if (thread.unread)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.circle, size: 8, color: Theme.of(context).colorScheme.onSurface),
                    ),
                  Expanded(
                    child: Text(_title(runtime, thread),
                        overflow: TextOverflow.ellipsis,
                        style: thread.unread ? text.titleSmall?.copyWith(fontWeight: FontWeight.w700) : text.titleSmall),
                  ),
                  Muted(shortTime(thread.date)),
                ],
              ),
              subtitle: Text(thread.snippet.isEmpty ? 'Picture message' : thread.snippet,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
              onTap: () => openThread(context, runtime, thread.id, thread.addresses),
            ),
        ],
      ),
    );
  }

  static String _title(ReceptionistRuntime runtime, TextThread thread) =>
      thread.addresses.isEmpty ? 'Unknown' : thread.addresses.map((a) => _Names.now(runtime, a)).join(', ');
}

/// Opens a conversation screen.
Future<void> openThread(BuildContext context, ReceptionistRuntime runtime, int threadId, List<String> addresses,
    {String draft = ''}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ThreadPage(runtime: runtime, threadId: threadId, addresses: addresses, draft: draft)));

/// Opens the conversation with [number], creating it when needed.
Future<void> openThreadFor(BuildContext context, ReceptionistRuntime runtime, String number, {String draft = ''}) async {
  final threadId = await runtime.texting.threadFor(number);
  if (!context.mounted) return;
  await openThread(context, runtime, threadId, [number], draft: draft);
}

/// One conversation with a reply box.
class ThreadPage extends StatefulWidget {
  const ThreadPage({
    super.key,
    required this.runtime,
    required this.threadId,
    required this.addresses,
    this.draft = '',
  });

  final ReceptionistRuntime runtime;
  final int threadId;
  final List<String> addresses;
  final String draft;

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<ThreadPage> {
  late final TextEditingController _reply = TextEditingController(text: widget.draft);
  List<TextMessage> _messages = [];
  late List<String> _addresses = widget.addresses;
  int _version = -1;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    widget.runtime.addListener(_maybeReload);
    _load();
  }

  @override
  void dispose() {
    widget.runtime.removeListener(_maybeReload);
    _reply.dispose();
    super.dispose();
  }

  void _maybeReload() {
    if (widget.runtime.textsVersion != _version) _load();
  }

  Future<void> _load() async {
    final runtime = widget.runtime;
    _version = runtime.textsVersion;
    if (widget.threadId < 0) return;
    try {
      final messages = await runtime.texting.messages(widget.threadId);
      if (_addresses.isEmpty) {
        _addresses = messages.where((m) => !m.outgoing && m.address.isNotEmpty).map((m) => m.address).toSet().toList();
      }
      await _Names.load(runtime, _addresses);
      if (mounted) setState(() => _messages = messages);
      if (messages.any((m) => !m.outgoing)) await runtime.texting.markRead(widget.threadId);
    } catch (_) {}
  }

  Future<void> _send() async {
    final body = _reply.text.trim();
    if (body.isEmpty || _addresses.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      // Group replies are sent to each person as separate texts.
      for (final address in _addresses) {
        await widget.runtime.sendText(address, body);
      }
      _reply.clear();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete this conversation?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(dialog).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.runtime.texting.deleteThread(widget.threadId);
    widget.runtime.textsVersion++;
    widget.runtime.changed();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final title = _addresses.isEmpty ? 'Conversation' : _addresses.map((a) => _Names.now(runtime, a)).join(', ');
    final single = _addresses.length == 1 ? _addresses.single : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          if (single != null)
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => runtime.api.call('placeCall', {'number': single}),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'delete') _delete();
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete conversation'))],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: _messages.length,
                itemBuilder: (context, index) => _Bubble(
                  message: _messages[_messages.length - 1 - index],
                  runtime: runtime,
                  showSender: _addresses.length > 1,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _reply,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'Text message', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.runtime, required this.showSender});
  final TextMessage message;
  final ReceptionistRuntime runtime;
  final bool showSender;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final outgoing = message.outgoing;
    final status = message.failed ? 'Not sent' : (message.pending ? 'Sending…' : shortTime(message.date));
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(
            crossAxisAlignment: outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (showSender && !outgoing)
                Text(_Names.now(runtime, message.address), style: text.labelSmall),
              for (final part in message.images) _Picture(runtime: runtime, partId: part),
              if (message.body.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: outgoing ? colors.primaryContainer : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: SelectableText(message.body, style: text.bodyMedium),
                ),
              Text(status, style: text.labelSmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _Picture extends StatelessWidget {
  const _Picture({required this.runtime, required this.partId});
  final ReceptionistRuntime runtime;
  final int partId;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: runtime.texting.picture(partId),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return const SizedBox(width: 160, height: 120);
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(bytes, width: 220, fit: BoxFit.cover),
          ),
        );
      },
    );
  }
}
