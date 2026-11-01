import 'dart:math' as math;

import 'package:android_ai_receptionist/src/agent.dart';
import 'package:android_ai_receptionist/src/calendar.dart';
import 'package:android_ai_receptionist/src/config.dart';
import 'package:android_ai_receptionist/src/contacts.dart';
import 'package:android_ai_receptionist/src/decision.dart';
import 'package:android_ai_receptionist/src/outbound.dart';
import 'package:android_ai_receptionist/src/policy.dart';
import 'package:android_ai_receptionist/src/tools.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements DecisionBackend {
  _Backend(this.answers);
  final Map<String, (String, String)> answers;

  (String, String) _match(String prompt) {
    final latest = prompt.split('Other: ').last;
    for (final e in answers.entries) {
      if (latest.contains(e.key)) return e.value;
    }
    return ('other', '{}');
  }

  @override
  Future<(List<double>, int)> score(RenderedPrompt prompt, List<String> options) async {
    final (label, _) = _match(prompt.text);
    return ([for (final o in options) math.log(o == label ? 0.95 : 0.05 / options.length)], 4);
  }

  @override
  Future<String> extract(RenderedPrompt prompt, String grammar) async => _match(prompt.text).$2;
}

class _Host implements ToolHost {
  final calendarData = CalendarData.defaults();
  @override
  DateTime now() => DateTime(2026, 11, 2, 9, 30); // Monday
  @override
  Future<List<CalendarEvent>> calendar(DateTime start, DateTime end) async => [
        CalendarEvent(DateTime(2026, 11, 6, 13), DateTime(2026, 11, 6, 15), 'Busy'),
      ];
  @override
  Future<(DateTime, DateTime)?> workingHours(DateTime day) async => calendarData.hoursFor(day);
  @override
  Future<void> notifyOwner(String title, String body, {bool urgent = false}) async {}
  @override
  Future<void> record(String kind, Map<String, dynamic> data) async {}
  @override
  Future<void> saveMessage(TakenMessage message) async {}
  @override
  Future<void> updateContact(String number, void Function(TrackedContact contact) change) async {}
  @override
  Future<void> blockNumber(String number, String reason) async {}
}

class _NoModel implements LanguageModel {
  @override
  Future<String> generate(String prompt,
          {required String grammar, int maxTokens = 160, double temperature = 0.4, void Function(String)? onToken}) =>
      throw StateError('no Gemma');
  @override
  Future<void> prefill(String prompt) async {}
  @override
  void cancel() {}
}

(OutboundResponder, List<DateTime>) _responder(Map<String, (String, String)> answers) {
  final cfg = ReceptionistConfig.fromJson({'owner_name': 'Sam'});
  final agent = Agent(config: cfg, disposition: CallerPolicy(cfg).classify('+15555550170'),
      channel: Channel.call, model: _NoModel(), host: _Host());
  final booked = <DateTime>[];
  final responder = OutboundResponder(
    router: DecisionRouter(_Backend(answers), PromptFormat.chatml, style: DecisionStyle.context),
    agent: agent,
    task: OutboundTask(id: '1', number: '+15555550170', objective: 'book a haircut on Friday afternoon'),
    ownerName: 'Sam',
    assistantName: "Sam's AI Assistant",
    onBooked: (start, _) async => booked.add(start),
  )..start();
  return (responder, booked);
}

