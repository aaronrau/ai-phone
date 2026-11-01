import 'contacts.dart';
import 'store.dart';
import 'tools.dart';

/// How the home screen files a call or text.
enum CallCategory {
  important('Important'),
  other('Not important'),
  spam('Spam'),
  blocked('Blocked');

  const CallCategory(this.label);
  final String label;
}

/// One call, text or call-out as the owner sees it on the home screen.
class CallSummary {
  CallSummary({
    required this.time,
    required this.number,
    required this.who,
    required this.kind,
    required this.category,
    required this.detail,
    this.topic = '',
    this.outgoing = false,
    this.lines = const [],
  });

  final DateTime time;
  final String number;
  final String who;

  /// 'call', 'text' or 'callout'.
  final String kind;

  /// Placed or sent from this phone (by the owner or the assistant).
  final bool outgoing;

  /// What the call was about, as detected on the phone (e.g. "Plans").
  final String topic;
  final CallCategory category;
  final String detail;

  /// Conversation lines as stored ({speaker, text}), oldest first.
  final List<Map<String, dynamic>> lines;
}

final _urgent = RegExp(
    r'\b(urgent|emergency|asap|as soon as possible|right away|hospital|accident|police|important|today|tonight|'
    r'call (me )?back|deadline|appointment|interview)\b',
    caseSensitive: false);

/// Files the activity log (newest first) into calls and texts with a category.
///
/// Important: known contacts, anyone who left a message or gave a reason,
/// urgent wording, and the results of call-outs. Not important: unknown
/// callers who said nothing useful and ignored texts. Spam: calls the
/// assistant hung up on as spam. Blocked: calls and texts rejected before
/// ringing.
List<CallSummary> summarizeActivity(
  List<ActivityEntry> activity,
  ContactBook contacts, {
  List<TakenMessage> messages = const [],
}) {
  String whoFor(String number, [String? name]) {
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return contacts.find(number)?.label ?? (number.isEmpty ? 'Unknown number' : number);
  }

  // Older call records have no message field; match saved messages by time.
  String? messageNear(String number, DateTime time) {
    for (final m in messages) {
      if (m.number == number && m.channel == 'call' && m.time.difference(time).inMinutes.abs() <= 10) return m.message;
    }
    return null;
  }

  bool spamBlockedNear(String number, DateTime time) => activity.any((e) =>
      e.kind == 'number_blocked' &&
      e.data['number'] == number &&
      e.time.difference(time).inMinutes.abs() <= 3);

  final result = <CallSummary>[];
  for (final entry in activity) {
    final data = entry.data;
    final number = (data['number'] ?? '').toString();
    switch (entry.kind) {
      case 'call_transcript':
        final lines = [for (final l in (data['lines'] as List? ?? const [])) if (l is Map) l.cast<String, dynamic>()];
        final said = lines.where((l) => l['speaker'] == 'caller').map((l) => (l['text'] ?? '').toString()).toList();
        final message = (data['message'] as String?) ?? messageNear(number, entry.time);
        final reason = (data['reason'] ?? '').toString();
        final spam = data['spam'] == true || spamBlockedNear(number, entry.time);
        final known = data['workflow'] == 'known';
        final detail = message ?? (reason.isNotEmpty ? reason : (said.isEmpty ? 'No one spoke' : said.join(' ')));
        final category = spam
            ? CallCategory.spam
            : (known || message != null || reason.isNotEmpty || _urgent.hasMatch(said.join(' ')))
                ? CallCategory.important
                : CallCategory.other;
        result.add(CallSummary(
          time: entry.time,
          number: number,
          who: whoFor(number, data['name'] as String?),
          kind: 'call',
          category: category,
          detail: detail,
          topic: (data['topic'] ?? '').toString(),
          lines: lines,
        ));
      case 'call_blocked':
        result.add(CallSummary(
            time: entry.time,
            number: number,
            who: whoFor(number),
            kind: 'call',
            category: CallCategory.blocked,
            detail: (data['reason'] ?? 'Blocked').toString()));
      case 'call_screened' when data['workflow'] == 'block':
        result.add(CallSummary(
            time: entry.time,
            number: number,
            who: whoFor(number),
            kind: 'call',
            category: CallCategory.blocked,
            detail: (data['reason'] ?? 'Blocked').toString()));
      case 'sms_in':
        final body = (data['body'] ?? '').toString();
        final workflow = data['workflow'];
        result.add(CallSummary(
          time: entry.time,
          number: number,
          who: whoFor(number),
          kind: 'text',
          category: workflow == 'block'
              ? CallCategory.blocked
              : workflow == 'known' || _urgent.hasMatch(body)
                  ? CallCategory.important
                  : CallCategory.other,
          detail: body,
        ));
      // Records from before calls logged their direction are covered elsewhere.
      case 'call_ended' when data['assistant'] != true && data['ai'] != true && data.containsKey('incoming'):
        // The owner's own calls: answered, missed or placed.
        final incoming = data['incoming'] == true;
        final answered = data['answered'] == true;
        final seconds = (data['seconds'] as num?)?.toInt() ?? 0;
        final known = contacts.find(number)?.status == ContactStatus.known;
        result.add(CallSummary(
          time: entry.time,
          number: number,
          who: whoFor(number),
          kind: 'call',
          outgoing: !incoming,
          category: !incoming || known ? CallCategory.important : CallCategory.other,
          detail: incoming
              ? (answered ? 'Incoming call · ${_duration(seconds)}' : 'Missed call')
              : (answered ? 'Outgoing call · ${_duration(seconds)}' : 'Outgoing call · no answer'),
        ));
      case 'sms_out' || 'sms_sent':
        result.add(CallSummary(
          time: entry.time,
          number: number,
          who: whoFor(number),
          kind: 'text',
          outgoing: true,
          category: CallCategory.important,
          detail: '${entry.kind == 'sms_out' ? 'Assistant replied: ' : ''}${(data['body'] ?? '').toString()}',
        ));
      case 'callout':
        final objective = (data['objective'] ?? '').toString();
        final outcome = (data['outcome'] ?? '').toString();
        final contact = (data['contact'] ?? '').toString();
        result.add(CallSummary(
          time: entry.time,
          number: number,
          who: whoFor(number, contact),
          kind: 'callout',
          outgoing: true,
          category: CallCategory.important,
          detail: outcome.isEmpty ? 'Called to $objective' : 'Called to $objective: $outcome',
          lines: [for (final l in (data['lines'] as List? ?? const [])) if (l is Map) l.cast<String, dynamic>()],
        ));
    }
  }
  return result;
}

String _duration(int seconds) => seconds < 60 ? '$seconds s' : '${(seconds / 60).round()} min';
