import 'config.dart';
import 'contacts.dart';
import 'policy.dart';
import 'intents.dart';

/// A tool the model may call. [followUp] tools return information the model
/// must relay, so the agent generates again after running them.
class ToolSpec {
  const ToolSpec(this.name, this.description, this.args, {this.followUp = false});
  final String name;
  final String description;
  final Map<String, String> args;
  final bool followUp;
}

const builtInTools = <String, ToolSpec>{
  'take_message': ToolSpec(
    'take_message',
    'Save a message for {owner_name} as soon as the caller has said what to pass on. Put their words in '
        'message; do not ask them to repeat it.',
    {
      'caller_name': "the caller's name",
      'message': "the complete message in the caller's own words, including any other callback number they give",
    },
  ),
  'check_availability': ToolSpec(
    'check_availability',
    "Look up {owner_name}'s calendar for one day. Use before saying anything about when {owner_name} is free.",
    {
      'day': 'today, tomorrow, a weekday name like friday, or a date like 2026-11-03',
      'time': 'optional time like 15:00, or empty',
    },
    followUp: true,
  ),
  'record_caller': ToolSpec(
    'record_caller',
    'Record who an unknown caller is and why they are calling, once they have told you.',
    {'name': 'who they said they are', 'reason': 'why they are calling'},
  ),
  'notify_owner': ToolSpec(
    'notify_owner',
    'Immediately alert {owner_name} about something urgent.',
    {'summary': 'one sentence summary'},
  ),
  'remember': ToolSpec(
    'remember',
    'Save a useful fact about this caller for next time, such as their company, role or preferences.',
    {'fact': 'one short fact about the caller'},
  ),
  'mark_spam': ToolSpec(
    'mark_spam',
    'Block a sales, scam or robocall number for good. Also ends the call.',
    {'reason': 'why this is spam'},
  ),
  'end_conversation': ToolSpec(
    'end_conversation',
    'End the call or text conversation after saying goodbye.',
    {},
  ),
};

class CalendarEvent {
  CalendarEvent(this.start, this.end, this.title,
      {this.allDay = false, this.busy = true, this.shareDetails = false, this.notes = ''});
  final DateTime start;
  final DateTime end;
  final String title;
  final bool allDay;
  final bool busy;

  /// Only events the owner marked as shareable reveal their title/notes.
  final bool shareDetails;
  final String notes;

  String get detail => shareDetails && title.isNotEmpty ? '$title${notes.isEmpty ? '' : ', $notes'}' : '';
}

class TakenMessage {
  TakenMessage({
    required this.time,
    required this.number,
    required this.callerName,
    required this.message,
    required this.callbackNumber,
    required this.channel,
    required this.workflow,
  });

  final DateTime time;
  final String number;
  final String callerName;
  final String message;
  final String callbackNumber;
  final String channel;
  final String workflow;

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'number': number,
        'caller_name': callerName,
        'message': message,
        'callback_number': callbackNumber,
        'channel': channel,
        'workflow': workflow,
      };

  factory TakenMessage.fromJson(Map<String, dynamic> json) => TakenMessage(
        time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        number: (json['number'] ?? '').toString(),
        callerName: (json['caller_name'] ?? '').toString(),
        message: (json['message'] ?? '').toString(),
        callbackNumber: (json['callback_number'] ?? '').toString(),
        channel: (json['channel'] ?? '').toString(),
        workflow: (json['workflow'] ?? '').toString(),
      );
}

/// Side effects available to tools; the runtime implements these on Android
/// and tests supply fakes.
abstract class ToolHost {
  DateTime now();

  /// The owner's busy times: app calendar items plus, optionally, phone events.
  Future<List<CalendarEvent>> calendar(DateTime start, DateTime end);

  /// Weekly availability window for [day], or null when the owner is off.
  Future<(DateTime, DateTime)?> workingHours(DateTime day);
  Future<void> notifyOwner(String title, String body, {bool urgent = false});
  Future<void> saveMessage(TakenMessage message);
  Future<void> record(String kind, Map<String, dynamic> data);

  /// Applies [change] to the tracked contact for [number] and persists it.
  Future<void> updateContact(String number, void Function(TrackedContact contact) change);

  /// Adds [number] to Android's system block list (calls and texts).
  Future<void> blockNumber(String number, String reason);
}

class ToolOutcome {
  ToolOutcome(this.result, {this.endConversation = false});
  final String result;
  final bool endConversation;
}

