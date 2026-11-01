import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent.dart';
import 'config.dart';
import 'native.dart';
import 'reply.dart';
import 'tiered.dart';

class TranscriptLine {
  TranscriptLine(this.speaker, this.text) : time = DateTime.now();
  final String speaker; // caller | assistant | system
  final String text;
  final DateTime time;

  Map<String, dynamic> toJson() => {'speaker': speaker, 'text': text, 'time': time.toIso8601String()};
}

/// A live spoken conversation: a real phone call, or speaker test mode using
/// the phone's own microphone and speaker. Half duplex: the microphone is
/// ignored natively while the receptionist is speaking.
class VoiceSession extends ChangeNotifier {
  VoiceSession({
    required this.api,
    required this.agent,
    required this.config,
    required this.onEnded,
    this.callId,
    this.bridged = false,
    this.tiered,
    this.outbound = false,
    this.onTransfer,
    this.onHandOff,
    this.greetingNote,
  }) : sessionId = 'voice-${DateTime.now().microsecondsSinceEpoch}';

  final NativeApi api;
  final Agent agent;
  final ReceptionistConfig config;
  final String? callId;
  final String sessionId;

  /// Audio flows through the shell call-audio helper (digital call path).
  final bool bridged;

  /// Small-model responder (inbound receptionist or outbound call-out).
  final TurnResponder? tiered;

  /// The assistant placed this call: listen first instead of greeting.
  final bool outbound;

  /// Added to the greeting: a message from the owner, or a question to ask.
  final String? greetingNote;

  /// Warm transfer: asks the owner to pick up; completes with whether they did.
  final Future<bool> Function(String callerSaid)? onTransfer;

  /// The owner picked up: the session has said its handover line and stopped.
  final Future<void> Function()? onHandOff;

  /// Waiting for the owner to answer a transfer request.
  bool _transferring = false;
  Timer? _silence;
  final void Function(VoiceSession session) onEnded;

  final List<TranscriptLine> lines = [];
  String state = 'starting';
  double? levelDb;
  bool finished = false;

  StreamSubscription<Map<String, dynamic>>? _events;
  final Set<String> _speaking = {};
  int _speechCounter = 0;
  bool _generating = false;
  bool _spokeThisStep = false;
  String? _activeInput;
  String? _queued;

  /// Input whose reply was cancelled because the caller continued speaking.
  String? _heldInput;
  Timer? _limit;

  /// Ends a call nobody is talking on: the caller went quiet or hung up badly.
  Timer? _idle;

  void _armIdle() {
    _idle?.cancel();
    if (!isCall || finished || _closing) return;
    _idle = Timer(Duration(seconds: outbound ? 30 : 15), () {
      if (finished || _closing || _generating || _transferring || _speaking.isNotEmpty) return;
      if (tiered?.waiting == true) return _armIdle(); // on hold: keep waiting
      unawaited(_finishWith(outbound
          ? "I'll have ${config.ownerName} follow up. Goodbye."
          : 'Thanks for calling. Goodbye.'));
    });
  }
  Completer<void>? _drained;

  bool get isCall => agent.channel == Channel.call;

  Future<void> start() async {
    _events = api.events.listen(_onEvent);
    final audio = config.callAudio;
    await api.setPlayback(
      usage: bridged ? 'call_bridge' : audio.speakerPlaybackUsage,
      gain: audio.gain,
    );
    if (outbound) {
      tiered?.start();
      // If nobody speaks after connecting, introduce ourselves anyway.
      _silence = Timer(const Duration(seconds: 4), () async {
        final turn = await tiered?.onSilence();
        if (turn != null && !finished) await _applyFast(turn, '');
      });
    } else {
      final greeting = withNote(agent.startCall(), greetingNote);
      tiered?.start(greeting: greeting);
      _add('assistant', greeting);
      _speak(greeting);
    }
    if (!outbound && (tiered == null || tiered!.escalateToLargeModel)) {
      unawaited(agent.prefill().catchError((Object e) => api.log('prefill failed: $e')));
    }
    await api.listenStart(
      sessionId,
      source: bridged ? 'call_bridge' : audio.speakerCaptureSource,
      endSilence: audio.endSilenceSeconds,
    );
    _limit = Timer(Duration(seconds: audio.maxCallSeconds), () {
      unawaited(_finishWith("I'm sorry, I have to end the call now. Goodbye."));
    });
  }

  void _add(String speaker, String text) {
    lines.add(TranscriptLine(speaker, text));
    if (kDebugMode) unawaited(api.log('voice $sessionId $state $speaker: $text'));
    notifyListeners();
  }

  void _setState(String value) {
    if (kDebugMode && value != state) unawaited(api.log('voice_state $sessionId $value'));
    state = value;
    notifyListeners();
  }

