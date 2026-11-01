import 'agent.dart';
import 'decision.dart';
import 'policy.dart';
import 'tools.dart';
import 'intents.dart';

/// Fixed lines for the prebuilt workflows. Gemma can restyle them once
/// ([authorPhrasesPrompt]); a rewrite that fails [acceptablePhrase] keeps the
/// default.
class WorkflowPhrases {
  const WorkflowPhrases(this.values);
  final Map<String, String> values;

  static const defaults = WorkflowPhrases({
    'identified': "Thanks, {caller}. {owner} isn't available right now. Would you like to leave a message?",
    'ask_message': 'Of course. What would you like me to tell {owner}?',
    'message_taken': "Got it, I'll pass that on to {owner}. Is there anything else I can help you with?",
    'spam': "Thanks, but we're not interested. Goodbye.",
    'goodbye': 'Thanks for calling. Goodbye.',
    'fallback_message': 'I can take a message for {owner}. What would you like me to pass on?',
    'availability_followup': 'Would you like to leave a message for {owner}?',
    'ask_day': 'Which day did you have in mind?',
    'give_up': "I've noted that for {owner}. Is there anything else you'd like me to pass on?",
    'clarify_who': "{owner} isn't available right now. May I ask who's calling and what it's regarding?",
    'clarify_more': 'Could you tell me a bit more about what you need from {owner}?',
    'transfer_context': "I'll see if {owner} can pick up. What's it about?",
    'transfer_context_again': 'So I can let {owner} know, what is the call regarding?',
    'transfer_hold': 'One moment, let me see if {owner} can pick up.',
    'transfer_connected': "Here's {owner} now.",
    'transfer_declined': "{owner} can't come to the phone right now. Would you like to leave a message?",
  });

  String render(String key, Map<String, String> values) => fillTemplate(this.values[key] ?? defaults.values[key] ?? '', values)
      .replaceAll(RegExp(r',\s*\.'), '.')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Accepts authored lines that pass [acceptablePhrase]; others keep the default.
  static WorkflowPhrases fromJson(Map<String, dynamic> json) => WorkflowPhrases({
        ...defaults.values,
        for (final e in json.entries)
          if (defaults.values.containsKey(e.key) && e.value is String && acceptablePhrase(e.key, (e.value as String).trim()))
            e.key: (e.value as String).trim(),
      });
}

/// GBNF for a flat JSON object with exactly [keys] and non-empty string values.
String phraseGrammar(List<String> keys) {
  final parts = <String>[];
  for (var i = 0; i < keys.length; i++) {
    final separator = i == 0 ? '' : ', ';
    parts.add('"$separator\\"${keys[i]}\\": " str');
  }
  return [
    'root ::= "{" ${parts.join(' ')} "}"',
    r'str ::= "\"" chr{1,200} "\""',
    r'chr ::= [^"\\\x00-\x1F]',
  ].join('\n');
}

/// Prompt asking the large model to restyle the default workflow lines once.
String authorPhrasesPrompt(String ownerName, String assistantName, String style) {
  final current = WorkflowPhrases.defaults.values.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  return 'You are $assistantName, a phone receptionist for $ownerName. Rewrite each line below so it sounds '
      '$style. Keep the meaning of each line, keep it to one or two short spoken sentences, and keep the '
      'placeholders {caller} and {owner} exactly where they appear. No emoji.\n\nLines:\n$current\n\n'
      'Return JSON with the same keys.';
}

/// Rules an authored line must meet; otherwise the default is kept.
bool acceptablePhrase(String key, String line) {
  final lower = line.toLowerCase();
  final question = line.trim().endsWith('?');
  if (line.length < 8 || line.length > 220) return false;
  if (line.contains(RegExp(r'[<>{}]')) && line.replaceAll(RegExp(r'\{(caller|owner)\}'), '').contains(RegExp(r'[<>{}]'))) {
    return false;
  }
  return switch (key) {
    'identified' => line.contains('{caller}') && lower.contains('message') && question,
    'ask_message' => question && (lower.contains('message') || lower.contains('tell')),
    'message_taken' => line.contains('{owner}') && question,
    'spam' || 'goodbye' => lower.contains('bye'),
    'give_up' => line.contains('{owner}') && question,
    'fallback_message' => line.contains('{owner}') && lower.contains('message') && question,
    'availability_followup' => question && lower.contains('message'),
    'ask_day' => question && lower.contains('day'),
    'clarify_who' => question && lower.contains('who'),
    'clarify_more' => question,
    'transfer_context' || 'transfer_context_again' => line.contains('{owner}') && question,
    'transfer_hold' => line.contains('{owner}') && !question,
    'transfer_connected' => line.contains('{owner}') && !question,
    'transfer_declined' => line.contains('{owner}') && lower.contains('message') && question,
    _ => false,
  };
}

