import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:android_ai_receptionist/src/agent.dart';
import 'package:android_ai_receptionist/src/calendar.dart';
import 'package:android_ai_receptionist/src/config.dart';
import 'package:android_ai_receptionist/src/contacts.dart';
import 'package:android_ai_receptionist/src/decision.dart';
import 'package:android_ai_receptionist/src/intents.dart';
import 'package:android_ai_receptionist/src/policy.dart';
import 'package:android_ai_receptionist/src/tiered.dart';
import 'package:android_ai_receptionist/src/tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _topics();
  _messageMakesContact();
  _warmTransfer();
  _textThreadSteps();
  test('red flags alone never hang up on the legitimate or ambiguous held-out callers', () {
    final rows = File('test/fixtures/decision_eval_v2.jsonl')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>);
    for (final row in rows.where((r) => r['label'] != 'spam')) {
      // Even if the model wrongly said "spam" with red flags present... the
      // non-spam callers must not carry two red flags on their own.
      expect(countSpamCues(row['caller'] as String), lessThan(2), reason: row['caller'] as String);
      expect(shouldHangUpAsSpam('identify', 0.99, row['caller'] as String), isFalse, reason: row['caller'] as String);
    }
    expect(shouldHangUpAsSpam('spam', 0.99, 'Hi, is Sam available?'), isFalse);
    expect(shouldHangUpAsSpam('identify', 0.96,
        'This is the electric company disconnection department. A technician will shut off power for nonpayment.'), isTrue);
  });

  test('screening: identify, off-script falls back to taking a message, goodbye', () async {
    final (r, host) = _responder('+15555550123', {
      'Alex from the vet': ('identify', '{"name": "Alex", "reason": "vaccines"}'),
      'Bye now': ('goodbye', '{}'),
    });
    final first = await r.handle('Hi, Alex from the vet about the vaccines.');
    expect(first!.say, startsWith('Thanks, Alex.'));
    expect(first.tool, 'record_caller');
    final offScript = await r.handle('Are you a real person?');
    expect(offScript!.say, contains('take a message for Sam'));
    expect(r.awaitingMessage, isTrue);
    final message = await r.handle('Tell Sam the vaccines are due Friday.');
    expect(message!.tool, 'take_message');
    expect(host.messages.single.message, 'Tell Sam the vaccines are due Friday.');
    final bye = await r.handle('Bye now');
    expect(bye!.ends, isTrue, reason: 'a real farewell after the opening ends the call');
    expect(bye.hangUp, isTrue);
    expect(bye.say, contains('Goodbye'));
  });

  test('known caller availability is answered from the calendar without Gemma', () async {
    final (r, _) = _responder('+15555550100', {
      'free tomorrow': ('availability', '{"day": "tomorrow", "time": ""}'),
    });
    final turn = await r.handle('Is Sam free tomorrow afternoon?');
    expect(turn!.say, startsWith('Sam is free tomorrow in the afternoon from twelve PM to five PM.'));
    expect(turn.say, endsWith('Would you like to leave a message for Sam?'));
    expect(r.step, 'anything_else');
  });

  test('a garbled first line never hangs up (regression)', () async {
    final (r, host) = _responder('+15555550100', {
      'I got worse': ('goodbye', '{}'),
      'Okay bye': ('goodbye', '{}'),
    });
    final turn = await r.handle('Uh, I got worse.');
    expect(turn!.ends, isFalse);
    expect(turn.say, contains('take a message'));
    final message = await r.handle('Tell Sam the car is ready.');
    expect(message!.tool, 'take_message');
    expect(host.messages.single.message, 'Tell Sam the car is ready.');
    final bye = await r.handle('Okay bye');
    expect(bye!.ends, isTrue, reason: 'after the message, a real goodbye hangs up');
  });

  test('a goodbye without farewell words keeps listening once, then ends', () async {
    final (r, _) = _responder('+15555550100', {
      'free tomorrow': ('availability', '{"day": "tomorrow", "time": ""}'),
      'I am done': ('goodbye', '{}'),
      'Good good': ('goodbye', '{}'),
    });
    await r.handle('Is Sam free tomorrow afternoon?');
    final first = await r.handle('I am done');
    expect(first!.ends, isFalse);
    final second = await r.handle('Good good');
    expect(second!.ends, isTrue);
  });

  test('two misses in a row are recorded as a message and the call stays open', () async {
    final (r, host) = _responder('+15555550123', {});
    final first = await r.handle('What is the meaning of life?');
    expect(first!.ends, isFalse);
    r.awaitingMessage = false; // caller ignored the offer
    final second = await r.handle('Seriously, what is it?');
    expect(second!.ends, isFalse);
    expect(second.say, "I've noted that for Sam. Is there anything else you'd like me to pass on?");
    expect(host.messages, hasLength(1));
  });

  test('context model asks follow-ups before deciding, then takes a message', () async {
    final (r, host) = _responder('+15555550123', {
      'Caller: Hi, is Sam there?\nChoose': ('clarify', '{}'),
      'Caller: It is personal.\nChoose': ('clarify', '{}'),
      'Caller: Just tell Sam to call me.\nChoose': ('clarify', '{}'),
    }, style: DecisionStyle.context);
    expect(r.step, 'screen');
    final first = await r.handle('Hi, is Sam there?');
    expect(first!.say, "Sam isn't available right now. May I ask who's calling and what it's regarding?");
    final second = await r.handle('It is personal.');
    expect(second!.say, 'Could you tell me a bit more about what you need from Sam?');
    final third = await r.handle('Just tell Sam to call me.');
    expect(third!.say, contains('take a message'));
    expect(r.lines.map((l) => l.assistant).toList(), [true, false, true, false, true, false, true]);
    expect(host.messages, isEmpty);
  });

  test('context prompt carries the conversation so far', () async {
    // Spam is only recognisable with the earlier turns in view.
    final backend = _Backend({
      'May I ask who': ('spam', '{}'),
      'bank security team.\nChoose': ('clarify', '{}'),
    });
    final cfg = ReceptionistConfig.fromJson({'owner_name': 'Sam'});
    final agent = Agent(
        config: cfg, disposition: CallerPolicy(cfg).classify('+15555550123'), channel: Channel.call,
        model: _NoModel(), host: _Host());
    final r = TieredResponder(
        router: DecisionRouter(backend, PromptFormat.chatml, style: DecisionStyle.context),
        agent: agent, phrases: WorkflowPhrases.defaults, ownerName: 'Sam')
      ..start(greeting: 'Hi, how can I help?');
    await r.handle('Hi, this is the bank security team.');
    final turn = await r.handle('Read me the six digit code we just sent.');
    expect(turn!.tool, 'mark_spam');
    expect(turn.ends, isTrue);
  });

  test('only spam hangs up: selling, asking for money, or asking to act', () async {
    for (final line in [
      "We've been trying to reach you about your car's extended warranty.",
      'You need to buy gift cards to pay the fee today.',
      'Press one to verify your bank account.',
    ]) {
      final (r, _) = _responder('+15555550123', {'': ('spam', '{}')});
      final turn = await r.handle(line);
      expect(turn!.ends, isTrue, reason: line);
      expect(turn.tool, 'mark_spam');
    }
    // A low-confidence "spam" guess without sales or money cues is not hung up on.
    final (unsure, _) = _responder('+15555550123', {});
    final turn = await unsure.handle('Hi, this is Dana, call me back.');
    expect(turn!.ends, isFalse);
  });

  test('phrase grammar is valid GBNF for the phrase keys', () {
    final grammar = phraseGrammar(['identified', 'goodbye']);
    expect(grammar.split('\n').first, r'root ::= "{" "\"identified\": " str ", \"goodbye\": " str "}"');
    expect(grammar, contains(r'str ::= "\"" chr{1,200} "\""'));
    expect(grammar, contains(r'chr ::= [^"\\\x00-\x1F]'));
  });

  test('authored lines must keep their meaning and placeholders', () {
    expect(acceptablePhrase('identified', 'Thank you, {caller}. {owner} is out. Can I take a message?'), isTrue);
    expect(acceptablePhrase('identified', 'Ava: Hello, this is Ava speaking. How may I help you today?'), isFalse);
    expect(acceptablePhrase('message_taken', 'I understand. Thank you for leaving your message.'), isFalse);
    expect(acceptablePhrase('message_taken', "I'll tell {owner}. Anything else I can do?"), isTrue);
    expect(acceptablePhrase('spam', 'Thank you for calling us today. Goodbye.'), isTrue);
    for (final entry in WorkflowPhrases.defaults.values.entries) {
      expect(acceptablePhrase(entry.key, entry.value), isTrue, reason: entry.key);
    }
  });

  test('authored phrases keep defaults for missing or unknown keys', () {
    final phrases = WorkflowPhrases.fromJson(jsonDecode('{"goodbye": "Bye now!", "unknown": "x", "spam": ""}'));
    expect(phrases.values['goodbye'], 'Bye now!');
    expect(phrases.values.containsKey('unknown'), isFalse);
    expect(phrases.values['spam'], WorkflowPhrases.defaults.values['spam']);
    expect(phrases.render('identified', {'caller': 'Alex', 'owner': 'Sam'}), startsWith('Thanks, Alex. Sam'));
  });
}

