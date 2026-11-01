import 'dart:convert';
import 'dart:io';

import 'agent.dart';
import 'calendar.dart';
import 'contacts.dart';
import 'tiered.dart';
import 'config.dart';
import 'tools.dart';
import 'tasks.dart';

/// One entry in the activity log shown in the app.
class ActivityEntry {
  ActivityEntry(this.time, this.kind, this.data);
  final DateTime time;
  final String kind;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {'time': time.toIso8601String(), 'kind': kind, 'data': data};
  factory ActivityEntry.fromJson(Map<String, dynamic> json) => ActivityEntry(
        DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        (json['kind'] ?? '').toString(),
        ((json['data'] as Map?) ?? const {}).cast<String, dynamic>(),
      );
}

/// SMS conversation state for one number.
class SmsThread {
  SmsThread(this.number, this.turns, this.replies, {this.closedAt, this.step, this.awaitingMessage = false});
  final String number;
  final List<ChatTurn> turns;

  /// Small-model workflow position for this thread.
  String? step;
  bool awaitingMessage;

  /// Times of replies sent, for rate limiting.
  final List<DateTime> replies;
  DateTime? closedAt;

  Map<String, dynamic> toJson() => {
        'number': number,
        'turns': [for (final t in turns) t.toJson()],
        'replies': [for (final r in replies) r.toIso8601String()],
        if (closedAt != null) 'closed_at': closedAt!.toIso8601String(),
        if (step != null) 'step': step,
        if (awaitingMessage) 'awaiting_message': true,
      };

  factory SmsThread.fromJson(Map<String, dynamic> json) => SmsThread(
        json['number'].toString(),
        [for (final t in (json['turns'] as List? ?? const [])) ChatTurn.fromJson((t as Map).cast<String, dynamic>())],
        [for (final r in (json['replies'] as List? ?? const [])) DateTime.parse(r.toString())],
        closedAt: DateTime.tryParse(json['closed_at']?.toString() ?? ''),
        step: json['step']?.toString(),
        awaitingMessage: json['awaiting_message'] == true,
      );
}

/// App-private persistence: configuration, taken messages, activity and SMS
/// threads. Nothing leaves the phone.
class Store {
  Store(this.directory);
  final Directory directory;

  File get _config => File('${directory.path}/receptionist.json');
  File get _messages => File('${directory.path}/messages.jsonl');
  File get _activity => File('${directory.path}/activity.jsonl');
  File get _threads => File('${directory.path}/sms_threads.json');
  File get _calendar => File('${directory.path}/calendar.json');
  File get _contacts => File('${directory.path}/contacts.json');
  File get _phrases => File('${directory.path}/workflow_phrases.json');
  File get _tasks => File('${directory.path}/tasks.json');

  Future<TaskBook> loadTasks() async {
    if (!await _tasks.exists()) return TaskBook.empty();
    try {
      return TaskBook.fromJson((jsonDecode(await _tasks.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      return TaskBook.empty();
    }
  }

  Future<void> saveTasks(TaskBook book) => _atomicWrite(_tasks, jsonEncode(book.toJson()));

  Future<WorkflowPhrases> loadPhrases() async {
    if (!await _phrases.exists()) return WorkflowPhrases.defaults;
    try {
      return WorkflowPhrases.fromJson((jsonDecode(await _phrases.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      return WorkflowPhrases.defaults;
    }
  }

  Future<void> savePhrases(WorkflowPhrases phrases) => _atomicWrite(_phrases, jsonEncode(phrases.values));

  Future<ContactBook> loadContacts() async {
    if (!await _contacts.exists()) return ContactBook.empty();
    try {
      return ContactBook.fromJson((jsonDecode(await _contacts.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      return ContactBook.empty();
    }
  }

  Future<void> saveContacts(ContactBook book) => _atomicWrite(_contacts, book.encode());

  Future<CalendarData> loadCalendar() async {
    if (!await _calendar.exists()) return CalendarData.defaults();
    try {
      return CalendarData.fromJson((jsonDecode(await _calendar.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      return CalendarData.defaults();
    }
  }

  Future<void> saveCalendar(CalendarData data) => _atomicWrite(_calendar, data.encode());

  Future<void> _atomicWrite(File file, String text) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
  }

  Future<String?> readConfigText() async => await _config.exists() ? _config.readAsString() : null;

  Future<ReceptionistConfig> loadConfig() async {
    final text = await readConfigText();
    if (text == null) return ReceptionistConfig.defaults();
    try {
      return ReceptionistConfig.fromJson((jsonDecode(text) as Map).cast<String, dynamic>());
    } catch (_) {
      return ReceptionistConfig.defaults();
    }
  }

  Future<void> saveConfigText(String text) => _atomicWrite(_config, text);

  Future<void> _appendQueue = Future.value();

  /// Appends one JSON line. Appends run one at a time so concurrent events
  /// (for example rapid probe results) can never interleave inside a line.
  Future<void> _appendLine(File file, Object json) {
    final Future<void> next = _appendQueue
        .then((_) => file.writeAsString('${jsonEncode(json)}\n', mode: FileMode.append, flush: true));
    _appendQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Decodes JSON lines, skipping any damaged line instead of losing the file.
  static List<Map<String, dynamic>> decodeLines(Iterable<String> lines) => [
        for (final line in lines)
          if (line.trim().isNotEmpty)
            if (_tryDecode(line) case final Map<String, dynamic> map) map,
      ];

  static Map<String, dynamic>? _tryDecode(String line) {
    try {
      final value = jsonDecode(line);
      return value is Map ? value.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> addMessage(TakenMessage message) => _appendLine(_messages, message.toJson());

  Future<List<TakenMessage>> messages() async {
    if (!await _messages.exists()) return [];
    return [for (final json in decodeLines(await _messages.readAsLines())) TakenMessage.fromJson(json)].reversed.toList();
  }

  Future<void> clearMessages() async {
    if (await _messages.exists()) await _messages.delete();
  }

  Future<void> addActivity(String kind, Map<String, dynamic> data) =>
      _appendLine(_activity, ActivityEntry(DateTime.now(), kind, data).toJson());

  Future<List<ActivityEntry>> activity({int limit = 200}) async {
    if (!await _activity.exists()) return [];
    final lines = await _activity.readAsLines();
    final start = lines.length > limit ? lines.length - limit : 0;
    return [for (final json in decodeLines(lines.sublist(start))) ActivityEntry.fromJson(json)].reversed.toList();
  }

  Future<Map<String, SmsThread>> threads() async {
    if (!await _threads.exists()) return {};
    try {
      final decoded = (jsonDecode(await _threads.readAsString()) as Map).cast<String, dynamic>();
      return {
        for (final e in decoded.entries) e.key: SmsThread.fromJson((e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> saveThreads(Map<String, SmsThread> threads) =>
      _atomicWrite(_threads, jsonEncode({for (final e in threads.entries) e.key: e.value.toJson()}));
}