/// Resolves the tools enabled for a workflow, including custom tools.
List<ToolSpec> toolsFor(ReceptionistConfig config, WorkflowConfig workflow) {
  final custom = {for (final t in config.customTools) t.name: t};
  final specs = <ToolSpec>[];
  for (final name in workflow.tools) {
    final builtIn = builtInTools[name];
    if (builtIn != null) {
      specs.add(builtIn);
    } else if (custom[name] != null) {
      final tool = custom[name]!;
      specs.add(ToolSpec(tool.name, tool.description, tool.args, followUp: tool.action == 'reply'));
    }
  }
  return specs;
}

class ToolExecutor {
  ToolExecutor({
    required this.config,
    required this.disposition,
    required this.channel,
    required this.host,
  });

  final ReceptionistConfig config;
  final Disposition disposition;
  final String channel;
  final ToolHost host;

  /// Name the caller gave via record_caller, used by later tools.
  String? identifiedName;
  String? identifiedReason;
  String? lastMessage;

  /// Topic detected in what the caller said, and its notification label.
  String? topic;
  String? topicLabel;

  String get _callerLabel => identifiedName ?? disposition.name ?? disposition.number;

  Future<ToolOutcome> run(String name, Map<String, String> args) async {
    switch (name) {
      case 'take_message':
        final callerName = (args['caller_name'] ?? '').trim().isNotEmpty
            ? args['caller_name']!.trim()
            : _callerLabel;
        final message = (args['message'] ?? '').trim();
        if (message.isEmpty) return ToolOutcome('No message text was given; ask what the message is.');
        final callback = (args['callback_number'] ?? '').trim();
        lastMessage = message;
        await host.saveMessage(TakenMessage(
          time: host.now(),
          number: disposition.number,
          callerName: callerName,
          message: message,
          callbackNumber: callback.isEmpty ? disposition.number : callback,
          channel: channel,
          workflow: disposition.workflow.name,
        ));
        // The intent label comes first, then the message.
        await host.notifyOwner('Message from $callerName', labelled(topicLabel, message));
        // Leaving a message makes the caller a contact: named, with what they
        // said, and "screened" (identified, not yet approved) until reviewed.
        await host.updateContact(disposition.number, (c) {
          if (c.name.isEmpty && callerName != disposition.number) c.name = callerName;
          if (disposition.workflow == Workflow.known) {
            if (c.status != ContactStatus.blocked) c.status = ContactStatus.known;
          } else if (c.status == ContactStatus.unknown) {
            c.status = ContactStatus.screened;
          }
          if (identifiedReason != null) c.addFact('Called about: $identifiedReason');
          c.addEvent(channel, 'left a message: $message', host.now());
        });
        return ToolOutcome('Message saved and ${config.ownerName} has been notified.');
      case 'check_availability':
        _spokenTimes = channel == 'call' || channel == 'speakerTest';
        try {
          return ToolOutcome(await _availability(args['day'] ?? 'today', args['time'] ?? ''));
        } finally {
          _spokenTimes = false;
        }
      case 'record_caller':
        final who = (args['name'] ?? '').trim();
        final reason = (args['reason'] ?? '').trim();
        if (who.isNotEmpty) identifiedName = who;
        if (reason.isNotEmpty) identifiedReason = reason;
        await host.record('caller_identified', {
          'number': disposition.number,
          'name': who,
          'reason': reason,
          'channel': channel,
        });
        await host.updateContact(disposition.number, (c) {
          if (who.isNotEmpty) c.name = who;
          if (c.status == ContactStatus.unknown) c.status = ContactStatus.screened;
          if (reason.isNotEmpty) c.addEvent(channel, 'identified; reason: $reason', host.now());
        });
        return ToolOutcome('Recorded. Offer to take a message for ${config.ownerName}.');
      case 'notify_owner':
        final summary = (args['summary'] ?? '').trim();
        await host.notifyOwner('Urgent: $_callerLabel', summary, urgent: true);
        return ToolOutcome('${config.ownerName} has been alerted.');
      case 'remember':
        final fact = (args['fact'] ?? '').trim();
        if (fact.isNotEmpty) await host.updateContact(disposition.number, (c) => c.addFact(fact));
        return ToolOutcome('Saved.');
      case 'mark_spam':
        final reason = (args['reason'] ?? '').trim();
        await host.updateContact(disposition.number, (c) {
          c.status = ContactStatus.blocked;
          c.blockReason = reason.isEmpty ? 'spam' : 'spam: $reason';
          c.addEvent(channel, 'marked as spam${reason.isEmpty ? '' : ': $reason'}', host.now());
        });
        await host.blockNumber(disposition.number, reason.isEmpty ? 'spam' : reason);
        return ToolOutcome('Number blocked.', endConversation: true);
      case 'end_conversation':
        return ToolOutcome('Conversation ended.', endConversation: true);
    }
    final custom = config.customTools.where((t) => t.name == name).firstOrNull;
    if (custom == null) return ToolOutcome('Unknown tool $name.');
    final text = custom.template.replaceAllMapped(RegExp(r'\{([a-z_]+)\}'), (m) {
      final key = m.group(1)!;
      if (key == 'caller') return _callerLabel;
      if (key == 'number') return disposition.number;
      if (key == 'owner_name') return config.ownerName;
      return args[key] ?? '';
    });
    switch (custom.action) {
      case 'notify':
        await host.notifyOwner('${custom.name} · $_callerLabel', text);
        return ToolOutcome('Done; ${config.ownerName} has been notified.');
      case 'reply':
        return ToolOutcome(text);
      default:
        await host.record(custom.name, {'number': disposition.number, 'text': text, 'channel': channel});
        return ToolOutcome('Recorded.');
    }
  }