// ---------------------------------------------------------------- flows

class _Backend implements DecisionBackend {
  _Backend(this.answers);

  /// Caller text fragment -> (label, slots json).
  final Map<String, (String, String)> answers;

  (String, String) _match(String prompt) {
    for (final e in answers.entries) {
      if (prompt.contains(e.key)) return e.value;
    }
    return ('other', '{}');
  }

  @override
  Future<(List<double>, int)> score(RenderedPrompt prompt, List<String> options) async {
    final (label, _) = _match(prompt.text);
    return ([for (final o in options) o == label ? math.log(0.97) : math.log(0.03 / options.length)], 5);
  }

  @override
  Future<String> extract(RenderedPrompt prompt, String grammar) async => _match(prompt.text).$2;
}

class _Host implements ToolHost {
  final messages = <TakenMessage>[];
  final records = <String>[];
  final book = ContactBook.empty();
  @override
  DateTime now() => DateTime(2026, 11, 2, 9, 30);
  @override
  Future<List<CalendarEvent>> calendar(DateTime start, DateTime end) async => [];
  @override
  Future<(DateTime, DateTime)?> workingHours(DateTime day) async => CalendarData.defaults().hoursFor(day);
  @override
  Future<void> notifyOwner(String title, String body, {bool urgent = false}) async {}
  @override
  Future<void> record(String kind, Map<String, dynamic> data) async => records.add(kind);
  @override
  Future<void> saveMessage(TakenMessage message) async => messages.add(message);
  @override
  Future<void> updateContact(String number, void Function(TrackedContact contact) change) async =>
      change(book.touch(number));
  @override
  Future<void> blockNumber(String number, String reason) async {}
}

