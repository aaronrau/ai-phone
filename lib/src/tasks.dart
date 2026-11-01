import 'policy.dart';

/// What the assistant should do the next time a specific person calls.
enum InboundAction {
  /// Give them a message from the owner.
  tell('Tell them'),

  /// Ask them a question and save the answer for the owner.
  ask('Ask them'),

  /// Warm-transfer them to the owner.
  transfer('Transfer to me');

  const InboundAction(this.label);
  final String label;
}

/// A task for the next call from a number.
class InboundTask {
  InboundTask({
    required this.id,
    required this.number,
    required this.action,
    this.name = '',
    this.topic = '',
    this.text = '',
    DateTime? created,
    this.doneAt,
    this.result = '',
  }) : created = created ?? DateTime.now();

  factory InboundTask.fromJson(Map<String, dynamic> json) => InboundTask(
        id: (json['id'] ?? '').toString(),
        number: (json['number'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        topic: (json['topic'] ?? '').toString(),
        action: InboundAction.values.firstWhere((a) => a.name == json['action'], orElse: () => InboundAction.tell),
        text: (json['text'] ?? '').toString(),
        created: DateTime.tryParse((json['created'] ?? '').toString()),
        doneAt: DateTime.tryParse((json['done_at'] ?? '').toString()),
        result: (json['result'] ?? '').toString(),
      );

  final String id;
  final String number;

  /// Who it is for (contact name), for display.
  final String name;

  /// Set for a standing task that applies to anyone calling about this topic
  /// (an intent name from the configuration) instead of one number.
  final String topic;
  final InboundAction action;

  /// The message to give, or the question to ask.
  final String text;
  final DateTime created;
  DateTime? doneAt;

  /// What happened: their answer, or whether the owner picked up.
  String result;

  bool get done => doneAt != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'name': name,
        if (topic.isNotEmpty) 'topic': topic,
        'action': action.name,
        'text': text,
        'created': created.toIso8601String(),
        if (doneAt != null) 'done_at': doneAt!.toIso8601String(),
        'result': result,
      };
}

/// All inbound tasks, newest first.
class TaskBook {
  TaskBook(this.inbound);
  factory TaskBook.empty() => TaskBook([]);
  factory TaskBook.fromJson(Map<String, dynamic> json) => TaskBook([
        for (final t in (json['inbound'] as List? ?? const []))
          if (t is Map) InboundTask.fromJson(t.cast<String, dynamic>()),
      ]);

  final List<InboundTask> inbound;

  Map<String, dynamic> toJson() => {'inbound': [for (final t in inbound) t.toJson()]};

  /// Open tasks for a caller, oldest first (so they are handled in order).
  List<InboundTask> pendingFor(String number) {
    if (normalizeNumber(number).isEmpty) return const [];
    return inbound.where((t) => !t.done && t.topic.isEmpty && sameNumber(t.number, number)).toList()
      ..sort((a, b) => a.created.compareTo(b.created));
  }

  /// Standing tasks for anyone calling about a topic.
  List<InboundTask> get topicTasks => inbound.where((t) => !t.done && t.topic.isNotEmpty).toList();

  void add(InboundTask task) => inbound.insert(0, task);
}
