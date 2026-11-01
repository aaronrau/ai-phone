import 'package:flutter/material.dart';

import '../contacts.dart';
import '../runtime.dart';
import 'callout_page.dart';
import 'common.dart';
import 'tasks_page.dart';

const _labels = {
  ContactStatus.known: 'Known',
  ContactStatus.screened: 'Screened',
  ContactStatus.unknown: 'Unknown',
  ContactStatus.blocked: 'Blocked',
};

/// Known contacts, screened callers and blocked numbers, with everything the
/// receptionist has learned about each.
class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  /// Selected tab; null shows everyone.
  ContactStatus? _filter;

  Future<void> _add(ContactStatus status) async {
    final name = TextEditingController();
    final number = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(status == ContactStatus.blocked ? 'Add spam number' : 'Add known contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (optional)')),
            TextField(
              controller: number,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone number'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || number.text.trim().isEmpty) return;
    final contact = widget.runtime.contacts.touch(number.text.trim());
    if (name.text.trim().isNotEmpty) contact.name = name.text.trim();
    await widget.runtime.setContactStatus(contact, status,
        reason: status == ContactStatus.blocked ? 'spam (added by owner)' : '');
    setState(() => _filter = null);
  }

  static const _notes = {
    ContactStatus.known: 'Get the assistant on calls and replies to texts.',
    ContactStatus.screened: 'Said who they are; not approved yet.',
    ContactStatus.unknown: 'Called or texted without saying who they are.',
    ContactStatus.blocked: 'Their calls and texts never reach you.',
  };

  @override
  Widget build(BuildContext context) {
    final runtime = widget.runtime;
    final text = Theme.of(context).textTheme;
    final list = _filter == null
        ? (runtime.contacts.contacts.where((c) => c.status != ContactStatus.blocked).toList()
          ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase())))
        : runtime.contacts.byStatus(_filter!);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
      children: [
        Row(
          children: [
            Expanded(
              child: FilterTabs<ContactStatus?>(
                values: const [null, ...ContactStatus.values],
                selected: _filter,
                label: (s) => s == null ? 'All' : _labels[s]!,
                count: (s) => s == null
                    ? runtime.contacts.contacts.where((c) => c.status != ContactStatus.blocked).length
                    : runtime.contacts.byStatus(s).length,
                onSelected: (s) => setState(() => _filter = s),
              ),
            ),
            PopupMenuButton<ContactStatus>(
              tooltip: 'Add a number',
              icon: const Icon(Icons.person_add_alt),
              onSelected: _add,
              itemBuilder: (_) => const [
                PopupMenuItem(value: ContactStatus.known, child: Text('Add known contact')),
                PopupMenuItem(value: ContactStatus.blocked, child: Text('Block a number')),
              ],
            ),
          ],
        ),
        Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Muted(_filter == null ? 'Everyone the assistant has talked to, except blocked numbers.' : _notes[_filter]!)),
        if (list.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Nobody here yet.', style: text.bodyMedium)),
        for (final contact in list)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(displayName(contact.label), style: text.titleSmall),
            subtitle: Muted(
              [
                if (contact.name.isNotEmpty) contact.numbers.map(formatPhone).join(', '),
                if (contact.status == ContactStatus.blocked && contact.blockReason.isNotEmpty)
                  contact.blockReason
                else if (contact.history.isNotEmpty)
                  contact.history.last.summary,
              ].join(' · '),
              maxLines: 2,
            ),
            onTap: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: true,
              builder: (_) => _ContactSheet(runtime: runtime, contact: contact),
            ),
          ),
      ],
    );
  }
}

class _ContactSheet extends StatefulWidget {
  const _ContactSheet({required this.runtime, required this.contact});
  final ReceptionistRuntime runtime;
  final TrackedContact contact;

  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  late final _name = TextEditingController(text: widget.contact.name);
  late final _organization = TextEditingController(text: widget.contact.organization);
  late final _relationship = TextEditingController(text: widget.contact.relationship);
  late final _facts = TextEditingController(text: widget.contact.facts.join('\n'));

  @override
  void dispose() {
    _name.dispose();
    _organization.dispose();
    _relationship.dispose();
    _facts.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.contact
      ..name = _name.text.trim()
      ..organization = _organization.text.trim()
      ..relationship = _relationship.text.trim();
    c.facts
      ..clear()
      ..addAll(_facts.text.split('\n').map((f) => f.trim()).where((f) => f.isNotEmpty));
    await widget.runtime.saveContacts();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _setStatus(ContactStatus status) async {
    await widget.runtime.setContactStatus(widget.contact, status);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.contact;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.numbers.map(formatPhone).join(', '), style: text.titleMedium),
            Text('Status: ${_labels[c.status]}', style: text.bodySmall),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: _organization, decoration: const InputDecoration(labelText: 'Organization')),
            TextField(controller: _relationship, decoration: const InputDecoration(labelText: 'Relationship')),
            TextField(
              controller: _facts,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(labelText: 'What the receptionist knows (one per line)'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(onPressed: _save, child: const Text('Save')),
                if (c.numbers.isNotEmpty && c.status != ContactStatus.blocked) ...[
                  OutlinedButton(
                    onPressed: () {
                      final navigator = Navigator.of(context)..pop();
                      navigator.push(MaterialPageRoute<void>(
                          builder: (_) => InboundTaskPage(runtime: widget.runtime, number: c.numbers.first, name: c.label)));
                    },
                    child: const Text('Task for their next call'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      final navigator = Navigator.of(context)..pop();
                      navigator.push(MaterialPageRoute<void>(
                          builder: (_) => CallOutPage(runtime: widget.runtime, number: c.numbers.first, name: c.label)));
                    },
                    child: const Text('Call them for me'),
                  ),
                ],
                if (c.status != ContactStatus.known)
                  OutlinedButton(onPressed: () => _setStatus(ContactStatus.known), child: const Text('Mark known')),
                if (c.status != ContactStatus.blocked)
                  OutlinedButton(onPressed: () => _setStatus(ContactStatus.blocked), child: const Text('Block as spam')),
                if (c.status == ContactStatus.blocked)
                  OutlinedButton(onPressed: () => _setStatus(ContactStatus.unknown), child: const Text('Unblock')),
                TextButton(
                  onPressed: () async {
                    if (c.status == ContactStatus.blocked) await widget.runtime.setContactStatus(c, ContactStatus.unknown);
                    widget.runtime.contacts.contacts.remove(c);
                    await widget.runtime.saveContacts();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('Delete'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('History', style: text.titleSmall),
            for (final event in c.history.reversed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${event.time.month}/${event.time.day} ${event.time.hour.toString().padLeft(2, '0')}:'
                  '${event.time.minute.toString().padLeft(2, '0')} · ${event.channel} · ${event.summary}',
                  style: text.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
