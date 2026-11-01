import 'dart:async';

import 'package:android_ai_receptionist/src/calendar.dart';
import 'package:android_ai_receptionist/src/contacts.dart';
import 'package:android_ai_receptionist/src/agent.dart';
import 'package:android_ai_receptionist/src/tools.dart';
import 'package:android_ai_receptionist/src/native.dart';

/// Stands in for the Android side of the app: records every method call and
/// lets a test push native events (call states, speech, playback).
class FakeNative {
  final calls = <(String, Map<String, dynamic>)>[];
  final status = <String, dynamic>{'callAudioHelper': true};
  final _events = StreamController<Map<String, dynamic>>.broadcast(sync: true);

  late final api = NativeApi.fake(
    // Cancelling must complete on the fake clock: a broadcast controller's
    // cancel future belongs to the root zone, which fake_async never runs.
    events: Stream.multi((listener) {
      final subscription = _events.stream.listen(listener.add);
      listener.onCancel = () {
        subscription.cancel();
        return Future<void>.value();
      };
    }, isBroadcast: true),
    handler: (method, args) async {
      calls.add((method, args));
      return method == 'status' ? status : null;
    },
  );

  void emit(Map<String, dynamic> event) => _events.add(event);

  /// Method names in call order, with their callId if any: "callAnswer call-2".
  List<String> get log => [for (final (m, a) in calls) [m, if (a['callId'] != null) a['callId'], if (a['on'] != null) a['on']].join(' ')];

  List<String> get spoken => [for (final (m, a) in calls) if (m == 'speak') a['text'].toString()];

  /// Finishes playback of everything spoken so far.
  void finishSpeaking() {
    for (final (m, a) in calls.toList()) {
      if (m == 'speak') emit({'type': 'tts_done', 'id': a['id']});
    }
  }
}

class StubHost implements ToolHost {
  final messages = <TakenMessage>[];
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
  Future<void> record(String kind, Map<String, dynamic> data) async {}
  @override
  Future<void> saveMessage(TakenMessage message) async => messages.add(message);
  @override
  Future<void> updateContact(String number, void Function(TrackedContact contact) change) async =>
      change(book.touch(number));
  @override
  Future<void> blockNumber(String number, String reason) async {}
}

class NoModel implements LanguageModel {
  @override
  Future<String> generate(String prompt,
          {required String grammar, int maxTokens = 160, double temperature = 0.4, void Function(String)? onToken}) =>
      throw StateError('the large model is not used');
  @override
  Future<void> prefill(String prompt) async {}
  @override
  void cancel() {}
}