class _NoModel implements LanguageModel {
  @override
  Future<String> generate(String prompt,
          {required String grammar, int maxTokens = 160, double temperature = 0.4, void Function(String)? onToken}) =>
      throw StateError('Gemma must not be used');
  @override
  Future<void> prefill(String prompt) async {}
  @override
  void cancel() {}
}

void _textThreadSteps() {
  test('a text thread restores only steps of the current model style', () {
    final (context, _) = _responder('+15555550100', {}, style: DecisionStyle.context);
    context.start();
    expect(context.step, 'known');
    expect(context.knowsStep('known_open'), isFalse, reason: 'a v1 step saved by an older model');
    expect(context.knowsStep('known'), isTrue);
    final (tuned, _) = _responder('+15555550100', {});
    tuned.start();
    expect(tuned.step, 'known_open');
    expect(tuned.knowsStep('anything_else'), isTrue);
  });
}

void _warmTransfer() {
  test('a known contact is offered to the owner once, then a message is taken', () async {
    final (r, host) = _responder('+15555550100', {
      'free tomorrow': ('availability', '{"day": "tomorrow", "time": ""}'),
    });
    r.offerTransfer = true;
    final hold = await r.handle('Is Sam free tomorrow afternoon?');
    expect(hold!.transfer, isTrue);
    expect(hold.say, 'One moment, let me see if Sam can pick up.');
    expect(r.transferConnected, "Here's Sam now.");
    final declined = r.transferDeclined();
    expect(declined.say, "Sam can't come to the phone right now. Would you like to leave a message?");
    final message = await r.handle('Tell Sam to call me about dinner.');
    expect(message!.tool, 'take_message');
    expect(host.messages.single.message, 'Tell Sam to call me about dinner.');
  });

  test('the assistant keeps asking until the reason is clear, then asks the owner', () async {
    final (r, _) = _responder('+15555550100', {
      'around': ('other', '{}'),
      'talk to him': ('other', '{}'),
      'dinner': ('other', '{}'),
    });
    r.offerTransfer = true;
    r.start(greeting: "Hi Jordan, you've reached Sam's AI Assistant. How can I help?");
    final first = await r.handle('Hey, is Sam around?');
    expect(first!.transfer, isFalse);
    expect(first.say, "I'll see if Sam can pick up. What's it about?");
    final second = await r.handle('Can I just talk to him?');
    expect(second!.transfer, isFalse, reason: 'asking for the owner is not a reason');
    expect(second.say, 'Could you tell me a bit more about what you need from Sam?');
    final hold = await r.handle("It's about the dinner plans for tonight.");
    expect(hold!.transfer, isTrue);
    expect(r.callerContext, "Hey, is Sam around? Can I just talk to him? It's about the dinner plans for tonight.");
  });

  test('only a useful, valid reason gets the owner on the phone', () {
    final (r, _) = _responder('+15555550100', {});
    for (final vague in ['Hey, is Sam around?', 'Can I just talk to him?', 'I need to talk to him about something.',
        "It's personal.", 'Just a quick question for Sam.', 'Hello?', 'Tell him to call me back.']) {
      expect(r.validReason(vague), isFalse, reason: vague);
    }
    for (final useful in ["It's about the dinner plans for tonight.", 'Is Sam free tomorrow afternoon?',
        "It's an emergency.", 'About the invoice from March.', 'The car repair estimate is ready.']) {
      expect(r.validReason(useful), isTrue, reason: useful);
    }
  });

  test('still unclear after three questions: no transfer, a message is taken', () async {
    final (r, host) = _responder('+15555550100', {'.': ('other', '{}')});
    r.offerTransfer = true;
    for (final said in ['Hello?', 'Is he there?', 'Yeah.']) {
      expect((await r.handle(said))!.transfer, isFalse);
    }
    final last = await r.handle('Um.');
    expect(last!.transfer, isFalse);
    expect(r.transferTried, isTrue);
    expect(last.say, contains('message'));
    expect(host.messages, isEmpty, reason: 'nothing worth saving was said yet');
  });

  test('no transfer is offered when the caller is just saying goodbye', () async {
    final (r, _) = _responder('+15555550100', {'Bye': ('goodbye', '{}')});
    r.offerTransfer = true;
    await r.handle('Hi there.');
    final bye = await r.handle('Bye now');
    expect(bye!.transfer, isFalse);
  });
}

