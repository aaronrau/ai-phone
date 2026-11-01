import 'agent.dart';
import 'calendar.dart';
import 'decision.dart';
import 'tiered.dart';
import 'tools.dart';

/// Something the owner asked the assistant to do by calling someone.
class OutboundTask {
  OutboundTask({
    required this.id,
    required this.number,
    required this.objective,
    this.contactName = '',
    this.message = '',
    this.preferredDay = '',
    this.maxHoldMinutes = 10,
  });

  final String id;
  final String number;

  /// In the owner's words, phrased to follow "I'm calling to", e.g.
  /// "book a haircut on Friday afternoon".
  final String objective;
  final String contactName;

  /// Optional message to pass on or leave on voicemail.
  final String message;

  /// Optional day to start proposing times from ("Friday", "next week").
  final String preferredDay;
  final int maxHoldMinutes;

  String status = 'dialing';
  String outcome = '';
  DateTime? booked;

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'objective': objective,
        'contact': contactName,
        'message': message,
        'status': status,
        'outcome': outcome,
        if (booked != null) 'booked': booked!.toIso8601String(),
      };
}

/// Words that suggest which phone-menu option serves the objective.
const _menuHints = {
  'appoint': ['appointment', 'appointments', 'schedul', 'book', 'reservation'],
  'bill': ['billing', 'bill', 'payment', 'invoice', 'refund', 'account'],
  'person': ['representative', 'operator', 'agent', 'all other', 'someone', 'front desk', 'reception'],
};

const _spokenDigits = {
  'zero': '0', 'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5',
  'six': '6', 'seven': '7', 'eight': '8', 'nine': '9', 'pound': '#', 'star': '*',
};

/// Picks the keypad digit whose spoken menu option best matches [objective];
/// falls back to the operator/representative option. Null when no options were heard.
String? chooseMenuDigit(String menu, String objective) {
  final text = menu.toLowerCase();
  final options = <(String, String)>[]; // (description, digit)
  String? digitOf(String word) => RegExp(r'^\d$').hasMatch(word) ? word : _spokenDigits[word];
  for (final m in RegExp(r'(?:for|to)\s+([^.,;]+?)[,\s]+(?:press|oprima|dial|say)\s+(\w+)').allMatches(text)) {
    final digit = digitOf(m.group(2)!);
    if (digit != null) options.add((m.group(1)!, digit));
  }
  for (final m in RegExp(r'(?:press|dial)\s+(\w+)\s+(?:for|to)\s+([^.,;]+)').allMatches(text)) {
    final digit = digitOf(m.group(1)!);
    if (digit != null) options.add((m.group(2)!, digit));
  }
  if (options.isEmpty) return null;
  final goal = objective.toLowerCase();
  int score(String description) {
    var total = 0;
    for (final entry in _menuHints.entries) {
      final goalHit = entry.value.any(goal.contains) || (entry.key == 'person');
      if (goalHit && entry.value.any(description.contains)) total += entry.key == 'person' ? 1 : 3;
    }
    for (final word in goal.split(RegExp(r'\W+')).where((w) => w.length > 3)) {
      if (description.contains(word)) total += 2;
    }
    if (description.contains('english')) total += 1;
    return total;
  }

  options.sort((a, b) => score(b.$1).compareTo(score(a.$1)));
  return score(options.first.$1) > 0 ? options.first.$2 : null;
}

final _holdCue = RegExp(
    r"please (hold|stay on the line)|your call is (important|very important)|estimated wait|currently (assisting|helping)|"
    r"all of our (agents|representatives|staff)|next available|will be with you shortly|remain on the line|thank you for your patience",
    caseSensitive: false);
final _voicemailCue = RegExp(
    r"leave (a|your|me a) message|after the (tone|beep)|record your message|mailbox|(can't|cannot) (come|get) to the phone|"
    r"is not available|unavailable to take your call",
    caseSensitive: false);
final _greetingOnly = RegExp(r"^\W*(hello|hi|hey|yes|yeah|hello\?|speaking|this is \w+)\W*\??\W*$", caseSensitive: false);
final _confirmCue = RegExp(
    r"(got|have|put) (you|sam|him|her|them|\w+) down|you're all set|you are all set|(it's|you're|that's) booked|"
    r"\b(is|are|you're|it's|that's|all) (now )?(booked|scheduled|confirmed)\b|\bi(?:'ve| have)? booked\b|"
    r"\bbooked (you|your|it|that|him|her|them)\b|"
    r"see you then|confirmed|i'll (pass|let) (that|them|him|her)",
    caseSensitive: false);
final _wrongCue = RegExp(
    r"we don't do|we do not do|wrong (number|department|place)|next door|answering service|(can't|cannot) (book|help|schedule)|"
    r"not the right (person|place|department)",
    caseSensitive: false);

