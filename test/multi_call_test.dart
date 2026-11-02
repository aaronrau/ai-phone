import 'dart:async';

import 'package:android_ai_receptionist/src/config.dart';
import 'package:android_ai_receptionist/src/runtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_native.dart';

/// Two calls at once: the assistant handles call waiting like a receptionist,
/// and never answers over a call the owner is on.
void main() {
  late FakeNative native;
  late ReceptionistRuntime runtime;

  setUp(() {
    native = FakeNative();
    runtime = ReceptionistRuntime(native.api)
      ..config = ReceptionistConfig.fromJson({'owner_name': 'Sam'})
      ..modelsReady = true
      ..decisionReady = true;
  });

  void onClock(void Function(FakeAsync async) body) => fakeAsync((async) {
        body(async);
        // Let session shutdown and the delayed volume restore finish.
        async.elapse(const Duration(seconds: 10));
      });

  void ring(FakeAsync async, String id, {String number = '+15555550123'}) {
    runtime.handleEvent({'type': 'call_added', 'callId': id, 'number': number, 'state': 'ringing', 'incoming': true});
    async.elapse(const Duration(milliseconds: 100));
  }

  void state(FakeAsync async, String id, String value) {
    runtime.handleEvent({'type': 'call_state', 'callId': id, 'state': value});
    async.elapse(const Duration(seconds: 1));
  }

  List<String> answered() => [for (final l in native.log) if (l.startsWith('callAnswer ')) l.split(' ').last];

  test('call waiting: the assistant holds its caller, answers the new call, then comes back', () => onClock((async) {
        ring(async, 'call-1');
        expect(answered(), ['call-1']);
        state(async, 'call-1', 'active');
        final first = runtime.session!;
        expect(first.callId, 'call-1');
        native.finishSpeaking(); // the greeting
        async.elapse(const Duration(seconds: 1));

        ring(async, 'call-2', number: '+15555550124');
        // The first caller hears why before going on hold, in full even if
        // they answer over it.
        expect(native.spoken.last, 'Sorry, another call is coming in. Please hold for a moment.');
        native.emit({'type': 'speech_start', 'session': first.sessionId});
        async.flushMicrotasks();
        expect(native.log, isNot(contains('stopSpeaking')));
        expect(answered(), ['call-1'], reason: 'not until the first caller has been told');
        native.finishSpeaking();
        async.elapse(const Duration(seconds: 1));
        final log = native.log;
        expect(log.lastIndexOf('callHold call-1'), lessThan(log.lastIndexOf('callAnswer call-2')));
        expect(log.lastIndexOf('listenStop'), lessThan(log.lastIndexOf('callAnswer call-2')));
        expect(answered(), ['call-1', 'call-2']);
        expect(runtime.heldSession, same(first));

        state(async, 'call-1', 'holding');
        expect(runtime.calls['call-1']!.aiHandled, isTrue, reason: 'held by the assistant, not given to the owner');
        state(async, 'call-2', 'active');
        expect(runtime.session?.callId, 'call-2');
        expect(native.spoken.last, contains("Sam's"));
        native.finishSpeaking();

        // The second caller hangs up: back to the first.
        state(async, 'call-2', 'disconnected');
        runtime.handleEvent({'type': 'call_removed', 'callId': 'call-2'});
        async.elapse(const Duration(milliseconds: 100));
        expect(native.log, contains('callUnhold call-1'));
        state(async, 'call-1', 'active');
        async.elapse(const Duration(seconds: 1));
        expect(runtime.session, same(first));
        // Back with the question the caller had not answered yet.
        expect(native.spoken.last, 'Thanks for holding. How can I help?');
        expect(native.log.where((l) => l == 'callMute false'), isEmpty, reason: 'the room never reaches a caller');
        state(async, 'call-1', 'disconnected');
      }));

  test('a caller who hangs up on hold ends quietly, the other call goes on', () => onClock((async) {
        ring(async, 'call-1');
        state(async, 'call-1', 'active');
        native.finishSpeaking();
        ring(async, 'call-2', number: '+15555550124');
        native.finishSpeaking();
        async.elapse(const Duration(seconds: 1));
        state(async, 'call-1', 'holding');
        state(async, 'call-2', 'active');
        final second = runtime.session!;
        native.calls.clear();
        state(async, 'call-1', 'disconnected');
        runtime.handleEvent({'type': 'call_removed', 'callId': 'call-1'});
        async.elapse(const Duration(seconds: 1));
        expect(runtime.heldSession, isNull);
        expect(runtime.session, same(second));
        expect(native.log, isNot(contains('listenStop')), reason: 'the second call keeps listening');
        state(async, 'call-2', 'disconnected');
      }));

  test('a call ringing while the owner is on the phone is left to the owner', () => onClock((async) {
        runtime.handleEvent(
            {'type': 'call_added', 'callId': 'call-1', 'number': '+15555550100', 'state': 'dialing', 'incoming': false});
        state(async, 'call-1', 'active');
        ring(async, 'call-2');
        expect(answered(), isEmpty);
        expect(runtime.session, isNull);
        state(async, 'call-2', 'disconnected');
        state(async, 'call-1', 'disconnected');
      }));

  test('answering a second call holds the assistant call and gives it to the owner first', () => onClock((async) {
        ring(async, 'call-1');
        state(async, 'call-1', 'active');
        ring(async, 'call-2', number: '+15555550124');
        native.calls.clear();

        unawaited(runtime.answerCall('call-2'));
        async.elapse(const Duration(seconds: 4));
        final log = native.log;
        expect(log.indexOf('callHold call-1'), greaterThanOrEqualTo(0));
        expect(log.indexOf('callHold call-1'), lessThan(log.indexOf('callAnswer call-2')));
        expect(log.indexOf('listenStop'), lessThan(log.indexOf('callAnswer call-2')),
            reason: 'the assistant stops listening before the owner is connected');
        expect(log, contains('callMute false'));
        expect(log, contains('callQuiet false'));
        expect(runtime.session, isNull);
        expect(runtime.calls['call-1']!.aiHandled, isFalse);

        state(async, 'call-1', 'holding');
        state(async, 'call-2', 'active');
        expect(runtime.session, isNull, reason: 'neither call is the assistant\'s now');
        state(async, 'call-2', 'disconnected');
        state(async, 'call-1', 'disconnected');
      }));

  test('a screened call arriving during another call rings as call waiting', () => onClock((async) {
        ring(async, 'call-1');
        state(async, 'call-1', 'active');
        runtime.handleEvent({'type': 'screen_call', 'number': '+15555550124', 'requestId': 7});
        async.elapse(const Duration(milliseconds: 100));
        final decision = native.calls.lastWhere((c) => c.$1 == 'screenDecision').$2['decision'];
        expect(decision, 'allow');
        state(async, 'call-1', 'disconnected');
      }));
}