void main() {
  test('phone menu picks the option that matches the objective', () {
    const menu = 'Thank you for calling Valley Medical. For billing, press 2. For appointments, press 1. '
        'For all other inquiries, press 0.';
    expect(chooseMenuDigit(menu, 'schedule a dental cleaning appointment'), '1');
    expect(chooseMenuDigit(menu, 'reach the billing department about invoice 1234'), '2');
    expect(chooseMenuDigit(menu, 'ask about parking'), '0');
    expect(chooseMenuDigit('press one for english para espanol oprima el dos', 'book a haircut'), '1');
    expect(chooseMenuDigit('Hello, this is Kim.', 'book a haircut'), isNull);
  });

  test('a live answer gets an introduction, then a time is negotiated and booked', () async {
    final (r, booked) = _responder({
      'Shear Style': ('person', '{}'),
      'Friday at 2': ('offer_time', '{"day": "Friday", "time": "2pm"}'),
      'Friday at 4': ('offer_time', '{"day": "Friday", "time": "4pm"}'),
      'all set': ('confirm', '{}'),
    });
    final intro = await r.handle('Thanks for calling Shear Style, this is Kim.');
    expect(intro!.say, "Hi, this is Sam's AI Assistant calling on behalf of Sam. I'm calling to book a haircut on Friday afternoon.");
    final busy = await r.handle('We have Friday at 2.');
    expect(busy!.say, startsWith("That time doesn't work for Sam."));
    final ok = await r.handle('How about Friday at 4?');
    expect(ok!.say, 'Friday at 4 PM works for Sam. Could you book that, please?');
    final done = await r.handle("You're all set.");
    expect(done!.hangUp, isTrue);
    expect(booked.single, DateTime(2026, 11, 6, 16));
    expect(r.task.outcome, 'booked Friday at 4 PM');
  });

  test('voicemail gets a message and the call ends; hold stays silent', () async {
    final (vm, _) = _responder({'leave a message': ('voicemail', '{}')});
    final left = await vm.handle("You've reached Dana, leave a message after the tone.");
    expect(left!.say, contains('Please call Sam back at this number'));
    expect(left.hangUp, isTrue);
    final (hold, _) = _responder({'Please hold': ('hold', '{}')});
    final waiting = await hold.handle('Please hold, your call is important to us.');
    expect(waiting!.say, isEmpty);
    expect(waiting.hangUp, isFalse);
    expect(hold.task.status, 'on hold');
  });

  test('a phone menu is answered with a keypad tone', () async {
    final (r, _) = _responder({'press': ('menu', '{}')});
    final turn = await r.handle('For appointments press 1, for billing press 2.');
    expect(turn!.dtmf, '1');
    expect(turn.say, isEmpty);
  });

  test('a name request after agreeing a time is answered, then the booking completes', () async {
    final (r, booked) = _responder({
      'Kim': ('person', '{}'),
      '11 AM on Friday': ('offer_time', '{"day": "Friday", "time": "11am"}'),
      'last name': ('offer_time', '{"day": "", "time": ""}'),
      'booked': ('confirm', '{}'),
    });
    await r.handle('Thanks for calling, this is Kim.');
    final ok = await r.handle('Would 11 AM on Friday work instead?');
    expect(ok!.say, 'Friday at 11 AM works for Sam. Could you book that, please?');
    final info = await r.handle("Great. Can I have Sam's last name to confirm the booking?");
    expect(info!.say, "It's under the name Sam, and the best number to reach Sam is this one. That's for Friday at 11 AM.");
    final done = await r.handle("Perfect, you're booked.");
    expect(done!.hangUp, isTrue);
    expect(booked.single, DateTime(2026, 11, 6, 11));
  });

  test('three offers that do not fit end the call with a promise to call back', () async {
    final (r, booked) = _responder({
      'Kim': ('person', '{}'),
      'Friday at 2': ('offer_time', '{"day": "Friday", "time": "2pm"}'),
    });
    await r.handle('Thanks for calling, this is Kim.');
    expect((await r.handle('We have Friday at 2.'))!.hangUp, isFalse);
    expect((await r.handle('Only Friday at 2, sorry.'))!.hangUp, isFalse);
    final last = await r.handle('Really, just Friday at 2.');
    expect(last!.hangUp, isTrue);
    expect(last.say, contains("I'll have Sam call back"));
    expect(r.task.outcome, 'no matching time');
    expect(booked, isEmpty);
  });

  test('a confirmation heard as the line drops still books the agreed time', () async {
    final (r, booked) = _responder({
      'Kim': ('person', '{}'),
      '11 AM on Friday': ('offer_time', '{"day": "Friday", "time": "11am"}'),
    });
    await r.handle('Thanks for calling, this is Kim.');
    await r.handle('Would 11 AM on Friday work instead?');
    await r.lateWords('Thank you. Your haircut is booked for Friday at 11 AM. Have a great day.');
    expect(booked.single, DateTime(2026, 11, 6, 11));
    expect(r.task.outcome, 'booked Friday at 11 AM');
    final (other, none) = _responder({'Kim': ('person', '{}')});
    await other.handle('Thanks for calling, this is Kim.');
    await other.lateWords('Your haircut is booked.');
    expect(outboundOverride('outbound', 'Thank you, Sam. Um, I booked your haircut for Friday at 11 AM.', 'other'),
        'confirm');
    expect(none, isEmpty, reason: 'nothing was agreed');
  });

  test('a list of times is searched for one that fits', () async {
    final (r, _) = _responder({
      'Kim': ('person', '{}'),
      'openings': ('offer_time', '{"day": "Friday", "time": "2 30 PM"}'),
    });
    await r.handle('Thanks for calling, this is Kim.');
    // Friday 1-3 PM is busy in the test calendar, so 2:30 is skipped and 4 PM is the first fit.
    final turn = await r.handle('We have openings Friday at 2 30 PM, 4 PM, or 11 AM.');
    expect(turn!.say, 'Friday at 4 PM works for Sam. Could you book that, please?');
    expect(parseTime('2 30 pm', DateTime(2026, 11, 6)), DateTime(2026, 11, 6, 14, 30));
    expect(parseTime('November 6 2026 at 3', DateTime(2026, 11, 6))!.minute, 0);
    expect(spokenTimes('Friday at 2 30 PM, 4 PM, or noon'), ['2 30 PM', '4 PM', '12 pm']);
  });

  test('a short acknowledgement is not taken as the booking', () async {
    final (r, booked) = _responder({
      'Kim': ('person', '{}'),
      '11 AM on Friday': ('offer_time', '{"day": "Friday", "time": "11am"}'),
      'Great.': ('confirm', '{}'),
    });
    await r.handle('Thanks for calling, this is Kim.');
    await r.handle('Would 11 AM on Friday work instead?');
    final ack = await r.handle('Great.');
    expect(ack!.say, isEmpty);
    expect(ack.hangUp, isFalse);
    expect(booked, isEmpty);
  });
}