void _messageMakesContact() {
  test('a spam hang-up is recorded as spam, whatever topic the words matched', () async {
    final (r, _) = _responder('+15555550123', {'warranty': ('spam', '{}')});
    r.intents = IntentDetector(intents: IntentDef.defaults, embed: _bagOfWords, threshold: 0.3);
    final turn = await r.handle('You have been selected for a free warranty offer, I need a billing contact and '
        'your credit card to confirm, press one now');
    expect(turn!.hangUp, isTrue);
    expect(r.agent.endedAsSpam, isTrue);
    expect(r.topic!.intent.kind, IntentKind.spam);
  });

  test('a known caller who leaves a message is saved as a known contact', () async {
    final (r, host) = _responder('+15555550100', {});
    r.awaitingMessage = true;
    await r.handle('Tell Sam I will be late tonight.');
    final contact = host.book.find('+15555550100')!;
    expect(contact.status, ContactStatus.known);
    expect(contact.name, isNotEmpty);
  });

  test('an unknown caller who leaves a message becomes a named, screened contact', () async {
    final (r, host) = _responder('+15555550123', {
      'Alex from the vet': ('identify', '{"name": "Alex", "reason": "vaccines"}'),
    });
    await r.handle('Hi, Alex from the vet about the vaccines.');
    r.awaitingMessage = true;
    await r.handle('Tell Sam the vaccines are due Friday.');
    final contact = host.book.find('+15555550123')!;
    expect(contact.name, 'Alex');
    expect(contact.status, ContactStatus.screened);
    expect(contact.facts, contains('Called about: vaccines'));
    expect(contact.history.last.summary, 'left a message: Tell Sam the vaccines are due Friday.');
  });
}