  void _speak(String text) {
    final clean = speakable(dropNumberQuestions(text));
    if (clean.isEmpty) return;
    final id = '$sessionId-${++_speechCounter}';
    _speaking.add(id);
    _spokeThisStep = true;
    state = 'speaking';
    notifyListeners();
    unawaited(api.speak(id, clean, config.voice));
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'];
    final session = event['session'];
    if (session != null && session != sessionId) return;
    switch (type) {
      case 'utterance':
        final text = (event['text'] ?? '').toString();
        if (finished || (_closing && event['final'] == true)) {
          // Heard as the line dropped: record it and let the responder act on it.
          if (text.trim().isEmpty) return;
          _add(isCall ? 'caller' : 'you', text);
          _late = tiered?.lateWords(text);
          return;
        }
        _onUtterance(text);
      case 'speech_start':
        _idle?.cancel();
        if (bridged && _speaking.isNotEmpty && !_closing) {
          _bargeIn();
        } else if (_generating && !_spokeThisStep) {
          // The caller kept talking: drop a reply that has not been spoken yet;
          // its input is merged with what they say next.
          agent.model.cancel();
        }
      case 'speech_discarded':
        if (_heldInput != null && !_generating) {
          final held = _heldInput!;
          _heldInput = null;
          unawaited(_run(held));
        }
      case 'level':
        levelDb = (event['peakDb'] as num?)?.toDouble();
        notifyListeners();
      case 'tts_done' || 'tts_error':
        final id = event['id'];
        if (_speaking.remove(id)) {
          if (type == 'tts_error') _add('system', 'Speech failed: ${event['message']}');
          if (_speaking.isEmpty) {
            if (!_generating) _setState('listening');
            _drained?.complete();
            _drained = null;
            _armIdle();
          }
        }
      case 'listen_error':
        _add('system', 'Microphone: ${event['message']}');
    }
  }

  /// The caller started talking over the receptionist (digital call path only,
  /// where the input never contains our own voice): stop speaking and listen.
  void _bargeIn() {
    if (kDebugMode) unawaited(api.log('voice $sessionId barge-in'));
    unawaited(api.stopSpeaking());
    _speaking.clear();
    _drained?.complete();
    _drained = null;
    if (_generating) agent.model.cancel();
    _setState('listening');
  }

  void _onUtterance(String text) {
    // Once the closing line is playing, nothing the other side says changes it.
    if (finished || _closing || text.trim().isEmpty) return;
    _idle?.cancel();
    if (_transferring) {
      _add(isCall ? 'caller' : 'you', text);
      return;
    }
    _add(isCall ? 'caller' : 'you', text);
    if (_generating) {
      _queued = _queued == null ? text : '$_queued $text';
      // Restart with the combined input if nothing has been spoken yet.
      if (!_spokeThisStep) agent.model.cancel();
      return;
    }
    final held = _heldInput;
    _heldInput = null;
    unawaited(_run(held == null ? text : '$held $text'));
  }

  Future<void> _run(String text) async {
    _generating = true;
    _spokeThisStep = false;
    _activeInput = text;
    _setState('thinking');
    final chunker = SentenceChunker();
    var cancelled = false;
    try {
      _silence?.cancel();
      final fast = await tiered?.handle(text);
      if (fast != null && !finished) {
        _generating = false;
        await _applyFast(fast, text);
        return;
      }
      final replies = await agent.respond(text, onSay: (delta) {
        for (final sentence in chunker.add(delta)) {
          _speak(sentence);
        }
      });
      final rest = chunker.flush();
      if (rest.isNotEmpty) _speak(rest);
      for (final reply in replies) {
        final said = dropNumberQuestions(reply.say);
        if (said.isNotEmpty) _add('assistant', said);
        if (reply.toolName != null) _add('system', 'Tool: ${reply.toolName}');
      }
    } on GenerationCancelled {
      cancelled = true;
    } catch (e) {
      _add('system', 'Error: $e');
      _speak("Sorry, I didn't catch that. Could you say it again?");
    } finally {
      _generating = false;
    }
    if (finished) return;
    final queued = _queued;
    _queued = null;
    if (queued != null) {
      unawaited(_run(cancelled ? '${_activeInput ?? ''} $queued'.trim() : queued));
      return;
    }
    if (cancelled) {
      // Wait for the rest of the caller's sentence, but never forever.
      final held = _activeInput;
      _heldInput = held;
      _setState('listening');
      Timer(const Duration(seconds: 4), () {
        if (!finished && !_generating && _heldInput == held && held != null) {
          _heldInput = null;
          unawaited(_run(held));
        }
      });
      return;
    }
    if (_speaking.isEmpty) _setState('listening');
    if (agent.ended) {
      if (agent.endedAsSpam) {
        await _endAfterSpeech();
      } else {
        // Only spam is hung up on; otherwise the caller ends the call.
        agent.ended = false;
      }
    }
  }