/// One handled turn of the other party.
class FastTurn {
  FastTurn(this.say,
      {this.tool,
      this.args = const {},
      this.ends = false,
      this.hangUp = false,
      this.dtmf,
      this.transfer = false,
      this.label = '',
      this.ms = 0});

  /// What to say; empty means stay silent (e.g. on hold).
  final String say;
  final String? tool;
  final Map<String, String> args;
  final bool ends;

  /// Disconnect after speaking (spam inbound; finished outbound calls).
  final bool hangUp;

  /// Keypad digit to send (phone menus on outbound calls).
  final String? dtmf;

  /// Ask the owner to pick up (warm transfer); the session waits for the answer.
  final bool transfer;
  final String label;
  final int ms;
}

/// Answers the other party's turns in a voice session.
abstract class TurnResponder {
  void start({String? greeting});
  Future<FastTurn?> handle(String said);

  /// Called when nobody has spoken for a while after connecting.
  Future<FastTurn?> onSilence() async => null;

  /// Words heard just as the call ended; nothing can be said back.
  Future<void> lateWords(String said) async {}

  /// Deliberately silent (e.g. on hold): the idle hang-up does not apply.
  bool get waiting => false;
  bool get escalateToLargeModel;
}

/// Answers every turn of a call or text thread with the fine-tuned decision
/// model and fixed phrasings. Anything it cannot handle confidently becomes
/// "take a message". With [escalateToLargeModel] it instead returns null so a
/// large model can answer.
class TieredResponder implements TurnResponder {
  TieredResponder({
    required this.router,
    required this.agent,
    required this.phrases,
    required this.ownerName,
    this.escalateToLargeModel = false,
  });

  final DecisionRouter router;
  final Agent agent;
  final WorkflowPhrases phrases;
  final String ownerName;
  @override
  final bool escalateToLargeModel;

  /// Current workflow step, or null when a large model took over.
  String? step;

  /// The receptionist asked for the message text itself.
  bool awaitingMessage = false;

  /// Consecutive turns that could not be understood.
  int misses = 0;

  /// What the receptionist actually said to open the call.
  String? openingSaid;

  /// Context-aware model: decides from the whole conversation.
  bool get contextMode => router.style == DecisionStyle.context;

  /// The conversation so far, as the context-aware model sees it.
  final List<ConversationLine> lines = [];

  /// Follow-up questions asked to learn the caller's intent.
  int clarifies = 0;

  /// Goodbyes said so far; the second one always ends the call.
  int goodbyes = 0;

  /// An owner task asked the caller a question in the greeting: their next
  /// words are the answer, handed to [onAnswer].
  String? pendingQuestion;
  Future<void> Function(String answer)? onAnswer;

  /// Offer a warm transfer to the owner once (known contacts on calls).
  bool offerTransfer = false;
  bool transferTried = false;

  /// Follow-up questions asked to learn what the call is about before the
  /// owner is asked to pick up.
  int contextAsks = 0;

  /// On-device topic detection (sentence embeddings); null without the model.
  IntentDetector? intents;

  /// What the call is about, shown to the owner: the first valid reason
  /// found, otherwise the latest detected intent (vague or spam).
  IntentMatch? topic;
  IntentMatch? _turnMatch;
  void Function(IntentMatch match)? onTopic;

  /// Standing tasks by topic name: a message to give, a question to ask, or
  /// a transfer to offer. Each applies once per call.
  Map<String, String> topicTell = const {};
  Map<String, String> topicAsk = const {};
  Set<String> topicTransfer = const {};
  Future<void> Function(String topic, String question, String answer)? onTopicAnswer;
  final Set<String> _topicsUsed = {};

