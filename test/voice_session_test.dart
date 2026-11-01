import 'dart:async';
import 'dart:math' as math;

import 'package:android_ai_receptionist/src/agent.dart';
import 'package:android_ai_receptionist/src/config.dart';
import 'package:android_ai_receptionist/src/decision.dart';
import 'package:android_ai_receptionist/src/policy.dart';
import 'package:android_ai_receptionist/src/tiered.dart';
import 'package:android_ai_receptionist/src/voice_session.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_native.dart';

late FakeNative native;

class _Backend implements DecisionBackend {
  _Backend(this.answers);
  final Map<String, String> answers;

  String _label(String prompt) =>
      answers.entries.firstWhere((e) => prompt.contains(e.key), orElse: () => const MapEntry('', 'other')).value;

  @override
  Future<(List<double>, int)> score(RenderedPrompt prompt, List<String> options) async {
    final label = _label(prompt.text);
    return ([for (final o in options) o == label ? math.log(0.97) : math.log(0.03 / options.length)], 5);
  }

  @override
  Future<String> extract(RenderedPrompt prompt, String grammar) async => '{}';
}

/// A bridged inbound call from a known contact ([number]) or a stranger.
VoiceSession _session({
  String number = '+15555550123',
  Map<String, String> answers = const {},
  bool offerTransfer = false,
  Future<bool> Function(String said)? onTransfer,
}) {
  final cfg = ReceptionistConfig.fromJson({
    'owner_name': 'Sam',
    'contacts': [
      {'name': 'Jordan Lee', 'numbers': ['+15555550100']},
    ],
  });
  final agent = Agent(
      config: cfg,
      disposition: CallerPolicy(cfg).classify(number),
      channel: Channel.call,
      model: NoModel(),
      host: StubHost());
  final responder = TieredResponder(
      router: DecisionRouter(_Backend(answers), PromptFormat.chatml, style: DecisionStyle.context),
      agent: agent,
      phrases: WorkflowPhrases.defaults,
      ownerName: 'Sam')
    ..offerTransfer = offerTransfer;
  return VoiceSession(
    api: native.api,
    agent: agent,
    config: cfg,
    callId: 'call-1',
    bridged: true,
    tiered: responder,
    onTransfer: onTransfer,
    onEnded: (_) {},
  );
}