  Future<String> _availability(String dayText, String timeText) async {
    final now = host.now();
    final day = parseDay(dayText, now);
    if (day == null) return 'Could not understand the day "$dayText". Ask the caller which day they mean.';
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day + 1);
    final events = (await host.calendar(start, end)).where((e) => e.busy).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final hours = await host.workingHours(start);
    final label = describeDay(start, now);
    final buffer = StringBuffer('Calendar for $label: ');
    if (hours == null) {
      buffer.write('${config.ownerName} is not available on this day. ');
    } else {
      buffer.write('available ${_hm(hours.$1)} to ${_hm(hours.$2)}. ');
    }
    final timed = events.where((e) => !e.allDay).toList();
    final allDay = events.where((e) => e.allDay).toList();
    if (allDay.isNotEmpty) {
      final shared = allDay.where((e) => e.detail.isNotEmpty).map((e) => e.detail).toList();
      buffer.write(shared.isEmpty ? 'Busy all day. ' : 'Busy all day: ${shared.join('; ')}. ');
    }
    if (timed.isEmpty) {
      buffer.write('No meetings. ');
    } else {
      buffer.write('Busy: ');
      buffer.write(timed.map((e) {
        final span = '${_hm(_clip(e.start, start))} to ${_hm(_clip(e.end, start))}';
        return e.detail.isNotEmpty ? '$span (${e.detail})' : span;
      }).join(', '));
      buffer.write('. ');
    }
    if (hours != null && allDay.isEmpty) {
      final free = freeWindows(start, hours, timed);
      buffer.write(free.isEmpty
          ? 'No free time that day.'
          : 'Free: ${free.map((w) => '${_hm(w.$1)} to ${_hm(w.$2)}').join(', ')}.');
      final asked = parseTime(timeText, start);
      if (asked != null) {
        final fits = free.any((w) => !asked.isBefore(w.$1) && asked.isBefore(w.$2));
        buffer.write(' At ${_hm(asked)}: ${fits ? 'free' : 'not free'}.');
      }
    }
    if (events.any((e) => e.detail.isEmpty)) {
      buffer.write(' Busy times without details are private: only say ${config.ownerName} is busy then.');
    }
    return buffer.toString().trim();
  }

  /// A short spoken answer about [dayText] (and optional [timeText]) built
  /// directly from the calendar, for the small-model path. Private items are
  /// only ever "busy". Returns null when the day cannot be understood.
  Future<String?> spokenAvailability(String dayText, String timeText) async {
    final now = host.now();
    final day = parseDay(dayText.isEmpty ? 'today' : dayText, now);
    if (day == null) return null;
    // Spelled-out times are for speech; texts get "1:30 PM".
    _spokenTimes = channel == 'call' || channel == 'speakerTest';
    try {
      final start = DateTime(day.year, day.month, day.day);
      final end = DateTime(day.year, day.month, day.day + 1);
      final events = (await host.calendar(start, end)).where((e) => e.busy).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      final hours = await host.workingHours(start);
      final owner = config.ownerName;
      final when = _spokenDay(start, now);
      if (hours == null || events.any((e) => e.allDay)) return "$owner isn't available $when.";
      final timed = events.where((e) => !e.allDay).toList();
      var free = freeWindows(start, hours, timed);
      final asked = parseTime(timeText, start);
      if (asked != null) {
        final fits = free.any((w) => !asked.isBefore(w.$1) && asked.isBefore(w.$2));
        if (fits) return '$owner looks free at ${_hm(asked)} $when.';
        if (free.isEmpty) return "$owner is busy then, and there's no free time $when.";
        return '$owner is busy at ${_hm(asked)} $when, but is free ${_windows(free)}.';
      }
      final period = dayPeriod('$dayText $timeText');
      if (period != null) {
        free = [
          for (final w in free)
            if (w.$2.hour > period.$1 && w.$1.hour < period.$2)
              (w.$1.hour < period.$1 ? DateTime(day.year, day.month, day.day, period.$1) : w.$1,
               w.$2.hour >= period.$2 ? DateTime(day.year, day.month, day.day, period.$2) : w.$2),
        ];
      }
      final part = period == null ? '' : ' in the ${period.$3}';
      if (free.isEmpty) return "$owner doesn't have free time $when$part.";
      return '$owner is free $when$part ${_windows(free)}.';
    } finally {
      _spokenTimes = false;
    }
  }

  /// Whether the owner is free at [dayText]/[timeText] for [minutes], plus
  /// the requested start time when it could be understood.
  Future<(bool, DateTime?)> isFreeAt(String dayText, String timeText, {int minutes = 60}) async {
    final day = parseDay(dayText.isEmpty ? 'today' : dayText, host.now());
    if (day == null) return (false, null);
    final at = parseTime(timeText, DateTime(day.year, day.month, day.day));
    if (at == null) return (false, null);
    final start = DateTime(day.year, day.month, day.day);
    final hours = await host.workingHours(start);
    if (hours == null) return (false, at);
    final events = (await host.calendar(start, DateTime(day.year, day.month, day.day + 1)))
        .where((e) => e.busy && !e.allDay)
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (events.any((e) => e.allDay)) return (false, at);
    final end = at.add(Duration(minutes: minutes));
    final free = freeWindows(start, hours, events).any((w) => !at.isBefore(w.$1) && !end.isAfter(w.$2));
    return (free, at);
  }

  /// "Sam is free Thursday from ... and Friday from ..." over the next few
  /// working days (starting at [fromDay] when given).
  Future<String> upcomingAvailability({String fromDay = '', int days = 2}) async {
    final now = host.now();
    var day = parseDay(fromDay, now) ?? DateTime(now.year, now.month, now.day + 1);
    final parts = <String>[];
    _spokenTimes = true;
    try {
      for (var i = 0; i < 10 && parts.length < days; i++, day = DateTime(day.year, day.month, day.day + 1)) {
        final hours = await host.workingHours(day);
        if (hours == null) continue;
        final events = (await host.calendar(day, DateTime(day.year, day.month, day.day + 1)))
            .where((e) => e.busy)
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
        if (events.any((e) => e.allDay)) continue;
        final free = freeWindows(day, hours, events.where((e) => !e.allDay).toList());
        if (free.isEmpty) continue;
        parts.add('${_spokenDay(day, now)} ${_windows(free.take(2).toList())}');
      }
    } finally {
      _spokenTimes = false;
    }
    if (parts.isEmpty) return "${config.ownerName} doesn't have open time in the next few days.";
    return '${config.ownerName} is free ${parts.join(', and ')}.';
  }

  static String _windows(List<(DateTime, DateTime)> free) {
    final spans = free.take(3).map((w) => 'from ${_hm(w.$1)} to ${_hm(w.$2)}').toList();
    return spans.length == 1 ? spans.first : '${spans.sublist(0, spans.length - 1).join(', ')} and ${spans.last}';
  }

  static String _spokenDay(DateTime day, DateTime now) {
    final described = describeDay(day, now);
    if (described.startsWith('today')) return 'today';
    if (described.startsWith('tomorrow')) return 'tomorrow';
    return 'on ${described.split(' ').take(3).join(' ')}';
  }

  static DateTime _clip(DateTime value, DateTime day) {
    if (value.isBefore(day)) return day;
    final next = DateTime(day.year, day.month, day.day + 1);
    return value.isAfter(next) ? next.subtract(const Duration(minutes: 1)) : value;
  }
}

