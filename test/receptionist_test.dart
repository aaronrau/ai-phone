import 'dart:convert';

import 'package:android_ai_receptionist/src/agent.dart';
import 'package:android_ai_receptionist/src/calendar.dart';
import 'package:android_ai_receptionist/src/config.dart';
import 'package:android_ai_receptionist/src/contacts.dart';
import 'package:android_ai_receptionist/src/policy.dart';
import 'package:android_ai_receptionist/src/reply.dart';
import 'package:android_ai_receptionist/src/tools.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHost implements ToolHost {
  FakeHost(this.clock, [this.events = const []]);
  final DateTime clock;
  final List<CalendarEvent> events;
  final messages = <TakenMessage>[];
  final notifications = <String>[];
  final records = <String>[];
  final book = ContactBook.empty();
  final blocked = <String>[];

  @override
  Future<void> updateContact(String number, void Function(TrackedContact contact) change) async =>
      change(book.touch(number));
  @override
  Future<void> blockNumber(String number, String reason) async => blocked.add(number);

  @override
  DateTime now() => clock;
  @override
  Future<List<CalendarEvent>> calendar(DateTime start, DateTime end) async =>
      events.where((e) => e.start.isBefore(end) && e.end.isAfter(start)).toList();
  @override
  Future<(DateTime, DateTime)?> workingHours(DateTime day) async => CalendarData.defaults().hoursFor(day);
  @override
  Future<void> notifyOwner(String title, String body, {bool urgent = false}) async =>
      notifications.add('$title: $body');
  @override
  Future<void> record(String kind, Map<String, dynamic> data) async => records.add(kind);
  @override
  Future<void> saveMessage(TakenMessage message) async => messages.add(message);
}

class ScriptedModel implements LanguageModel {
  ScriptedModel(this.outputs);
  final List<String> outputs;
  final prompts = <String>[];
  final grammars = <String>[];

  @override
  Future<String> generate(String prompt,
      {required String grammar, int maxTokens = 160, double temperature = 0.4, void Function(String)? onToken}) async {
    prompts.add(prompt);
    grammars.add(grammar);
    final out = outputs.removeAt(0);
    for (var i = 0; i < out.length; i += 3) {
      onToken?.call(out.substring(i, i + 3 > out.length ? out.length : i + 3));
    }
    return out;
  }

  @override
  Future<void> prefill(String prompt) async {}
  @override
  void cancel() {}
}

ReceptionistConfig config([Map<String, dynamic> extra = const {}]) => ReceptionistConfig.fromJson({
      'owner_name': 'Sam',
      'assistant_name': 'Ava',
      'contacts': [
        {'name': 'Jordan Lee', 'numbers': ['+1 (555) 555-0100'], 'relationship': 'sister'},
        {'name': 'Spam Co', 'numbers': ['5555550199'], 'workflow': 'block'},
      ],
      'blocked_numbers': ['+15555550111'],
      'screening_rules': [
        {'type': 'prefix', 'value': '+1555'},
      ],
      ...extra,
    });