void main() {
  setUp(() => native = FakeNative());

  /// Runs [body] on a fake clock; `async.elapse` moves time forward.
  void onClock(void Function(FakeAsync async) body) => fakeAsync((async) {
        body(async);
        async.flushMicrotasks();
      });

  void event(VoiceSession session, Map<String, dynamic> e) => native.emit({...e, 'session': session.sessionId});

  VoiceSession started(FakeAsync async, VoiceSession session) {
    unawaited(session.start());
    async.flushMicrotasks();
    return session;
  }

  void end(FakeAsync async, VoiceSession session) {
    unawaited(session.stop());
    async.elapse(const Duration(seconds: 1));
  }

  test('noise that interrupts the assistant does not leave the line silent', () => onClock((async) {
        final session = started(async, _session());
        final greeting = native.spoken.single;
        event(session, {'type': 'speech_start'});
        async.flushMicrotasks();
        expect(native.log, contains('stopSpeaking'), reason: 'barge-in stops the greeting');
        event(session, {'type': 'speech_discarded', 'audioMs': 300});
        async.flushMicrotasks();
        expect(native.spoken, [greeting, greeting], reason: 'the cut-off sentence is said again');
        end(async, session);
      }));

  test('the assistant never resumes over a caller who is still talking', () => onClock((async) {
        final session = started(async, _session());
        event(session, {'type': 'speech_start'});
        async.elapse(const Duration(seconds: 12));
        expect(native.spoken, hasLength(1), reason: 'a long sentence is still being spoken or transcribed');
        event(session, {'type': 'utterance', 'text': 'Okay.'});
        async.flushMicrotasks();
        expect(native.spoken, hasLength(2));
        end(async, session);
      }));

  test('a reply that finishes after the call ended is never spoken', () => onClock((async) {
        final session = started(async, _session());
        native.finishSpeaking();
        unawaited(session.stop());
        async.flushMicrotasks();
        final before = native.spoken.length;
        event(session, {'type': 'utterance', 'text': 'Can I leave a message?'});
        async.elapse(const Duration(seconds: 5));
        expect(native.spoken, hasLength(before));
      }));

  test('"okay" over the assistant finishes the sentence instead of starting a turn', () => onClock((async) {
        final session = started(async, _session());
        final greeting = native.spoken.single;
        event(session, {'type': 'speech_start'});
        event(session, {'type': 'utterance', 'text': 'Okay, okay.'});
        async.flushMicrotasks();
        expect(native.spoken, [greeting, greeting]);
        end(async, session);
      }));

  test('a real answer after a barge-in gets a reply, not a repeat', () => onClock((async) {
        final session = started(async, _session(answers: {'leave a message': 'message'}));
        event(session, {'type': 'speech_start'});
        event(session, {'type': 'utterance', 'text': 'Can I leave a message?'});
        async.flushMicrotasks();
        expect(native.spoken.last, 'Of course. What would you like me to tell Sam?');
        expect(native.spoken, hasLength(2));
        end(async, session);
      }));

  test("speech that could not be made out gets \"didn't catch that\"", () => onClock((async) {
        final session = started(async, _session());
        native.finishSpeaking();
        event(session, {'type': 'speech_start'});
        event(session, {'type': 'speech_discarded', 'audioMs': 2000});
        async.flushMicrotasks();
        expect(native.spoken.last, "Sorry, I didn't catch that. Could you say it again?");
        end(async, session);
      }));

  test('a quiet line gets a check-in before the call is ended', () => onClock((async) {
        started(async, _session());
        native.finishSpeaking();
        async.elapse(const Duration(seconds: 8, milliseconds: 100));
        expect(native.spoken.last, 'Are you still there?');
        expect(native.log, isNot(contains('callHangup call-1')));
        native.finishSpeaking();
        async.elapse(const Duration(seconds: 10, milliseconds: 100));
        expect(native.spoken.last, 'Thanks for calling. Goodbye.');
        native.finishSpeaking();
        async.elapse(const Duration(seconds: 6));
        expect(native.log, contains('callHangup call-1'));
      }));

  test('the caller hears hold updates while the owner decides', () => onClock((async) {
        final owner = Completer<bool>();
        final session = started(
            async,
            _session(
              number: '+15555550100',
              answers: {'free tomorrow': 'availability'},
              offerTransfer: true,
              onTransfer: (_) => owner.future,
            ));
        native.finishSpeaking();
        event(session, {'type': 'utterance', 'text': 'Is Sam free tomorrow afternoon?'});
        async.flushMicrotasks();
        expect(native.spoken.last, 'One moment, let me see if Sam can pick up.');
        native.finishSpeaking();
        async.flushMicrotasks();
        // Music plays between the updates.
        expect(native.log, contains('holdMusic true'));
        async.elapse(const Duration(seconds: 12, milliseconds: 100));
        expect(native.spoken.last, 'Still trying Sam. Thanks for holding.');
        native.finishSpeaking();
        // A "hello?" on hold is answered too (but not within 5 s of the last update).
        async.elapse(const Duration(seconds: 5));
        event(session, {'type': 'utterance', 'text': 'Hello?'});
        async.flushMicrotasks();
        expect(native.spoken.where((s) => s.startsWith('Still trying')), hasLength(2));
        native.finishSpeaking();
        owner.complete(false);
        async.flushMicrotasks();
        // The music stops before the assistant takes a message.
        expect(native.log.lastIndexOf('holdMusic false'), greaterThan(native.log.lastIndexOf('holdMusic true')));
        expect(native.log.lastIndexOf('holdMusic false'), lessThan(native.log.lastIndexOf('speak')));
        expect(native.spoken.last, "Sam can't come to the phone right now. Would you like to leave a message?");
        end(async, session);
      }));
}
