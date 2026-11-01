import 'package:android_ai_receptionist/src/call_summary.dart';
import 'package:android_ai_receptionist/src/contacts.dart';
import 'package:android_ai_receptionist/src/store.dart';
import 'package:android_ai_receptionist/src/tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final contacts = ContactBook.empty();
  final t = DateTime(2026, 1, 5, 9);
  ActivityEntry entry(String kind, Map<String, dynamic> data, [int minute = 0]) =>
      ActivityEntry(t.add(Duration(minutes: minute)), kind, data);
  List<Map<String, String>> said(String text) => [
        {'speaker': 'assistant', 'text': 'Hi, how can I help?'},
        {'speaker': 'caller', 'text': text},
      ];
  CallCategory categoryOf(ActivityEntry e, {List<TakenMessage> messages = const []}) =>
      summarizeActivity([e], contacts, messages: messages).single.category;

  test('a known caller or a left message is important', () {
    expect(categoryOf(entry('call_transcript', {'number': '+15555550100', 'workflow': 'known', 'lines': said('hey')})),
        CallCategory.important);
    expect(
        categoryOf(entry('call_transcript',
            {'number': '+15555550101', 'workflow': 'screen', 'message': 'Call the office', 'lines': said('hi')})),
        CallCategory.important);
  });

  test('older calls find their message by number and time', () {
    final message = TakenMessage(
        time: t.add(const Duration(minutes: 2)),
        number: '+15555550101',
        callerName: 'Pat',
        message: 'Please call me',
        callbackNumber: '+15555550101',
        channel: 'call',
        workflow: 'screen');
    final summary = summarizeActivity(
        [entry('call_transcript', {'number': '+15555550101', 'workflow': 'screen', 'lines': said('hi')})], contacts,
        messages: [message]).single;
    expect(summary.category, CallCategory.important);
    expect(summary.detail, 'Please call me');
  });

  test('silent or vague unknown callers are not important', () {
    expect(categoryOf(entry('call_transcript', {'number': '+15555550102', 'workflow': 'screen', 'lines': []})),
        CallCategory.other);
    expect(categoryOf(entry('sms_in', {'number': '+15555550102', 'workflow': 'screen', 'body': 'hello?'})),
        CallCategory.other);
  });

  test('urgent words make an unknown caller important', () {
    expect(
        categoryOf(entry('call_transcript',
            {'number': '+15555550103', 'workflow': 'screen', 'lines': said('it is urgent, please call back')})),
        CallCategory.important);
  });

  test('hung-up spam and pre-ring blocks are separated', () {
    expect(categoryOf(entry('call_transcript', {'number': '+15555550104', 'spam': true, 'lines': said('free cruise')})),
        CallCategory.spam);
    final both = summarizeActivity([
      entry('number_blocked', {'number': '+15555550105', 'reason': 'spam'}, 1),
      entry('call_transcript', {'number': '+15555550105', 'workflow': 'screen', 'lines': said('gift card')}),
    ], contacts);
    expect(both.single.category, CallCategory.spam);
    expect(categoryOf(entry('call_blocked', {'number': '+15555550106', 'reason': 'blocked list'})), CallCategory.blocked);
    expect(categoryOf(entry('call_screened', {'number': '+15555550106', 'workflow': 'block'})), CallCategory.blocked);
    expect(categoryOf(entry('sms_in', {'number': '+15555550106', 'workflow': 'block'})), CallCategory.blocked);
  });

  test('call-outs are important and technical entries are hidden', () {
    expect(categoryOf(entry('callout', {'number': '+15555550107', 'objective': 'book a haircut', 'outcome': 'booked'})),
        CallCategory.important);
    expect(summarizeActivity([entry('probe', {}), entry('call_screened', {'workflow': 'known'})], contacts), isEmpty);
  });

  test("the owner's own calls and texts, and assistant replies, appear with a direction", () {
    final items = summarizeActivity([
      entry('call_ended', {'number': '+15555550110', 'assistant': false, 'incoming': true, 'answered': false}),
      entry('call_ended', {'number': '+15555550111', 'assistant': false, 'incoming': false, 'answered': true, 'seconds': 125}),
      entry('call_ended', {'number': '+15555550112', 'assistant': true, 'incoming': true, 'answered': true}),
      entry('sms_sent', {'number': '+15555550113', 'body': 'On my way'}),
      entry('sms_out', {'number': '+15555550114', 'body': 'Sam is free at 3 PM.'}),
    ], contacts);
    expect(items.map((i) => i.detail), [
      'Missed call',
      'Outgoing call · 2 min',
      'On my way',
      'Assistant replied: Sam is free at 3 PM.',
    ]);
    expect(items.map((i) => i.outgoing), [false, true, true, true]);
    expect(items.first.category, CallCategory.other, reason: 'a missed call from an unknown number');
  });

  test('the detected intent is labelled by its kind', () {
    CallSummary one(Map<String, dynamic> extra) => summarizeActivity(
        [entry('call_transcript', {'number': '+15555550120', 'workflow': 'known', 'lines': said('hi'), ...extra})],
        contacts).single;
    expect(one({'topic': 'Plans', 'topic_kind': 'reason'}).topicLabel, 'About: Plans');
    expect(one({'topic': 'Wants to talk', 'topic_kind': 'vague'}).topicLabel, 'Intent: Wants to talk (not a reason)');
    expect(one({'topic': 'Sales', 'topic_kind': 'spam'}).topicLabel, 'Spam: Sales');
    expect(one({}).topicLabel, '');
  });
}
