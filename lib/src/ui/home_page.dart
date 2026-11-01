import 'package:flutter/material.dart';

import '../call_summary.dart';
import '../contacts.dart';
import '../runtime.dart';
import 'common.dart';
import 'messages_page.dart' show openThreadFor;
import 'setup_page.dart';

/// A summary of calls and texts, filed automatically into Important,
/// Not important, Spam and Blocked.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<CallSummary> _items = [];
  /// Selected filter; null shows everything.
  CallCategory? _category;

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
    final store = widget.runtime.store;
    if (store == null) return;
    final messages = await store.messages();
    final activity = await store.activity(limit: 400);
    if (!mounted) return;
    setState(() => _items = summarizeActivity(activity, widget.runtime.contacts, messages: messages));
  }

  String _status(ReceptionistRuntime runtime) {
    if (!runtime.config.enabled) return 'Off · calls ring normally';
    if (runtime.modelState.startsWith('loading') || runtime.modelState == 'not loaded') return 'Getting ready…';
    if (runtime.modelState == 'failed') return 'Models failed to load';
    if (runtime.status['callAudioHelper'] != true) return 'On for texts · calls need the audio helper';
    return 'On · answering calls and texts';
  }

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    final issues = setupIssues(runtime);
    final shown = _category == null ? _items : _items.where((i) => i.category == _category).toList();
    return RefreshIndicator(
      onRefresh: () async {
        await runtime.refreshStatus();
        await _load();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Assistant', style: text.titleMedium),
            subtitle: Text(_status(runtime), style: text.bodySmall),
            value: runtime.config.enabled,
            onChanged: runtime.setEnabled,
          ),
          if (issues.isNotEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.info_outline),
              title: Text('Finish setup: ${issues.join(', ')}'),
              trailing: TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SetupPage(runtime: runtime))),
                child: const Text('Fix'),
              ),
            ),
          FilterTabs<CallCategory?>(
            values: const [null, ...CallCategory.values],
            selected: _category,
            label: (c) => c?.label ?? 'All',
            count: (c) => c == null ? _items.length : _items.where((i) => i.category == c).length,
            onSelected: (c) => setState(() => _category = c),
          ),
          const SizedBox(height: 4),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Nothing here.', style: text.bodyMedium),
            ),
          for (final item in shown) _SummaryTile(item: item, runtime: runtime),
        ],
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.item, required this.runtime});
  final CallSummary item;
  final ReceptionistRuntime runtime;

  IconData get _icon => switch (item.kind) {
        'callout' => Icons.support_agent,
        'text' => item.outgoing ? Icons.send_outlined : Icons.sms_outlined,
        _ when item.detail == 'Missed call' => Icons.call_missed,
        _ => item.outgoing ? Icons.call_made : Icons.call_received,
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 20,
      leading: Icon(_icon, size: 18, color: colors.onSurfaceVariant),
      title: Row(
        children: [
          Expanded(child: Text(displayName(item.who), style: text.titleSmall, overflow: TextOverflow.ellipsis)),
          Muted(shortTime(item.time)),
        ],
      ),
      subtitle: Text(item.topic.isEmpty ? item.detail : '${item.topic} · ${item.detail}',
          maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
      onTap: () => _showDetails(context),
    );
  }

  Future<void> _confirmBlock(BuildContext context, BuildContext sheet) async {
    final who = displayName(item.who);
    final ok = await showDialog<bool>(
      context: sheet,
      builder: (dialog) => AlertDialog(
        title: Text('Block $who?'),
        content: const Text('Their calls and texts will no longer reach you. You can unblock them in Contacts.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Block')),
        ],
      ),
    );
    if (ok != true) return;
    if (sheet.mounted) Navigator.of(sheet).pop();
    await runtime.setContactStatus(runtime.contacts.touch(item.number), ContactStatus.blocked,
        reason: 'blocked by you');
  }

  void _showDetails(BuildContext context) {
    final canReach = item.number.isNotEmpty &&
        (item.category == CallCategory.important || item.category == CallCategory.other);
    final blocked = runtime.contacts.find(item.number)?.status == ContactStatus.blocked;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) {
        final text = Theme.of(sheet).textTheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.75),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                Text(displayName(item.who), style: text.titleMedium),
                Muted('${item.number.isEmpty ? '' : '${formatPhone(item.number)} · '}${shortTime(item.time)} · '
                    '${item.category.label}${item.topic.isEmpty ? '' : ' · About: ${item.topic}'}'),
                const SizedBox(height: 12),
                if (item.lines.isEmpty) Text(item.detail, style: text.bodyMedium),
                for (final line in item.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: line['speaker'] == 'assistant' ? 'Assistant  ' : 'Them  ', style: text.labelLarge),
                      TextSpan(text: (line['text'] ?? '').toString(), style: text.bodyMedium),
                    ])),
                  ),
                if (canReach) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            Navigator.of(sheet).pop();
                            runtime.api.call('placeCall', {'number': item.number});
                          },
                          icon: const Icon(Icons.call),
                          label: const Text('Call back'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(sheet).pop();
                            openThreadFor(context, runtime, item.number);
                          },
                          icon: const Icon(Icons.sms_outlined),
                          label: const Text('Send text'),
                        ),
                      ),
                    ],
                  ),
                ],
                // Every incoming call or text can be blocked (or unblocked) here.
                if (item.number.isNotEmpty && !item.outgoing && item.kind != 'callout') ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: blocked
                        ? TextButton.icon(
                            onPressed: () async {
                              Navigator.of(sheet).pop();
                              await runtime.setContactStatus(runtime.contacts.touch(item.number), ContactStatus.unknown);
                            },
                            icon: const Icon(Icons.undo),
                            label: const Text('Unblock number'),
                          )
                        : TextButton.icon(
                            onPressed: () => _confirmBlock(context, sheet),
                            icon: const Icon(Icons.block),
                            label: const Text('Block number'),
                          ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

String shortTime(DateTime t) {
  final now = DateTime.now();
  final clock = '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) return clock;
  return '${t.month}/${t.day} $clock';
}