  /// Everything the caller has said, for the owner's transfer screen.
  String get callerContext => lines.where((l) => !l.assistant).map((l) => l.text.trim()).join(' ');

  /// Said to the caller just before the owner takes the call.
  String get transferConnected => phrases.render('transfer_connected', _values);

  /// The owner could not pick up: carry on and take a message.
  FastTurn transferDeclined() {
    awaitingMessage = true;
    final say = phrases.render('transfer_declined', _values);
    lines.add(ConversationLine(true, say));
    return FastTurn(say, label: 'transfer_declined');
  }

  @override
  Future<FastTurn?> onSilence() async => null;

  @override
  Future<void> lateWords(String said) async {}

  @override
  bool get waiting => false;

  @override
  void start({String? greeting}) {
    final known = agent.disposition.workflow == Workflow.known;
    step = contextMode ? (known ? 'known' : 'screen') : (known ? 'known_open' : 'screen_open');
    openingSaid = greeting;
    if (greeting != null) lines.add(ConversationLine(true, greeting));
  }

  /// Whether [id] is a step of the current decision style (a text thread may
  /// have saved a step from another model version).
  bool knowsStep(String id) => contextMode ? contextSteps.containsKey(id) : decisionSteps.containsKey(id);

  /// Advances the single-turn step machine; the context model reads the
  /// conversation instead.
  void _next() {
    if (!contextMode) step = 'anything_else';
  }

  static int spamCues(String text) => countSpamCues(text);

  static final _farewell = RegExp(
      r"\b(bye|goodbye|thanks|thank you|never ?mind|wrong number|later|that's all|that is all|nothing)\b",
      caseSensitive: false);

  String get _callerName {
    final identified = agent.executor.identifiedName;
    if (identified != null && identified.isNotEmpty) return identified;
    return (agent.disposition.name ?? '').split(RegExp(r'\s+')).first;
  }

  Map<String, String> get _values => {'caller': _callerName, 'owner': ownerName};
  Set<String> get _tools => agent.tools.map((t) => t.name).toSet();

  /// The step with the owner's real name in what the assistant said.
  DecisionStep _step(String id) {
    if (contextMode) return contextSteps[id]!;
    final base = decisionSteps[id]!;
    final opening = (id == 'known_open' || id == 'screen_open') && openingSaid != null;
    return DecisionStep(
        base.id, opening ? openingSaid! : base.assistantSaid.replaceAll('Sam', ownerName), base.options);
  }

  bool get _atOpening =>
      contextMode ? lines.where((l) => !l.assistant).length <= 1 : (step == 'known_open' || step == 'screen_open');

  Future<FastTurn> _takeMessage(String message, DateTime started) async {
    awaitingMessage = false;
    misses = 0;
    await agent.executor.run('take_message', {'caller_name': _callerName, 'message': message});
    _next();
    return FastTurn(phrases.render('message_taken', _values), tool: 'take_message', args: {'message': message},
        label: 'message', ms: _ms(started));
  }

  /// Warm transfer: keep asking until the caller has said what the call is
  /// about (up to three questions), then ask them to hold while the owner
  /// decides. Still unclear after that, the owner is not interrupted and a
  /// message is taken instead.
  Future<FastTurn?> _transferStep(String label, String callerSaid, DateTime started) async {
    if (!offerTransfer || transferTried || label == 'goodbye' || label == 'spam') return null;
    if (!_clearPurpose(label, callerSaid)) {
      contextAsks++;
      if (contextAsks > maxContextAsks) {
        transferTried = true;
        awaitingMessage = false;
        return _fallback(callerSaid, started);
      }
      final key = switch (contextAsks) {
        1 => 'transfer_context',
        2 => 'clarify_more',
        _ => 'transfer_context_again',
      };
      return FastTurn(phrases.render(key, _values), label: 'transfer_context', ms: _ms(started));
    }
    transferTried = true;
    return FastTurn(phrases.render('transfer_hold', _values), transfer: true, label: 'transfer', ms: _ms(started));
  }

  static const maxContextAsks = 3;