/// Whether tool results should be phrased for speech (set per call).
bool _spokenTimes = false;

const _numberWords = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve',
];

String _hm(DateTime t) {
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final suffix = t.hour < 12 ? 'AM' : 'PM';
  if (_spokenTimes) {
    final minute = switch (t.minute) {
      0 => '',
      15 => ' fifteen',
      30 => ' thirty',
      45 => ' forty-five',
      _ => ' ${t.minute.toString().padLeft(2, '0')}',
    };
    return '${_numberWords[hour]}$minute $suffix';
  }
  final minutes = t.minute == 0 ? '' : ':${t.minute.toString().padLeft(2, '0')}';
  return '$hour$minutes $suffix';
}

const _weekdays = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
const _months = [
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december',
];

DateTime? parseDay(String text, DateTime now) {
  final value = text.trim().toLowerCase();
  final today = DateTime(now.year, now.month, now.day);
  if (value.contains('tomorrow')) return DateTime(today.year, today.month, today.day + 1);
  if (value.isEmpty || value.contains('today') || value.contains('tonight') || value == 'now' ||
      RegExp(r'^this (morning|afternoon|evening)$').hasMatch(value)) {
    return today;
  }
  final iso = DateTime.tryParse(value);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  for (var i = 0; i < 7; i++) {
    final name = _weekdays[i];
    if (value.contains(name) || value.contains(name.substring(0, 3))) {
      var delta = (i + 1 - today.weekday) % 7;
      if (delta == 0 || value.contains('next')) delta = delta == 0 ? 7 : delta;
      return DateTime(today.year, today.month, today.day + delta);
    }
  }
  final monthDay = RegExp(r'([a-z]+)\s+(\d{1,2})').firstMatch(value);
  if (monthDay != null) {
    final month = _months.indexWhere((m) => m.startsWith(monthDay.group(1)!.substring(0, 3)));
    if (month >= 0) {
      var date = DateTime(today.year, month + 1, int.parse(monthDay.group(2)!));
      if (date.isBefore(today)) date = DateTime(today.year + 1, month + 1, date.day);
      return date;
    }
  }
  return null;
}

