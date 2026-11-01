import 'package:flutter/material.dart';

import '../contacts.dart';
import '../policy.dart';
import '../runtime.dart';
import 'common.dart';

/// A person (or bare number) picked from the contact search.
typedef PickedContact = ({String name, String number});

/// Opens the contact search: the assistant's contacts and the phone's address
/// book, searchable by name or number. When a typed number matches nobody it
/// can be used as is, or saved as a new contact first.
Future<PickedContact?> pickContact(BuildContext context, ReceptionistRuntime runtime,
        {String title = 'Choose a contact', String useLabel = 'Use'}) =>
    Navigator.of(context).push<PickedContact>(MaterialPageRoute(
        builder: (_) => ContactPickerPage(runtime: runtime, title: title, useLabel: useLabel)));

class ContactPickerPage extends StatefulWidget {
  const ContactPickerPage({super.key, required this.runtime, required this.title, required this.useLabel});
  final ReceptionistRuntime runtime;
  final String title;

  /// Verb for a typed number, e.g. "Call" or "Text".
  final String useLabel;

  @override
  State<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<ContactPickerPage> {
  final _query = TextEditingController();
  List<PickedContact> _phone = [];

  @override
  void initState() {
    super.initState();
    _loadPhoneContacts();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadPhoneContacts() async {
    try {
      final rows = await widget.runtime.api.call<List>('contacts') ?? const [];
      final list = [
        for (final r in rows)
          if (r is Map && (r['number'] ?? '').toString().isNotEmpty)
            (name: (r['name'] ?? '').toString(), number: (r['number'] ?? '').toString()),
      ];
      if (mounted) setState(() => _phone = list);
    } catch (_) {
      // No contacts permission: the assistant's own contacts still show.
    }
  }

  /// Everyone, deduplicated by number: the assistant's contacts first.
  List<PickedContact> get _everyone {
    final seen = <String>[];
    final result = <PickedContact>[];
    void add(String name, String number) {
      if (seen.any((n) => sameNumber(n, number))) return;
      seen.add(number);
      result.add((name: name, number: number));
    }

    for (final c in widget.runtime.contacts.contacts) {
      if (c.status == ContactStatus.blocked) continue;
      for (final n in c.numbers) {
        add(c.name, n);
      }
    }
    for (final p in _phone) {
      add(p.name, p.number);
    }
    result.sort((a, b) => (a.name.isEmpty ? '~${a.number}' : a.name.toLowerCase())
        .compareTo(b.name.isEmpty ? '~${b.number}' : b.name.toLowerCase()));
    return result;
  }

  Future<void> _addContact(String number) async {
    final name = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Add ${formatPhone(number)}'),
        content: TextField(
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final contact = widget.runtime.contacts.touch(number);
    if (name.text.trim().isNotEmpty) contact.name = name.text.trim();
    await widget.runtime.setContactStatus(contact, ContactStatus.known);
    if (mounted) Navigator.of(context).pop((name: contact.name, number: number));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final query = _query.text.trim();
    final digits = query.replaceAll(RegExp(r'[^\d]'), '');
    final lower = query.toLowerCase();
    final matches = query.isEmpty
        ? _everyone
        : _everyone
            .where((c) =>
                c.name.toLowerCase().contains(lower) ||
                (digits.length >= 3 && c.number.replaceAll(RegExp(r'[^\d]'), '').contains(digits)))
            .toList();
    final typedNumber = digits.length >= 3 && RegExp(r'^[\d\s()+.-]+$').hasMatch(query);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _query,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search by name or number',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  if (typedNumber && matches.isEmpty) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.dialpad),
                      title: Text('${widget.useLabel} ${formatPhone(query)}'),
                      onTap: () => Navigator.of(context).pop((name: '', number: query)),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_add_alt),
                      title: Text('Add ${formatPhone(query)} to contacts'),
                      onTap: () => _addContact(query),
                    ),
                  ],
                  if (!typedNumber && query.isNotEmpty && matches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text('No one matches "$query". Type a number to use it.', style: text.bodyMedium),
                    ),
                  for (final c in matches.take(200))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(c.name.isEmpty ? formatPhone(c.number) : c.name, style: text.titleSmall),
                      subtitle: c.name.isEmpty ? null : Muted(formatPhone(c.number)),
                      onTap: () => Navigator.of(context).pop(c),
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