  static final _urgentReason =
      RegExp(r'\b(emergency|urgent|hospital|accident|ambulance|police|hurt|injured|died|passed away)\b', caseSensitive: false);

  /// Words that carry no reason: greetings, filler, asking for the owner,
  /// generic verbs, and vague stand-ins such as "something" or "personal".
  static const _noReason = {
    'i', 'im', 'me', 'my', 'mine', 'you', 'your', 'he', 'him', 'his', 'she', 'her', 'they', 'them', 'it', 'its',
    'is', 'are', 'was', 'be', 'been', 'am', 'the', 'a', 'an', 'and', 'or', 'but', 'to', 'for', 'of', 'on', 'in',
    'at', 'with', 'about', 'from', 'this', 'that', 'there', 'here', 'just', 'so', 'um', 'uh', 'hey', 'hi', 'hello',
    'yes', 'yeah', 'yep', 'ok', 'okay', 'please', 'can', 'could', 'would', 'will', 'wanna', 'want', 'wanted',
    'need', 'needed', 'talk', 'talking', 'speak', 'speaking', 'call', 'calling', 'called', 'get', 'got', 'tell',
    'ask', 'see', 'know', 'like', 'have', 'has', 'had', 'do', 'does', 'did', 'around', 'available', 'reach',
    'regarding', 'sure', 'well', 'not', 'no', 'don', 'dont', 'doesn', 'thats', 'whats', 'something',
    'anything', 'stuff', 'thing', 'things', 'personal', 'private', 'matter', 'important', 'question', 'questions',
    'quick', 'minute', 'second', 'sec', 'real', 'really', 'kind', 'sort', 'some', 'one', 'now', 'phone',
    'line', 'back', 'later', 'again', 'still', 'way', 'also', 'go', 'going', 'let', 'say', 'said', 'put',
    'through', 'connect', 'transfer', 'directly', 'myself', 'actually', 'basically', 'honestly',
  };