  /// Speaks a small-model turn, sends keypad tones, and ends or keeps the call.
  Future<void> _applyFast(FastTurn fast, String text) async {
    if (kDebugMode) unawaited(api.log('voice $sessionId fast label=${fast.label} ms=${fast.ms}'));
    if (text.isNotEmpty) agent.recordFastTurn(text, fast.say, tool: fast.tool, args: fast.args);
    if (fast.dtmf != null && callId != null) {
      unawaited(api.call('callDtmf', {'callId': callId, 'digit': fast.dtmf}));
      _add('system', 'Pressed ${fast.dtmf}');
    }
    if (fast.hangUp) _closing = true;
    if (fast.say.isNotEmpty) {
      _speak(fast.say);
      _add('assistant', fast.say);
    }
    if (fast.tool != null) _add('system', 'Tool: ${fast.tool} (fast path)');
    if (fast.transfer && onTransfer != null && tiered is TieredResponder) {
      _queued = null;
      unawaited(_transfer(tiered as TieredResponder, text));
      return;
    }
    if (_closing) _queued = null;
    if (_queued != null) {
      final queued = _queued!;
      _queued = null;
      unawaited(_run(queued));
      return;
    }
    if (_speaking.isEmpty) {
      _setState('listening');
      _armIdle();
    }
    // Spam, a finished conversation, and finished outbound calls hang up.
    if (fast.hangUp) await _endAfterSpeech();
  }

  /// Warm transfer: hold the caller while the owner decides, then hand the
  /// call over or carry on taking a message.
  Future<void> _transfer(TieredResponder responder, String callerSaid) async {
    _transferring = true;
    _idle?.cancel();
    await _waitForSpeech();
    // The owner sees everything the caller has said, not just the last line.
    final context = responder.callerContext;
    final picked = await onTransfer!(context.isEmpty ? callerSaid : context);
    _transferring = false;
    if (finished) return;
    if (picked) {
      _closing = true;
      final line = responder.transferConnected;
      _add('assistant', line);
      _speak(line);
      await _waitForSpeech();
      await onHandOff?.call();
      return;
    }
    await _applyFast(responder.transferDeclined(), '');
  }

  Future<void> _waitForSpeech() async {
    if (_speaking.isEmpty) return;
    _drained ??= Completer<void>();
    await _drained!.future.timeout(const Duration(seconds: 30), onTimeout: () {});
  }

  /// Set once the call is ending: the closing line is spoken in full even if
  /// the other side talks over it.
  bool _closing = false;

  /// Handling of words heard as the line dropped, awaited before [onEnded].
  Future<void>? _late;

  Future<void> _endAfterSpeech() async {
    _closing = true;
    await _waitForSpeech();
    await stop(hangUp: true);
  }

  Future<void> _finishWith(String goodbye) async {
    if (finished) return;
    agent.model.cancel();
    _add('assistant', goodbye);
    _closing = true;
    _speak(goodbye);
    await _endAfterSpeech();
  }

  /// Ends the session. [hangUp] disconnects the phone call too.
  Future<void> stop({bool hangUp = false, bool silenceNow = false}) async {
    if (finished) return;
    finished = true;
    _limit?.cancel();
    _silence?.cancel();
    _idle?.cancel();
    if (_generating) agent.model.cancel();
    if (silenceNow) await api.stopSpeaking();
    await api.listenStop();
    // listenStop returns after any final words were delivered; let them land.
    await (_late ?? Future.value()).timeout(const Duration(seconds: 5), onTimeout: () {});
    if (bridged) await api.setPlayback(usage: config.callAudio.speakerPlaybackUsage);
    if (hangUp && callId != null) await api.call('callHangup', {'callId': callId});
    await _events?.cancel();
    _setState('ended');
    onEnded(this);
  }
}

/// Puts an owner's note into the greeting: a statement goes before the closing
/// "How can I help?"; a question replaces it, so the caller answers it first.
String withNote(String greeting, String? note) {
  final text = note?.trim() ?? '';
  if (text.isEmpty) return greeting;
  final match = RegExp(r'^(.*[.!])\s*([^.!?]*\?)\s*$').firstMatch(greeting.trim());
  final opening = match?.group(1) ?? greeting.trim();
  final closing = match?.group(2) ?? '';
  if (text.endsWith('?')) return '$opening $text';
  return closing.isEmpty ? '$opening $text' : '$opening $text $closing';
}
