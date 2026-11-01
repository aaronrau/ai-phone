import 'dart:async';

import 'package:android_ai_receptionist/src/config.dart';
import 'package:android_ai_receptionist/src/runtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_native.dart';

/// Two calls at once: the assistant holds one conversation at a time, and a
/// call that rings meanwhile is never answered over the call in progress.
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

  test('a second call rings while the assistant talks, and is answered when the line frees', () => onClock((async) {
        ring(async, 'call-1');
        expect(answered(), ['call-1']);
        state(async, 'call-1', 'active');
        expect(runtime.session?.callId, 'call-1');

        ring(async, 'call-2', number: '+15555550124');
        expect(answered(), ['call-1'], reason: 'answering would put the first caller on hold');
        expect(runtime.calls['call-2']!.waiting, isTrue);
        expect(runtime.session?.callId, 'call-1', reason: 'the first conversation keeps going');

        state(async, 'call-1', 'disconnected');
        runtime.handleEvent({'type': 'call_removed', 'callId': 'call-1'});
        async.elapse(const Duration(seconds: 1));
        expect(answered(), ['call-1', 'call-2']);
        state(async, 'call-2', 'active');
        expect(runtime.session?.callId, 'call-2');
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
