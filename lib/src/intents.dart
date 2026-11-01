import 'dart:math' as math;

/// How a detected topic affects screening.
enum IntentKind {
  /// A useful, valid reason for the call (e.g. plans, work, an appointment).
  reason('Valid reason'),

  /// Not a reason: asking for the owner, "it's personal", "something".
  vague('Not a reason'),

  /// Selling, asking for money, or other spam.
  spam('Spam');

  const IntentKind(this.label);
  final String label;
}

/// A configurable topic/intent with example phrases.
class IntentDef {
  IntentDef({required this.name, required this.kind, required this.examples});

  factory IntentDef.fromJson(Map<String, dynamic> json) => IntentDef(
        name: (json['name'] ?? '').toString(),
        kind: IntentKind.values.firstWhere((k) => k.name == json['kind'], orElse: () => IntentKind.reason),
        examples: [for (final e in (json['examples'] as List? ?? const [])) e.toString()],
      );

  final String name;
  final IntentKind kind;
  final List<String> examples;

  Map<String, dynamic> toJson() => {'name': name, 'kind': kind.name, 'examples': examples};

  static List<IntentDef> get defaults => [
        IntentDef(name: 'Plans', kind: IntentKind.reason, examples: [
          'about the dinner plans tonight',
          'are we still meeting for coffee',
          'plans for the weekend',
          'what time should we meet',
          'are you free for lunch this weekend',
        ]),
        IntentDef(name: 'Family', kind: IntentKind.reason, examples: [
          'it is about mom and dad',
          'the kids need to be picked up from school',
          'family gathering this weekend',
        ]),
        IntentDef(name: 'Work', kind: IntentKind.reason, examples: [
          'about the project deadline',
          'the meeting tomorrow at work',
          'a question about the report you sent',
          'the project review was moved to another day',
        ]),
        IntentDef(name: 'Appointment', kind: IntentKind.reason, examples: [
          'confirming your appointment on Tuesday',
          'rescheduling the dentist appointment',
          'your reservation is ready',
        ]),
        IntentDef(name: 'Delivery', kind: IntentKind.reason, examples: [
          'I have a package delivery for you',
          'the delivery driver is outside',
          'where should I leave the package',
        ]),
        IntentDef(name: 'Billing', kind: IntentKind.reason, examples: [
          'about the invoice from last month',
          'a question about your bill',
          'the payment for the repair',
        ]),
        IntentDef(name: 'Urgent', kind: IntentKind.reason, examples: [
          'it is an emergency',
          'someone is in the hospital',
          'it is urgent please get him',
        ]),
        IntentDef(name: 'Wants to talk', kind: IntentKind.vague, examples: [
          'can I talk to him',
          'is he there',
          'I just want to speak with him',
          'put me through please',
        ]),
        IntentDef(name: 'No reason given', kind: IntentKind.vague, examples: [
          'it is personal',
          'about something',
          'just a quick question',
          'nothing important',
        ]),
        IntentDef(name: 'Sales', kind: IntentKind.spam, examples: [
          'we have a special offer for you',
          'your car warranty is about to expire',
          'lower the interest rate on your credit card',
        ]),
        IntentDef(name: 'Money request', kind: IntentKind.spam, examples: [
          'you need to pay right now',
          'send us gift cards',
          'confirm your bank account details',
        ]),
      ];
}

/// The best-matching topic for something a caller said.
class IntentMatch {
  IntentMatch(this.intent, this.score);
  final IntentDef intent;

  /// Cosine similarity of the closest example (0..1 for normalised vectors).
  final double score;

  /// Shown at the start of notifications: "Plans", "Wants to talk (not a
  /// reason)" or "Spam: Sales".
  String get label => intentLabel(intent.name, intent.kind);

  @override
  String toString() => '${intent.name} (${intent.kind.name}, ${score.toStringAsFixed(2)})';
}

/// Detects topics by comparing sentence embeddings with each intent's
/// examples. [embed] returns L2-normalised vectors (the on-device model).
class IntentDetector {
  IntentDetector({required this.intents, required this.embed, this.threshold = 0.70});

  final List<IntentDef> intents;
  final Future<List<List<double>>> Function(List<String> texts) embed;

  /// Minimum similarity for a match.
  final double threshold;

  final Map<String, List<double>> _vectors = {};

  bool get ready => intents.every((i) => i.examples.every(_vectors.containsKey));

  /// Embeds every example once.
  Future<void> prepare() async {
    final missing = {for (final i in intents) ...i.examples}.where((e) => !_vectors.containsKey(e)).toList();
    for (var start = 0; start < missing.length; start += 16) {
      final batch = missing.sublist(start, math.min(start + 16, missing.length));
      final vectors = await embed(batch);
      for (var i = 0; i < batch.length; i++) {
        _vectors[batch[i]] = vectors[i];
      }
    }
  }

  /// The closest intent above [threshold], or null.
  Future<IntentMatch?> detect(String text) async {
    final best = await rank(text);
    return best.isNotEmpty && best.first.score >= threshold ? best.first : null;
  }

  /// Every intent with its best example similarity, highest first.
  Future<List<IntentMatch>> rank(String text) async {
    if (text.trim().isEmpty) return const [];
    if (!ready) await prepare();
    final query = (await embed([text])).first;
    final ranked = [
      for (final intent in intents)
        if (intent.examples.isNotEmpty)
          IntentMatch(intent, intent.examples.map((e) => _dot(query, _vectors[e]!)).reduce(math.max)),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return ranked;
  }

  static double _dot(List<double> a, List<double> b) {
    var sum = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }
}

/// "Plans", "Wants to talk (not a reason)" or "Spam: Sales".
String intentLabel(String name, IntentKind kind) => switch (kind) {
      IntentKind.reason => name,
      IntentKind.vague => '$name (not a reason)',
      IntentKind.spam => name == 'Spam' ? 'Spam' : 'Spam: $name',
    };

/// Notification text with the intent label first, then the message.
String labelled(String? label, String text) =>
    label == null || label.isEmpty ? text : (text.trim().isEmpty ? label : '$label · ${text.trim()}');

