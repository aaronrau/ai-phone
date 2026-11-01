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
    this.maxSeconds,
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

  /// Overrides the configured call length limit (e.g. while another caller
  /// waits on hold).
  final int? maxSeconds;

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

  /// Asked "Are you still there?" since the caller last spoke.
  bool _checkedIn = false;

  void _armIdle() {
    _idle?.cancel();
    if (!isCall || finished || _closing) return;
    // Inbound: check in after a short silence (the caller may be waiting on
    // us, e.g. after speech we could not make out), then end the call.
    final checkIn = !outbound && !_checkedIn;
    _idle = Timer(Duration(seconds: outbound ? 30 : (checkIn ? 8 : 10)), () {
      if (finished || _closing || _generating || _transferring || _speaking.isNotEmpty) return;
      if (tiered?.waiting == true) return _armIdle(); // on hold: keep waiting
      if (checkIn) {
        _checkedIn = true;
        _say('Are you still there?'); // re-arms when spoken
        return;
      }
      unawaited(_finishWith(outbound
          ? "I'll have ${config.ownerName} follow up. Goodbye."
          : 'Thanks for calling. Goodbye.'));
    });
  }

  /// Text of each sentence still being spoken, by speech id.
  final Map<String, String> _speechText = {};

  /// What a barge-in cut off. Spoken again if the "interruption" was noise or
  /// a backchannel ("okay", "mm-hmm"), so neither side waits on the other.
  String? _interrupted;
  Timer? _resumeTimer;

  /// "Sorry, I didn't catch that" replies so far (bounded: line noise).
  int _notCaught = 0;

  /// Hold updates while the owner decides on a warm transfer.
  Timer? _holdTimer;

  /// Running for 5 s after each hold update, so updates never pile up.
  Timer? _holdSpacing;

  void _say(String line) {
    _add('assistant', line);
    _speak(line);
  }
  Completer<void>? _drained;

  bool get isCall => agent.channel == Channel.call;

  DateTime? _startedAt;

  Future<void> start() async {
    _startedAt = DateTime.now();
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
    _armLimit(maxSeconds ?? audio.maxCallSeconds);
  }

  void _armLimit(int seconds) {
    _limit?.cancel();
    _limit = Timer(Duration(seconds: seconds), () {
      unawaited(_finishWith(maxSeconds != null
          ? "I'm sorry, I have to get back to another caller. ${config.ownerName} will follow up. Goodbye."
          : "I'm sorry, I have to end the call now. Goodbye."));
    });
  }

  /// On hold while the assistant answers another call (call waiting).
  bool get paused => _paused;
  bool _paused = false;
  DateTime? _pausedAt;

  /// A conversation that can step away for another call: not in the middle
  /// of a transfer or closing, and not a call the assistant placed.
  bool get canPause => !finished && !_closing && !_transferring && !_paused && !outbound && isCall;

  /// Call waiting: finish the current sentence, tell the caller about the
  /// other call, then stop listening so the call can go on hold.
  Future<void> pause() async {
    if (!canPause) return;
    _idle?.cancel();
    _resumeTimer?.cancel();
    _interrupted = null;
    if (_generating) agent.model.cancel();
    await _waitForSpeech(const Duration(seconds: 6));
    _say('Sorry, another call is coming in. Please hold for a moment.');
    await _waitForSpeech(const Duration(seconds: 10));
    _paused = true;
    _pausedAt = DateTime.now();
    _limit?.cancel();
    _idle?.cancel();
    if (_musicOn) await _music(false);
    await api.stopSpeaking();
    _speaking.clear();
    await api.listenStop();
    _setState('on hold');
  }

  /// Back from the other call: thank the caller and repeat our last question,
  /// so the conversation picks up where it left off.
  Future<void> resume() async {
    if (!_paused || finished) return;
    _paused = false;
    final audio = config.callAudio;
    await api.setPlayback(usage: bridged ? 'call_bridge' : audio.speakerPlaybackUsage, gain: audio.gain);
    await api.listenStart(
      sessionId,
      source: bridged ? 'call_bridge' : audio.speakerCaptureSource,
      endSilence: audio.endSilenceSeconds,
    );
    // The time on hold does not count toward the call length limit.
    final used = _startedAt == null ? 0 : _pausedAt!.difference(_startedAt!).inSeconds;
    _armLimit(((maxSeconds ?? audio.maxCallSeconds) - used).clamp(30, 1 << 20).toInt());
    final last = lines.lastWhere((l) => l.speaker == 'assistant' && !l.text.startsWith('Sorry, another call'),
        orElse: () => TranscriptLine('assistant', ''));
    final question = RegExp(r'[^.!?]*\?\s*$').firstMatch(last.text)?.group(0)?.trim();
    _say(question == null || question.isEmpty ? 'Thanks for holding.' : 'Thanks for holding. $question');
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
    // A reply that finished after the call ended must never play: the phone's
    // own speaker would say it out loud.
    if (finished) return;
    final clean = speakable(dropNumberQuestions(text));
    if (clean.isEmpty) return;
    final id = '$sessionId-${++_speechCounter}';
    _speaking.add(id);
    _speechText[id] = clean;
    _spokeThisStep = true;
    state = 'speaking';
    notifyListeners();
    unawaited(api.speak(id, clean, config.voice));
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'];
    final session = event['session'];
    if (session != null && session != sessionId) return;
    // On hold: the audio and speech events belong to the other call.
    if (_paused) return;
    switch (type) {
      case 'utterance':
        _hearing = false;
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
        _hearing = true;
        _idle?.cancel();
        if (bridged && _speaking.isNotEmpty && !_closing) {
          _bargeIn();
        } else if (_generating && !_spokeThisStep) {
          // The caller kept talking: drop a reply that has not been spoken yet;
          // its input is merged with what they say next.
          agent.model.cancel();
        }
      case 'speech_discarded':
        _hearing = false;
        if (finished) return;
        if (_heldInput != null && !_generating) {
          final held = _heldInput!;
          _heldInput = null;
          unawaited(_run(held));
        } else if (_interrupted != null) {
          _resumeInterrupted('noise');
        } else if (((event['audioMs'] as num?) ?? 0) >= 1200 && _notCaught < 2 && _canReply) {
          // The caller said something we could not make out: say so instead of
          // leaving them waiting for an answer.
          _notCaught++;
          _say("Sorry, I didn't catch that. Could you say it again?");
        } else if (_speaking.isEmpty && !_generating) {
          _armIdle();
        }
      case 'level':
        levelDb = (event['peakDb'] as num?)?.toDouble();
        notifyListeners();
      case 'tts_done' || 'tts_error':
        final id = event['id'];
        _speechText.remove(id);
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
    final cut = [for (final id in _speaking) _speechText.remove(id) ?? ''].join(' ').trim();
    if (cut.isNotEmpty && !_transferring) {
      _interrupted = _interrupted == null ? cut : '$_interrupted $cut';
      // If nothing comes of the interruption, finish what was being said.
      _resumeTimer?.cancel();
      _resumeTimer = Timer(const Duration(seconds: 6), () => _resumeInterrupted('timeout'));
    }
    _speaking.clear();
    _drained?.complete();
    _drained = null;
    if (_generating) agent.model.cancel();
    _setState('listening');
  }

  /// Nothing is being said or prepared, so a reply would not talk over one.
  bool get _canReply => !finished && !_closing && !_generating && !_transferring && _speaking.isEmpty;

  /// The caller is talking, or their words are still being transcribed.
  bool _hearing = false;

  void _resumeInterrupted(String why) {
    _resumeTimer?.cancel();
    if (why == 'timeout' && _hearing && !finished) {
      // Still talking (long sentences take a while): never talk over them.
      _resumeTimer = Timer(const Duration(seconds: 2), () => _resumeInterrupted('timeout'));
      return;
    }
    final text = _interrupted;
    _interrupted = null;
    if (text == null || !_canReply) return;
    if (kDebugMode) unawaited(api.log('voice $sessionId resume after $why'));
    _speak(text);
  }

  /// While waiting for the owner, keep the caller company: never a dead line.
  void _holdLine() {
    final responder = tiered;
    if (responder is! TieredResponder || finished || _closing || _speaking.isNotEmpty) return;
    if (_holdSpacing?.isActive == true) return;
    _holdSpacing = Timer(const Duration(seconds: 5), () {});
    _say(responder.transferStill);
  }

  void _onUtterance(String text) {
    // Once the closing line is playing, nothing the other side says changes it.
    if (finished || _closing || text.trim().isEmpty) return;
    _idle?.cancel();
    _checkedIn = false;
    _resumeTimer?.cancel();
    final interrupted = _interrupted;
    _interrupted = null;
    if (_transferring) {
      _add(isCall ? 'caller' : 'you', text);
      _holdLine();
      return;
    }
    if (interrupted != null && !_generating && _backchannel.hasMatch(text.trim())) {
      // "Okay" / "mm-hmm" over our sentence: not a new turn; finish the sentence.
      _add(isCall ? 'caller' : 'you', text);
      _interrupted = interrupted;
      _resumeInterrupted('backchannel');
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
    _holdSpacing = Timer(const Duration(seconds: 5), () {});
    // Music between the hold updates: the caller always hears that the line is alive.
    unawaited(_music(true));
    _holdTimer = Timer.periodic(const Duration(seconds: 12), (_) => _holdLine());
    // The owner sees everything the caller has said, not just the last line.
    final context = responder.callerContext;
    final bool picked;
    try {
      picked = await onTransfer!(context.isEmpty ? callerSaid : context);
    } finally {
      _holdTimer?.cancel();
      _holdSpacing?.cancel();
      _transferring = false;
      await _music(false);
    }
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

  bool _musicOn = false;

  Future<void> _music(bool on) async {
    if (_musicOn == on) return;
    _musicOn = on;
    try {
      await api.holdMusic(on);
    } catch (e) {
      if (kDebugMode) unawaited(api.log('voice $sessionId hold music failed: $e'));
    }
  }

  Future<void> _waitForSpeech([Duration limit = const Duration(seconds: 30)]) async {
    if (_speaking.isEmpty) return;
    _drained ??= Completer<void>();
    await _drained!.future.timeout(limit, onTimeout: () {});
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
    _resumeTimer?.cancel();
    _holdTimer?.cancel();
    _holdSpacing?.cancel();
    if (_generating) agent.model.cancel();
    if (_musicOn) await _music(false);
    // A caller who hung up while on hold: the audio now belongs to the other
    // call, so leave speech, listening and playback alone.
    if (!_paused) {
      if (silenceNow) await api.stopSpeaking();
      await api.listenStop();
      // listenStop returns after any final words were delivered; let them land.
      await (_late ?? Future.value()).timeout(const Duration(seconds: 5), onTimeout: () {});
      if (bridged) await api.setPlayback(usage: config.callAudio.speakerPlaybackUsage);
    }
    if (hangUp && callId != null) await api.call('callHangup', {'callId': callId});
    await _events?.cancel();
    _setState('ended');
    onEnded(this);
  }
}

/// Short acknowledgements that are not a turn of their own.
final _backchannel = RegExp(
    r"^((ok(ay)?|mm+[- ]?hmm+|m+hm+|uh[- ]?huh|hmm+|um+|uh+|ah+|oh|right|i see|got it|all ?right)[.!,]*\s*)+$",
    caseSensitive: false);

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