final _infoCue = RegExp(
    r"\b(can|could|may) i (have|get|grab|take)\b|\b(last|first|full) name\b|\bdate of birth\b|\b(phone|callback|contact) "
    r"number\b|\bspell\b|\bwhat(?:'s| is) (?:the|your|his|her|their|\w+'s) (?:name|number|email)\b|"
    r"\bname (for|on|under) the (booking|appointment|reservation)\b",
    caseSensitive: false);

/// Unmistakable phrases override the small model on outbound calls.
String outboundOverride(String step, String text, String label) {
  if (step == 'line') {
    if (_voicemailCue.hasMatch(text)) return 'voicemail';
    if (_holdCue.hasMatch(text)) return 'hold';
    if (_greetingOnly.hasMatch(text)) return 'person';
    return label;
  }
  // A question for a name or number is never a new time offer or a final yes.
  if (_infoCue.hasMatch(text) && text.contains('?') || _infoCue.hasMatch(text) && label == 'offer_time') return 'ask_info';
  if (_confirmCue.hasMatch(text)) return 'confirm';
  if (_wrongCue.hasMatch(text)) return 'wrong_person';
  return label;
}

/// Pursues an [OutboundTask] with the fine-tuned decision model: works out
/// what answered (person, voicemail, phone menu, hold), introduces itself,
/// coordinates a time against the owner's calendar, and books it.
class OutboundResponder implements TurnResponder {
  OutboundResponder({
    required this.router,
    required this.agent,
    required this.task,
    required this.ownerName,
    required this.assistantName,
    required this.onBooked,
  });

  final DecisionRouter router;
  final Agent agent;
  final OutboundTask task;
  final String ownerName;
  final String assistantName;
  final Future<void> Function(DateTime start, String title) onBooked;

  final List<ConversationLine> lines = [];
  String phase = 'line'; // line → outbound
  bool introduced = false;
  DateTime? holdingSince;
  DateTime? pendingTime;
  int unclear = 0;
  int menuPresses = 0;

  /// Offered times that did not fit the calendar, and transfer requests; each
  /// is capped so a call that cannot succeed ends politely.
  int rejectedOffers = 0;
  int transferAsks = 0;

  String get _callBack => "None of those times work for $ownerName right now. I'll have $ownerName call back to find "
      'a time. Thank you, goodbye.';

  @override
  bool get escalateToLargeModel => false;

  @override
  bool get waiting => holdingSince != null;

  ToolExecutor get _tools => agent.executor;

  String get _intro {
    final base = "Hi, this is $assistantName calling on behalf of $ownerName. I'm calling to ${task.objective}.";
    return task.message.isEmpty ? base : '$base ${task.message}';
  }

  String get _voicemail => "Hi, this is $assistantName calling on behalf of $ownerName. I'm calling to "
      '${task.objective}.${task.message.isEmpty ? '' : ' ${task.message}'} Please call $ownerName back at this number. '
      'Thank you.';

  FastTurn _say(String text, {String label = '', bool hangUp = false, String? dtmf}) {
    lines.add(ConversationLine(true, text, otherSpeaker: 'Other'));
    return FastTurn(text, label: label, hangUp: hangUp, ends: hangUp, dtmf: dtmf);
  }

  FastTurn _finish(String text, String outcome) {
    task
      ..status = 'done'
      ..outcome = outcome;
    return _say(text, label: outcome, hangUp: true);
  }

  @override
  void start({String? greeting}) {
    task.status = 'connected';
  }

  /// The other side confirmed just as the line dropped: book the agreed time.
  @override
  Future<void> lateWords(String said) async {
    lines.add(ConversationLine(false, said, otherSpeaker: 'Other'));
    final at = pendingTime;
    if (at == null || task.booked != null || !_confirmCue.hasMatch(said)) return;
    task.booked = at;
    await onBooked(at, task.objective);
    task
      ..status = 'done'
      ..outcome = 'booked ${_when(at)}';
  }

  /// Nobody spoke after the call connected: assume a quiet person and introduce.
  @override
  Future<FastTurn?> onSilence() async {
    if (introduced || phase != 'line' || holdingSince != null) return null;
    introduced = true;
    phase = 'outbound';
    task.status = 'talking';
    return _say(_intro, label: 'person');
  }

  @override
  Future<FastTurn?> handle(String said) async {
    lines.add(ConversationLine(false, said, otherSpeaker: 'Other'));
    router.conversation = lines;
    return phase == 'line' ? _line(said) : _talk(said);
  }