Future<List<List<double>>> _bagOfWords(List<String> texts) async => [
      for (final t in texts)
        () {
          final v = List<double>.filled(64, 0);
          for (final w in t.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.length > 2)) {
            v[w.hashCode % 64] += 1;
          }
          final n = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
          return n == 0 ? v : [for (final x in v) x / n];
        }(),
    ];

void _topics() {
  test('detected topics decide the reason, show as the call topic, and drive topic tasks', () async {
    final (r, _) = _responder('+15555550100', {'.': ('other', '{}')});
    r
      ..offerTransfer = true
      ..intents = IntentDetector(intents: IntentDef.defaults, embed: _bagOfWords, threshold: 0.5);
    final vague = await r.handle('Can I talk to him please?');
    expect(vague!.transfer, isFalse);
    final plans = await r.handle('Are we still meeting for coffee tomorrow?');
    expect(plans!.transfer, isTrue);
    expect(r.topic!.intent.name, 'Plans');

    final (d, _) = _responder('+15555550123', {'.': ('other', '{}')});
    d
      ..intents = IntentDetector(intents: IntentDef.defaults, embed: _bagOfWords, threshold: 0.5)
      ..topicTell = {'Delivery': 'Leave it at the side door.'};
    final turn = await d.handle('I have a package delivery for you');
    expect(turn!.say, startsWith('Sam asked me to let you know: Leave it at the side door.'));
  });
}

(TieredResponder, _Host) _responder(String number, Map<String, (String, String)> answers,
    {DecisionStyle style = DecisionStyle.tuned}) {
  final cfg = ReceptionistConfig.fromJson({
    'owner_name': 'Sam',
    'contacts': [
      {'name': 'Jordan Lee', 'numbers': ['+15555550100']},
    ],
  });
  final host = _Host();
  final agent = Agent(
      config: cfg,
      disposition: CallerPolicy(cfg).classify(number),
      channel: Channel.call,
      model: _NoModel(),
      host: host);
  final responder = TieredResponder(
      router: DecisionRouter(_Backend(answers), PromptFormat.chatml, style: style),
      agent: agent,
      phrases: WorkflowPhrases.defaults,
      ownerName: 'Sam')
    ..start(greeting: "Hi, you've reached Sam's AI Assistant. How can I help?");
  return (responder, host);
}