void main() {
  group('policy', () {
    test('configured contacts match across formatting', () {
      final d = CallerPolicy(config()).classify('5555550100');
      expect(d.workflow, Workflow.known);
      expect(d.name, 'Jordan Lee');
    });

    test('blocked list and block contacts win', () {
      expect(CallerPolicy(config()).classify('+1 555 555 0111').workflow, Workflow.block);
      expect(CallerPolicy(config()).classify('+15555550199').workflow, Workflow.block);
    });

    test('phone contacts are known when enabled', () {
      expect(CallerPolicy(config()).classify('+447700900000', phoneContactName: 'Pat').workflow, Workflow.known);
      expect(
        CallerPolicy(config({'use_phone_contacts': false}))
            .classify('+447700900000', phoneContactName: 'Pat')
            .workflow,
        Workflow.block,
      );
    });

    test('screening rules decide unknown numbers, everyone else is blocked', () {
      expect(CallerPolicy(config()).classify('+15555550123').workflow, Workflow.screen);
      expect(CallerPolicy(config()).classify('+447700900123').workflow, Workflow.block);
      expect(CallerPolicy(config()).classify('').workflow, Workflow.block);
      expect(
        CallerPolicy(config({'screening_rules': [{'type': 'withheld'}]})).classify('').workflow,
        Workflow.screen,
      );
    });

    test('texts are only handled for known contacts', () {
      final policy = CallerPolicy(config({'screening_rules': [{'type': 'any'}]}));
      expect(policy.classify('72345', sms: true).workflow, Workflow.block);
      expect(policy.classify('+15555550123', sms: true).workflow, Workflow.block);
      expect(policy.classify('+15555550100', sms: true).workflow, Workflow.known);
      expect(policy.classify('+447700900000', phoneContactName: 'Pat', sms: true).workflow, Workflow.known);
    });

    test('contact book statuses drive calls', () {
      final book = ContactBook.empty();
      book.touch('+15555550150').status = ContactStatus.known;
      book.touch('+15555550151')
        ..status = ContactStatus.screened
        ..name = 'Alex';
      book.touch('+15555550152').status = ContactStatus.blocked;
      final policy = CallerPolicy(config({'screening_rules': []}), book);
      expect(policy.classify('5555550150').workflow, Workflow.known);
      final screened = policy.classify('5555550151');
      expect(screened.workflow, Workflow.screen);
      expect(screened.name, 'Alex');
      expect(policy.classify('5555550152').workflow, Workflow.block);
      expect(policy.classify('5555550153').workflow, Workflow.block);
    });
  });

  group('reply parsing', () {
    test('parses tool calls', () {
      final reply = AgentReply.parse(
          '{"say": "I\'ll pass that on.", "tool": {"name": "take_message", "args": {"caller_name": "Jo", "message": "Call me", "callback_number": ""}}}');
      expect(reply.say, "I'll pass that on.");
      expect(reply.toolName, 'take_message');
      expect(reply.args['message'], 'Call me');
    });

    test('streams say text across token boundaries and escapes', () {
      final extractor = SayExtractor();
      final raw = jsonEncode({'say': 'Hi "there", it\'s fine\\ok', 'tool': null});
      final out = StringBuffer();
      for (var i = 0; i < raw.length; i += 2) {
        out.write(extractor.add(raw.substring(i, i + 2 > raw.length ? raw.length : i + 2)));
      }
      expect(out.toString(), 'Hi "there", it\'s fine\\ok');
      expect(extractor.done, isTrue);
    });

    test('chunks sentences for speech', () {
      final chunker = SentenceChunker();
      expect(chunker.add('Hello there. How are'), ['Hello there.']);
      expect(chunker.add(' you? I'), ['How are you?']);
      expect(chunker.flush(), 'I');
    });

    test('drops questions asking for the caller number', () {
      expect(dropNumberQuestions('I will tell Sam. Can you please leave your number for them? Goodbye.'),
          'I will tell Sam. Goodbye.');
      expect(dropNumberQuestions('What is the best number to reach you at?'), '');
      expect(dropNumberQuestions('Sam is free at two.'), 'Sam is free at two.');
    });

    test('plain text fallback', () {
      expect(AgentReply.parse('Sure, no problem').say, 'Sure, no problem');
    });
  });

  group('grammar', () {
    test('lists each enabled tool with its exact arguments', () {
      final grammar = buildGrammar(toolsFor(config(), config().known));
      expect(grammar, contains('root ::='));
      expect(grammar, contains('t-take-message'));
      expect(grammar, contains(r'\"message\": '));
      expect(grammar, isNot(contains('callback_number')));
      expect(grammar, contains(r'"{\"name\": \"end_conversation\", \"args\": {" "}}"'));
      expect(grammar, isNot(contains('record-caller')));
    });
  });

  group('availability', () {
    final now = DateTime(2026, 11, 2, 9, 30); // Monday
    test('day parsing', () {
      expect(parseDay('today', now), DateTime(2026, 11, 2));
      expect(parseDay('tomorrow', now), DateTime(2026, 11, 3));
      expect(parseDay('Friday', now), DateTime(2026, 11, 6));
      expect(parseDay('monday', now), DateTime(2026, 11, 9));
      expect(parseDay('2026-12-01', now), DateTime(2026, 12, 1));
      expect(parseDay('November 20', now), DateTime(2026, 11, 20));
    });

    test('day parsing across the end of daylight saving time', () {
      final saturday = DateTime(2026, 10, 31, 12, 29);
      expect(parseDay('Monday', saturday), DateTime(2026, 11, 2));
      expect(parseDay('tomorrow', saturday), DateTime(2026, 11, 1));
      expect(describeDay(DateTime(2026, 11, 1), saturday), startsWith('tomorrow'));
    });

    test('voice channels get spoken times', () async {
      final host = FakeHost(DateTime(2026, 11, 2, 9, 30), [
        CalendarEvent(DateTime(2026, 11, 3, 12), DateTime(2026, 11, 3, 13, 30), 'Lunch'),
      ]);
      final cfg = config();
      final executor = ToolExecutor(
          config: cfg, disposition: CallerPolicy(cfg).classify('5555550100'), channel: 'call', host: host);
      final result = await executor.run('check_availability', {'day': 'tomorrow', 'time': ''});
      expect(result.result, contains('Busy: twelve PM to one thirty PM'));
      expect(result.result, contains('available nine AM to five PM'));
    });

    test('spoken availability for the small-model path', () async {
      final host = FakeHost(DateTime(2026, 11, 2, 9, 30), [
        CalendarEvent(DateTime(2026, 11, 3, 10), DateTime(2026, 11, 3, 11), 'Dentist'),
        CalendarEvent(DateTime(2026, 11, 3, 14), DateTime(2026, 11, 3, 15, 30), 'Review'),
      ]);
      final cfg = config();
      final executor = ToolExecutor(
          config: cfg, disposition: CallerPolicy(cfg).classify('5555550100'), channel: 'call', host: host);
      expect(await executor.spokenAvailability('tomorrow', ''),
          'Sam is free tomorrow from nine AM to ten AM, from eleven AM to two PM and from three thirty PM to five PM.');
      expect(await executor.spokenAvailability('tomorrow afternoon', ''),
          'Sam is free tomorrow in the afternoon from twelve PM to two PM and from three thirty PM to five PM.');
      expect(await executor.spokenAvailability('tomorrow', '10am'),
          'Sam is busy at ten AM tomorrow, but is free from nine AM to ten AM, from eleven AM to two PM and from three thirty PM to five PM.');
      expect(await executor.spokenAvailability('tomorrow', '12'), 'Sam looks free at twelve PM tomorrow.');
      expect(await executor.spokenAvailability('Saturday', ''), "Sam isn't available on Saturday November 7.");
      expect(await executor.spokenAvailability('someday maybe', ''), isNull);
      final spoken = await executor.spokenAvailability('tomorrow', '');
      expect(spoken, isNot(contains('Dentist')));
    });

    test('working hours and free windows', () async {
      final host = FakeHost(now, [
        CalendarEvent(DateTime(2026, 11, 3, 10), DateTime(2026, 11, 3, 11), 'Dentist'),
        CalendarEvent(DateTime(2026, 11, 3, 14), DateTime(2026, 11, 3, 15, 30), 'Team lunch',
            shareDetails: true, notes: 'at the office'),
      ]);
      final executor = ToolExecutor(
        config: config(),
        disposition: CallerPolicy(config()).classify('5555550100'),
        channel: 'sms',
        host: host,
      );
      final result = await executor.run('check_availability', {'day': 'tomorrow', 'time': '3pm'});
      expect(result.result, contains('Busy: 10 AM to 11 AM, 2 PM to 3:30 PM (Team lunch, at the office)'));
      expect(result.result, contains('Free: 9 AM to 10 AM, 11 AM to 2 PM, 3:30 PM to 5 PM'));
      expect(result.result, contains('At 3 PM: not free'));
      expect(result.result, isNot(contains('Dentist')));
      final weekend = await executor.run('check_availability', {'day': 'saturday', 'time': ''});
      expect(weekend.result, contains('not available on this day'));
    });
  });

  group('agent', () {
    test('known caller: availability then message then goodbye', () async {
      final now = DateTime(2026, 11, 2, 9, 30);
      final host = FakeHost(now);
      final model = ScriptedModel([
        '{"say": "Let me check.", "tool": {"name": "check_availability", "args": {"day": "tomorrow", "time": ""}}}',
        '{"say": "Sam is free tomorrow from nine to five.", "tool": null}',
        '{"say": "Got it, I will pass that on.", "tool": {"name": "take_message", "args": {"caller_name": "Jordan", "message": "Lunch tomorrow?"}}}',
        '{"say": "Bye!", "tool": {"name": "end_conversation", "args": {}}}',
      ]);
      final agent = Agent(
        config: config(),
        disposition: CallerPolicy(config()).classify('5555550100'),
        channel: Channel.call,
        model: model,
        host: host,
      );
      final greeting = agent.startCall();
      expect(greeting, contains('Hi Jordan'));
      final spoken = StringBuffer();
      final first = await agent.respond('Is Sam free tomorrow?', onSay: spoken.write);
      expect(first.map((r) => r.say), ['Let me check.', 'Sam is free tomorrow from nine to five.']);
      expect(spoken.toString(), 'Let me check. Sam is free tomorrow from nine to five.');
      expect(model.prompts[1], contains('[Tool result for check_availability: Calendar for tomorrow'));

      await agent.respond('Tell Sam lunch tomorrow?');
      expect(host.messages.single.message, 'Lunch tomorrow?');
      expect(host.messages.single.callbackNumber, '5555550100');
      expect(host.notifications.single, contains('Jordan'));

      await agent.respond("That's all, bye");
      expect(agent.ended, isTrue);
      // The take_message result is carried into the next user turn.
      expect(model.prompts.last, contains('[Tool result for take_message'));
      // Roles strictly alternate after the system prompt.
      final roles = agent.turns.map((t) => t.role).toList();
      for (var i = 1; i < roles.length; i++) {
        expect(roles[i], isNot(roles[i - 1]));
      }
    });

    test('screen workflow uses screening prompt and tools', () async {
      final model = ScriptedModel(['{"say": "Who is calling?", "tool": null}']);
      final agent = Agent(
        config: config(),
        disposition: CallerPolicy(config()).classify('+15555550123'),
        channel: Channel.sms,
        model: model,
        host: FakeHost(DateTime(2026, 11, 2)),
      );
      await agent.respond('hi is sam there');
      expect(model.prompts.single, contains('not in the contact list'));
      expect(model.prompts.single, contains('Text message: hi is sam there'));
      expect(model.grammars.single, contains('t-record-caller'));
      expect(model.grammars.single, isNot(contains('t-check-availability')));
    });
  });

  group('calendar', () {
    test('weekly hours and item queries', () {
      final data = CalendarData.defaults();
      data.week.firstWhere((d) => d.weekday == 6)
        ..enabled = true
        ..start = '10:00'
        ..end = '12:30';
      expect(data.hoursFor(DateTime(2026, 11, 7)), (DateTime(2026, 11, 7, 10), DateTime(2026, 11, 7, 12, 30)));
      expect(data.hoursFor(DateTime(2026, 11, 8)), isNull);
      data.items.add(CalendarItem(
          id: 'a', title: 'Dentist', start: DateTime(2026, 11, 3, 10), end: DateTime(2026, 11, 3, 11)));
      final round = CalendarData.fromJson(jsonDecode(data.encode()) as Map<String, dynamic>);
      expect(round.itemsBetween(DateTime(2026, 11, 3), DateTime(2026, 11, 4)).single.title, 'Dentist');
      expect(round.hoursFor(DateTime(2026, 11, 7))!.$2, DateTime(2026, 11, 7, 12, 30));
    });
  });

  group('contact learning', () {
    test('screening identifies, remembers and blocks spam', () async {
      final cfg = config();
      final host = FakeHost(DateTime(2026, 11, 2, 10));
      final executor = ToolExecutor(
          config: cfg, disposition: CallerPolicy(cfg).classify('+15555550123'), channel: 'call', host: host);
      await executor.run('record_caller', {'name': 'Alex', 'reason': 'dental appointment'});
      await executor.run('remember', {'fact': 'works at Brightside Dental'});
      final contact = host.book.find('5555550123')!;
      expect(contact.status, ContactStatus.screened);
      expect(contact.name, 'Alex');
      expect(contact.facts, ['works at Brightside Dental']);
      expect(contact.describe(), contains('Brightside Dental'));

      final spam = ToolExecutor(
          config: cfg, disposition: CallerPolicy(cfg).classify('+15555550124'), channel: 'call', host: host);
      final outcome = await spam.run('mark_spam', {'reason': 'warranty robocall'});
      expect(outcome.endConversation, isTrue);
      expect(host.blocked, ['+15555550124']);
      expect(host.book.find('+15555550124')!.status, ContactStatus.blocked);
    });

    test('contact book round-trips and bounds history', () {
      final book = ContactBook.empty();
      final c = book.touch('+15555550160');
      for (var i = 0; i < 40; i++) {
        c.addEvent('call', 'event $i', DateTime(2026, 11, 1, 9, i));
      }
      c.addFact('likes mornings');
      c.addFact('Likes mornings');
      final round = ContactBook.fromJson(book.toJson());
      expect(round.contacts.single.history.length, TrackedContact.maxHistory);
      expect(round.contacts.single.facts, ['likes mornings']);
    });
  });

  group('config', () {
    test('defaults round-trip and validate', () {
      final text = ReceptionistConfig.defaults().encode();
      expect(ReceptionistConfig.validate(text), isEmpty);
    });

    test('rejects unknown tools and bad custom tools', () {
      final bad = jsonEncode({
        'workflows': {
          'known': {'tools': ['take_message', 'fly_to_moon']},
        },
        'custom_tools': [
          {'name': 'Bad Name', 'description': 'x', 'args': {}, 'action': 'explode', 'template': ''},
        ],
      });
      final problems = ReceptionistConfig.validate(bad);
      expect(problems.any((p) => p.contains('fly_to_moon')), isTrue);
      expect(problems.any((p) => p.contains('snake_case')), isTrue);
      expect(problems.any((p) => p.contains('action')), isTrue);
    });

    test('custom notify tool fills its template', () async {
      final cfg = config({
        'custom_tools': [
          {
            'name': 'flag_urgent',
            'description': 'Flag an urgent matter',
            'args': {'reason': 'why'},
            'action': 'notify',
            'template': 'URGENT from {caller}: {reason}',
          },
        ],
      });
      final host = FakeHost(DateTime(2026, 11, 2));
      final executor = ToolExecutor(
          config: cfg, disposition: CallerPolicy(cfg).classify('5555550100'), channel: 'call', host: host);
      await executor.run('flag_urgent', {'reason': 'flat tyre'});
      expect(host.notifications.single, contains('URGENT from Jordan Lee: flat tyre'));
    });
  });
}