  /// A useful, valid reason for the owner to pick up: an emergency, or at
  /// least two real topic words ("dinner plans tonight", "the invoice from
  /// March"). "Can I talk to him?", "it's personal" or "about something" are not.
  bool validReason(String said) {
    if (_urgentReason.hasMatch(said)) return true;
    final owner = ownerName.toLowerCase().split(RegExp(r'\s+'));
    final topics = said
        .toLowerCase()
        .replaceAll("'", '')
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 2 && !_noReason.contains(w) && !owner.contains(w));
    return topics.length >= 2;
  }

  /// A detected topic decides (a valid reason, or vague/spam); without one,
  /// the word rule does.
  bool _clearPurpose(String label, String said) {
    final match = _turnMatch;
    if (match != null) return match.intent.kind == IntentKind.reason;
    return validReason(said);
  }

  /// Default for anything not understood: offer to take a message; after two
  /// misses in a row, log the call for the owner and end politely.
  Future<FastTurn> _fallback(String callerSaid, DateTime started) async {
    misses++;
    if (misses >= 2 || awaitingMessage) {
      // Never hang up on a person: record what they said and keep listening.
      misses = 0;
      awaitingMessage = false;
      await agent.executor.run('take_message', {'caller_name': _callerName, 'message': callerSaid});
      _next();
      return FastTurn(phrases.render('give_up', _values), tool: 'take_message', args: {'message': callerSaid},
          label: 'fallback', ms: _ms(started));
    }
    awaitingMessage = true;
    return FastTurn(phrases.render('fallback_message', _values), label: 'fallback', ms: _ms(started));
  }

  @override
  Future<FastTurn?> handle(String callerSaid) async {
    lines.add(ConversationLine(false, callerSaid));
    router.conversation = lines;
    await _detectTopic(callerSaid);
    final started = DateTime.now();
    final name = _turnMatch?.intent.name;
    FastTurn? turn;
    String? tell;
    if (name != null && pendingQuestion == null && _topicsUsed.add(name)) {
      if (topicTransfer.contains(name)) offerTransfer = true;
      final question = topicAsk[name];
      if (question != null) {
        // A standing task for this topic: ask the owner's question first.
        pendingQuestion = question;
        onAnswer = (answer) async => onTopicAnswer?.call(name, question, answer);
        turn = FastTurn('$ownerName asked me to ask: $question', label: 'topic_ask', ms: _ms(started));
      }
      tell = topicTell[name];
    }
    turn ??= await _handle(callerSaid);
    if (turn != null && tell != null && !turn.hangUp) {
      turn = FastTurn('$ownerName asked me to let you know: $tell ${turn.say}'.trim(),
          tool: turn.tool, args: turn.args, ends: turn.ends, transfer: turn.transfer, label: turn.label, ms: turn.ms);
    }
    if (turn != null) lines.add(ConversationLine(true, turn.say));
    return turn;
  }

  Future<void> _detectTopic(String said) async {
    _turnMatch = null;
    final detector = intents;
    if (detector == null) return;
    try {
      _turnMatch = await detector.detect(said);
    } catch (_) {
      return;
    }
    final match = _turnMatch;
    final current = topic;
    // A valid reason sticks; otherwise show the latest detected intent.
    if (match != null && (current == null || current.intent.kind != IntentKind.reason || match.intent.kind == IntentKind.reason)) {
      topic = match;
      agent.executor
        ..topic = match.intent.name
        ..topicLabel = match.label;
      onTopic?.call(match);
    }
  }

  Future<FastTurn?> _handle(String callerSaid) async {
    final started = DateTime.now();
    if (pendingQuestion != null) {
      pendingQuestion = null;
      await onAnswer?.call(callerSaid);
      return FastTurn(phrases.render('message_taken', _values), label: 'task_answer', ms: _ms(started));
    }
    if (awaitingMessage) {
      // Whatever the caller says now is the message.
      return _takeMessage(callerSaid, started);
    }
    final id = step;
    if (id == null) return null;
    final result = await router.route(_step(id), callerSaid,
        extractFor: const {'identify', 'message', 'availability'});
    if (result.escalate) {
      // An unclear turn from someone the owner may take: ask what it's about.
      final transfer = countSpamCues(callerSaid) >= 2 ? null : await _transferStep('other', callerSaid, started);
      if (transfer != null) return transfer;
      if (escalateToLargeModel) {
        step = null;
        return null;
      }
      return _fallback(callerSaid, started);
    }
    // Never end a call on a guess: at the opening the caller must actually say
    // goodbye, and spam needs high confidence. Otherwise take a message.
    if (result.label == 'goodbye' && _atOpening &&
        (result.probability < 0.95 || !_farewell.hasMatch(callerSaid))) {
      return _fallback(callerSaid, started);
    }
    // A spam-topic match is shown to the owner but does not count toward
    // hanging up: measured on the phone it caught one more scam (39/40) but
    // hung up on two legitimate callers, against 38/40 and none without it.
    final spam = _tools.contains('mark_spam') && shouldHangUpAsSpam(result.label, result.probability, callerSaid);
    if (spam) {
      await agent.executor.run('mark_spam', {'reason': 'spam call'});
      // Record the call as spam (the topic too, whatever words matched).
      agent.endedAsSpam = true;
      if (topic?.intent.kind != IntentKind.spam) {
        topic = IntentMatch(IntentDef(name: 'Spam', kind: IntentKind.spam, examples: const []), 1);
        agent.executor
          ..topic = 'Spam'
          ..topicLabel = 'Spam';
      }
      return FastTurn(phrases.render('spam', _values), tool: 'mark_spam', args: const {'reason': 'spam call'},
          ends: true, hangUp: true, label: 'spam', ms: _ms(started));
    }
    if (result.label == 'spam') return _fallback(callerSaid, started);
    misses = 0;
    final transfer = await _transferStep(result.label, callerSaid, started);
    if (transfer != null) return transfer;
    switch (result.label) {
      case 'clarify':
        // Ask what the call is about before deciding; after two follow-ups,
        // take a message with whatever the caller says.
        clarifies++;
        if (clarifies > 2) return _fallback(callerSaid, started);
        return FastTurn(phrases.render(clarifies == 1 ? 'clarify_who' : 'clarify_more', _values),
            label: 'clarify', ms: _ms(started));
      case 'identify' when _tools.contains('record_caller'):
        final args = {'name': result.slots['name'] ?? '', 'reason': result.slots['reason'] ?? ''};
        await agent.executor.run('record_caller', args);
        _next();
        return FastTurn(phrases.render('identified', _values), tool: 'record_caller', args: args,
            label: 'identify', ms: _ms(started));
      case 'message':
        final message = result.slots['message'] ?? '';
        // "Can I leave a message?" carries no message yet.
        if (message.split(' ').length < 4 || !groundedIn(message, callerSaid)) {
          awaitingMessage = true;
          return FastTurn(phrases.render('ask_message', _values), label: 'message', ms: _ms(started));
        }
        // Keep the caller's exact words; the extracted slot only confirms a message is present.
        return _takeMessage(callerSaid, started);
      case 'availability' when _tools.contains('check_availability'):
        if (escalateToLargeModel) {
          _next();
          return null;
        }
        final period = dayPeriod(callerSaid)?.$3 ?? '';
        final answer = await agent.executor
            .spokenAvailability(result.slots['day'] ?? '', '${result.slots['time'] ?? ''} $period'.trim());
        _next();
        if (answer == null) {
          return FastTurn(phrases.render('ask_day', _values), label: 'availability', ms: _ms(started));
        }
        return FastTurn('$answer ${phrases.render('availability_followup', _values)}', tool: 'check_availability',
            args: {'day': result.slots['day'] ?? '', 'time': result.slots['time'] ?? ''},
            label: 'availability', ms: _ms(started));
      case 'goodbye':
        // A real farewell (the opening guard above already rejected early ones)
        // or a second goodbye ends the call; otherwise keep listening.
        _next();
        goodbyes++;
        final done = goodbyes > 1 || _farewell.hasMatch(callerSaid);
        return FastTurn(phrases.render('goodbye', _values),
            ends: done, hangUp: done, label: 'goodbye', ms: _ms(started));
      default:
        // An option this workflow does not offer (e.g. availability while screening).
        if (escalateToLargeModel) {
          step = null;
          return null;
        }
        return _fallback(callerSaid, started);
    }
  }

  static int _ms(DateTime started) => DateTime.now().difference(started).inMilliseconds;
}