  Future<FastTurn?> _line(String said) async {
    final result = await router.route(contextSteps['line']!, said, extractSlots: false);
    final menuDigit = chooseMenuDigit(said, task.objective);
    final guess = outboundOverride('line', said, result.label);
    final label = menuDigit != null && guess != 'person' ? 'menu' : guess;
    switch (label) {
      case 'person':
        introduced = true;
        holdingSince = null;
        phase = 'outbound';
        task.status = 'talking';
        return _say(_intro, label: 'person');
      case 'voicemail':
        task.status = 'voicemail';
        return _finish(_voicemail, 'left voicemail');
      case 'menu':
        task.status = 'phone menu';
        if (++menuPresses > 4) return _finish('', 'stuck in phone menu');
        if (menuDigit != null) {
          lines.add(ConversationLine(true, '(pressed $menuDigit)', otherSpeaker: 'Other'));
          return FastTurn('', dtmf: menuDigit, label: 'menu');
        }
        return _say('Representative.', label: 'menu');
      case 'hold':
        task.status = 'on hold';
        holdingSince ??= DateTime.now();
        if (DateTime.now().difference(holdingSince!).inMinutes >= task.maxHoldMinutes) {
          return _finish('', 'gave up after ${task.maxHoldMinutes} minutes on hold');
        }
        return FastTurn('', label: 'hold');
      default:
        // Unclear: say nothing yet and keep listening.
        return FastTurn('', label: 'other');
    }
  }

  Future<FastTurn?> _talk(String said) async {
    final result = await router.route(contextSteps['outbound']!, said, extractFor: const {'offer_time'});
    // Outbound turns rarely have a "safe" default, so act on the model's best
    // guess unless it is genuinely unsure.
    final label = outboundOverride('outbound', said, result.probability < 0.45 ? 'other' : result.label);
    if (label != 'other') unclear = 0;
    // "Great." / "Okay." is an acknowledgement, not a booking: keep listening.
    if (label == 'confirm' && !_confirmCue.hasMatch(said) && said.trim().split(RegExp(r'\s+')).length <= 3) {
      return FastTurn('', label: 'ack');
    }
    switch (label) {
      case 'offer_time':
        final day = result.slots['day'] ?? '';
        final time = result.slots['time'] ?? '';
        // Try the extracted time, then every other time they listed.
        final dayText = day.isEmpty ? said : day;
        var (free, at) = await _tools.isFreeAt(dayText, time.isEmpty ? said : time);
        for (final other in spokenTimes(said)) {
          if (free) break;
          final (otherFree, otherAt) = await _tools.isFreeAt(dayText, other);
          if (otherFree) (free, at) = (true, otherAt);
        }
        if (at == null) {
          // No concrete time: keep the agreed one in play, or say when the owner is free.
          if (pendingTime != null) return _say(_details(), label: 'ask_info');
          return _say('${await _tools.upcomingAvailability(fromDay: task.preferredDay, days: 1)} Would any of those work?',
              label: 'ask_time');
        }
        if (free) {
          pendingTime = at;
          return _say('${_when(at)} works for $ownerName. Could you book that, please?', label: label);
        }
        if (++rejectedOffers >= 3) return _finish(_callBack, 'no matching time');
        final options = await _tools.upcomingAvailability(fromDay: day.isEmpty ? task.preferredDay : day, days: 1);
        return _say("That time doesn't work for $ownerName. $options Would any of those work?", label: label);
      case 'ask_time':
        return _say('${await _tools.upcomingAvailability(fromDay: task.preferredDay, days: 1)} Would any of those work?',
            label: label);
      case 'confirm':
        if (pendingTime != null) {
          task.booked = pendingTime;
          await onBooked(pendingTime!, task.objective);
          return _finish('Great, thank you so much. Goodbye.', 'booked ${_when(pendingTime!)}');
        }
        return _finish("Thank you, I'll let $ownerName know. Goodbye.", 'confirmed');
      case 'ask_info':
        return _say(_details(), label: label);
      case 'transfer':
        phase = 'line';
        holdingSince = DateTime.now();
        task.status = 'being transferred';
        return _say('Thank you, I can hold.', label: label);
      case 'wrong_person':
        if (++transferAsks > 2) return _finish(_callBack, 'no one could help');
        return _say('Could you transfer me to someone who can help me ${task.objective}?', label: label);
      case 'decline':
        return _finish("I understand. I'll let $ownerName know. Thank you, goodbye.", 'declined');
      case 'goodbye':
        return _finish('Thank you, goodbye.', pendingTime == null ? 'ended without a booking' : 'ended');
      default:
        if (++unclear > 2) return _finish("I'll have $ownerName follow up directly. Thank you, goodbye.", 'unclear');
        return _say('Sorry, could you say that again?', label: 'other');
    }
  }

  /// Name and number for the booking; restates the agreed time if there is one.
  String _details() {
    final base = "It's under the name $ownerName, and the best number to reach $ownerName is this one.";
    if (pendingTime != null) return '$base That\'s for ${_when(pendingTime!)}.';
    return "$base I'm calling to ${task.objective}.";
  }

  static const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  static String _when(DateTime t) {
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final minutes = t.minute == 0 ? '' : ':${t.minute.toString().padLeft(2, '0')}';
    return '${_weekdays[t.weekday - 1]} at $hour$minutes ${t.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// Adds a confirmed outbound booking to the receptionist's calendar.
CalendarItem bookingItem(DateTime start, String objective) => CalendarItem(
      id: 'booking-${start.millisecondsSinceEpoch}',
      title: objective,
      start: start,
      end: start.add(const Duration(hours: 1)),
      notes: 'Booked by the AI assistant',
    );