// "2:30 pm", and speech-to-text's "2 30 pm" (a space only counts before am/pm).
final _timePattern =
    RegExp(r'(\d{1,2})(?::(\d{2})|\s(\d{2})(?=\s*(?:am|pm|a\.m\.|p\.m\.)))?\s*(am|pm|a\.m\.|p\.m\.)?');
final _spokenTime = RegExp(r'\b\d{1,2}(?:[: ]\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)|\bnoon\b', caseSensitive: false);

/// Every clock time with am/pm (or "noon") in [text], in order, e.g. for
/// "Friday at 2 30 PM, 4 PM, or 11 AM".
List<String> spokenTimes(String text) =>
    [for (final m in _spokenTime.allMatches(text)) m.group(0)!.toLowerCase() == 'noon' ? '12 pm' : m.group(0)!];

DateTime? parseTime(String text, DateTime day) {
  final match = _timePattern.firstMatch(text.toLowerCase());
  if (match == null) return null;
  var hour = int.parse(match.group(1)!);
  final minute = int.tryParse(match.group(2) ?? match.group(3) ?? '') ?? 0;
  final suffix = match.group(4) ?? '';
  if (suffix.startsWith('p') && hour < 12) hour += 12;
  if (suffix.startsWith('a') && hour == 12) hour = 0;
  if (suffix.isEmpty && hour >= 1 && hour <= 7) hour += 12; // "at 3" means afternoon
  if (hour > 23 || minute > 59) return null;
  return DateTime(day.year, day.month, day.day, hour, minute);
}

/// Morning / afternoon / evening mentioned in [text], as (startHour, endHour, name).
(int, int, String)? dayPeriod(String text) {
  final value = text.toLowerCase();
  if (value.contains('morning')) return (0, 12, 'morning');
  if (value.contains('afternoon') || value.contains('lunch')) return (12, 17, 'afternoon');
  if (value.contains('evening') || value.contains('tonight') || value.contains('dinner')) return (17, 24, 'evening');
  return null;
}

String describeDay(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  // Calendar-day difference; Duration-based arithmetic breaks across DST.
  final diff = DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  final name = '${_weekdays[day.weekday - 1][0].toUpperCase()}${_weekdays[day.weekday - 1].substring(1)}';
  final month = '${_months[day.month - 1][0].toUpperCase()}${_months[day.month - 1].substring(1)}';
  final prefix = diff == 0 ? 'today, ' : diff == 1 ? 'tomorrow, ' : '';
  return '$prefix$name $month ${day.day}';
}

List<(DateTime, DateTime)> freeWindows(DateTime day, (DateTime, DateTime) hours, List<CalendarEvent> busy) {
  final windows = <(DateTime, DateTime)>[];
  var cursor = hours.$1;
  for (final event in busy) {
    if (!event.end.isAfter(cursor)) continue;
    if (!event.start.isBefore(hours.$2)) break;
    if (event.start.isAfter(cursor)) windows.add((cursor, event.start.isBefore(hours.$2) ? event.start : hours.$2));
    if (event.end.isAfter(cursor)) cursor = event.end;
  }
  if (cursor.isBefore(hours.$2)) windows.add((cursor, hours.$2));
  return windows.where((w) => w.$2.difference(w.$1).inMinutes >= 15).toList();
}