/// Red flags from FTC/FCC/SSA/IRS scam guidance: payment demands (gift cards,
/// wire, crypto, fees), codes and credentials, threats (arrest, warrant,
/// shut-off, suspension), prizes, "press 1", remote access and secrecy.
final _spamCue = RegExp(
    r"\b(buy|selling|sale|offer|deal|discount|promotion|special rate|warranty|insurance|loans?|credit cards?|"
    r"interest rates?|debt|invest\w*|crypto\w*|bitcoin|gift cards?|certificates|wire|payments?|nonpayment|"
    r"pay (now|today|a fee|the fee)|send (money|cash)|cash|courier|bail|fees?|donat\w*|charity|refund|prize|"
    r"winner|you('ve| have) (won|been selected)|free (cruise|vacation|gift|panels|installation)|"
    r"press (one|two|zero|nine|\d)|verify|confirm your|card number|pin|password|codes?|social security|"
    r"medicare (number|card)|bank account|suspend\w*|deactivat\w*|disconnect\w*|shut (off|down)|lawsuit|"
    r"warrant|arrest\w*|jury|police|final notice|irs|survey|solar|homeowner|timeshare|we buy houses|"
    r"remote access|install|virus|hacked|compromised|don't tell|secret|you qualify|qualif\w+ for|at no cost|"
    r"trading|guaranteed|returns|limited (spot|time)|legal documents|fraud case|served with)\b",
    caseSensitive: false);

int countSpamCues(String text) => _spamCue.allMatches(text).length;

/// The receptionist hangs up only on spam, and never on the small model's
/// confidence alone: the caller's own words must contain a red flag.
/// Hang up only on clear spam: the model says spam and there is at least one
/// red flag, or there are two red flags. [topicSpam] (a spam-topic match) is
/// only used by the evaluation, to measure it as an extra red flag.
bool shouldHangUpAsSpam(String label, double probability, String text, {bool topicSpam = false}) {
  final cues = countSpamCues(text) + (topicSpam ? 1 : 0);
  return (label == 'spam' && cues >= 1) || cues >= 2;
}
