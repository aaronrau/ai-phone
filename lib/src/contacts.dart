import 'dart:convert';

import 'policy.dart';

/// How the receptionist treats a number.
enum ContactStatus {
  /// Allowed: gets the known workflow on calls and replies to texts.
  known,

  /// Identified themselves during screening; awaiting the owner's decision.
  screened,

  /// Seen, but never identified.
  unknown,

  /// On Android's system block list (spam, or an unknown texter).
  blocked,
}

class ContactEvent {
  ContactEvent(this.time, this.channel, this.summary);
  final DateTime time;
  final String channel;
  final String summary;

  Map<String, dynamic> toJson() => {'time': time.toIso8601String(), 'channel': channel, 'summary': summary};
  factory ContactEvent.fromJson(Map<String, dynamic> json) => ContactEvent(
        DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        (json['channel'] ?? '').toString(),
        (json['summary'] ?? '').toString(),
      );
}

/// What the receptionist knows about one person, built up over time.
class TrackedContact {
  TrackedContact({
    required this.id,
    required this.numbers,
    this.name = '',
    this.organization = '',
    this.relationship = '',
    this.status = ContactStatus.unknown,
    this.blockReason = '',
    List<String>? facts,
    List<ContactEvent>? history,
    DateTime? firstSeen,
    DateTime? lastSeen,
  })  : facts = facts ?? [],
        history = history ?? [],
        firstSeen = firstSeen ?? DateTime.now(),
        lastSeen = lastSeen ?? DateTime.now();

  final String id;
  final List<String> numbers;
  String name;
  String organization;
  String relationship;
  ContactStatus status;
  String blockReason;
  final List<String> facts;
  final List<ContactEvent> history;
  DateTime firstSeen;
  DateTime lastSeen;

  static const maxFacts = 20;
  static const maxHistory = 30;

  String get label => name.isNotEmpty ? name : (numbers.isEmpty ? 'Unknown' : numbers.first);

  bool matches(String number) => numbers.any((n) => sameNumber(n, number));

  void addFact(String fact) {
    final clean = fact.trim();
    if (clean.isEmpty || facts.any((f) => f.toLowerCase() == clean.toLowerCase())) return;
    facts.add(clean);
    if (facts.length > maxFacts) facts.removeAt(0);
  }

  void addEvent(String channel, String summary, DateTime time) {
    history.add(ContactEvent(time, channel, summary));
    if (history.length > maxHistory) history.removeAt(0);
    lastSeen = time;
  }

  /// Compact context for the model; never includes other people's data.
  String describe() {
    final parts = <String>[
      if (organization.isNotEmpty) 'from $organization',
      if (relationship.isNotEmpty) relationship,
      if (facts.isNotEmpty) 'known facts: ${facts.join('; ')}',
    ];
    final recent = history.reversed.take(3).toList().reversed;
    if (recent.isNotEmpty) {
      parts.add('recent contact: ${recent.map((e) => '${_date(e.time)} ${e.channel}: ${e.summary}').join(' | ')}');
    }
    return parts.join('; ');
  }

  static String _date(DateTime t) => '${t.month}/${t.day}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'numbers': numbers,
        'name': name,
        'organization': organization,
        'relationship': relationship,
        'status': status.name,
        'block_reason': blockReason,
        'facts': facts,
        'history': [for (final e in history) e.toJson()],
        'first_seen': firstSeen.toIso8601String(),
        'last_seen': lastSeen.toIso8601String(),
      };

  factory TrackedContact.fromJson(Map<String, dynamic> json) => TrackedContact(
        id: json['id'].toString(),
        numbers: [for (final n in (json['numbers'] as List? ?? const [])) n.toString()],
        name: (json['name'] ?? '').toString(),
        organization: (json['organization'] ?? '').toString(),
        relationship: (json['relationship'] ?? '').toString(),
        status: ContactStatus.values.firstWhere((s) => s.name == json['status'], orElse: () => ContactStatus.unknown),
        blockReason: (json['block_reason'] ?? '').toString(),
        facts: [for (final f in (json['facts'] as List? ?? const [])) f.toString()],
        history: [
          for (final e in (json['history'] as List? ?? const []))
            ContactEvent.fromJson((e as Map).cast<String, dynamic>()),
        ],
        firstSeen: DateTime.tryParse(json['first_seen']?.toString() ?? ''),
        lastSeen: DateTime.tryParse(json['last_seen']?.toString() ?? ''),
      );
}

/// All tracked people, keyed by number.
class ContactBook {
  ContactBook(this.contacts);
  final List<TrackedContact> contacts;

  factory ContactBook.empty() => ContactBook([]);

  factory ContactBook.fromJson(Map<String, dynamic> json) => ContactBook([
        for (final c in (json['contacts'] as List? ?? const []))
          TrackedContact.fromJson((c as Map).cast<String, dynamic>()),
      ]);

  Map<String, dynamic> toJson() => {'contacts': [for (final c in contacts) c.toJson()]};
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  TrackedContact? find(String number) {
    if (number.trim().isEmpty) return null;
    for (final contact in contacts) {
      if (contact.matches(number)) return contact;
    }
    return null;
  }

  /// Finds or creates the entry for [number].
  TrackedContact touch(String number, {ContactStatus status = ContactStatus.unknown}) {
    final existing = find(number);
    if (existing != null) return existing;
    final created = TrackedContact(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      numbers: [normalizeNumber(number)],
      status: status,
    );
    contacts.add(created);
    return created;
  }

  List<TrackedContact> byStatus(ContactStatus status) =>
      contacts.where((c) => c.status == status).toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
}
