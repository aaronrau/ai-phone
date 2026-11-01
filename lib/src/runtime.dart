import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent.dart';
import 'calendar.dart';
import 'contacts.dart';
import 'decision.dart';
import 'decision_eval.dart';
import 'tiered.dart';
import 'config.dart';
import 'native.dart';
import 'outbound.dart';
import 'policy.dart';
import 'reply.dart';
import 'intents.dart';
import 'store.dart';
import 'tasks.dart';
import 'texting.dart';
import 'tools.dart';
import 'voice_session.dart';

class CallInfo {
  CallInfo(this.callId, this.number, this.incoming);
  final String callId;
  final String number;
  final bool incoming;
  String state = 'new';
  Disposition? disposition;
  bool aiHandled = false;
  bool aiStarted = false;

  /// When the call connected (for the call log on Home).
  DateTime? connectedAt;

  /// Conversation runs through the shell call-audio helper.
  bool bridged = false;

  /// Set when the assistant placed this call for the owner.
  OutboundTask? outbound;
  bool speaker = false;
  bool muted = false;
}

class RuntimeToolHost implements ToolHost {
  RuntimeToolHost(this.runtime);
  final ReceptionistRuntime runtime;

  @override
  DateTime now() => DateTime.now();

  @override
  Future<List<CalendarEvent>> calendar(DateTime start, DateTime end) async {
    final data = runtime.calendar;
    final events = [
      for (final item in data.itemsBetween(start, end))
        CalendarEvent(item.start, item.end, item.title,
            allDay: item.allDay, shareDetails: item.shareDetails, notes: item.notes),
    ];
    if (data.usePhoneCalendar) {
      try {
        // Phone calendar entries only ever count as busy; their titles stay private.
        for (final e in await runtime.api.calendar(start, end)) {
          events.add(CalendarEvent(e.start, e.end, '', allDay: e.allDay, busy: e.busy));
        }
      } catch (_) {}
    }
    return events;
  }

  @override
  Future<(DateTime, DateTime)?> workingHours(DateTime day) async => runtime.calendar.hoursFor(day);

  @override
  Future<void> updateContact(String number, void Function(TrackedContact contact) change) =>
      runtime.updateContact(number, change);

  @override
  Future<void> blockNumber(String number, String reason) => runtime.blockNumber(number, reason);

  @override
  Future<void> notifyOwner(String title, String body, {bool urgent = false}) =>
      runtime.api.notifyOwner(title, body, urgent: urgent);

  @override
  Future<void> record(String kind, Map<String, dynamic> data) async {
    await runtime.store?.addActivity(kind, data);
    runtime.changed();
  }

  @override
  Future<void> saveMessage(TakenMessage message) async {
    await runtime.store?.addMessage(message);
    runtime.changed();
  }
}

/// The receptionist: routes call and SMS events from Android through the
/// caller policy to an [Agent], and exposes state to the UI.
class ReceptionistRuntime extends ChangeNotifier {
  ReceptionistRuntime(this.api);

  final NativeApi api;
  late final NativeLanguageModel model = NativeLanguageModel(api);
  late final RuntimeToolHost host = RuntimeToolHost(this);
  Store? store;
  ReceptionistConfig config = ReceptionistConfig.defaults();
  CalendarData calendar = CalendarData.defaults();
  ContactBook contacts = ContactBook.empty();
  WorkflowPhrases phrases = WorkflowPhrases.defaults;
  bool decisionReady = false;

  /// Outbound tasks waiting for their call to appear, by number.
  final Map<String, OutboundTask> _pendingCallOuts = {};

  /// Recent outbound tasks, newest first, for the Call out screen.
  final List<OutboundTask> callOuts = [];
  Map<String, dynamic> status = const {};
  String modelState = 'not loaded';
  String? modelError;
  bool modelsReady = false;
  bool probeNextCall = false;

  /// Debug: answer the next call, stay silent for 75 s, then hang up.
  bool holdNextCall = false;
  final List<Map<String, dynamic>> probeResults = [];
  final Map<String, CallInfo> calls = {};
  final Map<String, Disposition> _screened = {};
  VoiceSession? session;
  String? focusCallId;
  String? dialNumber;

  /// The phone's text messages (when this app is the default messaging app).
  late final Texting texting = Texting(api);

  /// Bumped whenever texts change, so open conversations reload.
  int textsVersion = 0;

  /// What to do the next time specific people call.
  TaskBook tasks = TaskBook.empty();

  /// A known contact on an assistant call waiting for the owner (warm transfer).
  TransferRequest? transfer;
  Completer<bool>? _transferAnswer;

  /// A conversation the UI should open: from a notification, or an sms: link.
  int? openThreadId;
  String? composeNumber;
  String composeBody = '';
  bool uiVisible = false;
  Future<void> _llmQueue = Future.value();

  void changed() => notifyListeners();

  /// Callers who are in the phone's address book (or the configured contact
  /// list) but were recorded as unknown or screened become known contacts.
  Future<void> _promoteKnownCallers() async {
    var changed = false;
    for (final c in contacts.contacts.toList()) {
      if (c.status != ContactStatus.unknown && c.status != ContactStatus.screened) continue;
      if (c.numbers.isEmpty) continue;
      try {
        final disposition = await classify(c.numbers.first);
        if (disposition.workflow != Workflow.known) continue;
        c.status = ContactStatus.known;
        if (c.name.isEmpty && (disposition.name ?? '').isNotEmpty) c.name = disposition.name!;
        changed = true;
      } catch (_) {}
    }
    if (changed) await saveContacts();
  }

  Future<void> addTask(InboundTask task) async {
    tasks.add(task);
    await store?.saveTasks(tasks);
    notifyListeners();
  }

  Future<void> deleteTask(InboundTask task) async {
    tasks.inbound.remove(task);
    await store?.saveTasks(tasks);
    notifyListeners();
  }

  Future<void> _finishTask(InboundTask task, String result) async {
    task
      ..doneAt = DateTime.now()
      ..result = result;
    await store?.saveTasks(tasks);
    notifyListeners();
  }

  /// Sends a text the owner wrote and records it for the Home list.
  Future<void> sendText(String number, String body) async {
    await texting.send(number, body);
    await store?.addActivity('sms_sent', {'number': number, 'body': body});
    textsVersion++;
    notifyListeners();
  }

  /// As the default messaging app, notifies for incoming texts. While the
  /// assistant is on, only known contacts (and one-time sign-in codes) notify;
  /// with it off, every text does. Blocked numbers never reach the app.
  Future<void> _notifyText(String number, String body, int threadId) async {
    try {
      final contact = contacts.find(number);
      if (contact?.status == ContactStatus.blocked) return;
      final known = (await classify(number, sms: true)).workflow == Workflow.known;
      if (config.enabled && !known && !isVerificationCode(body)) return;
      final name = contact?.label ?? await api.lookupContact(number) ?? number;
      IntentMatch? match;
      try {
        match = await intentDetector?.detect(body);
      } catch (_) {}
      await api.call('smsNotify', {'threadId': threadId, 'title': name, 'body': labelled(match?.label, body)});
    } catch (e) {
      debugLog('text notification failed: $e');
    }
  }

  Future<void> init() async {
    api.events.listen(_onEvent, onError: (Object e) => debugPrint('event error $e'));
    await refreshStatus();
    // If the app stopped during an assistant call, give the owner their call volume back.
    unawaited(api.call('callQuiet', {'on': false}));
    final files = status['filesDir']?.toString();
    if (files != null) {
      store = Store(Directory(files));
      config = await store!.loadConfig();
      calendar = await store!.loadCalendar();
      contacts = await store!.loadContacts();
      tasks = await store!.loadTasks();
      unawaited(_promoteKnownCallers());
      phrases = await store!.loadPhrases();
    }
    notifyListeners();
    unawaited(loadModels());
  }

  Future<void> refreshStatus() async {
    try {
      status = await api.status();
    } catch (e) {
      debugPrint('status failed: $e');
    }
    notifyListeners();
  }

  Future<void> loadModels() async {
    modelError = null;
    modelState = 'loading';
    notifyListeners();
    try {
      if (!config.usesGemma) {
        // Small-model mode: Gemma is never resident.
        await api.call('llmUnload');
      }
      await api.call('loadModels', {
        'llm': config.usesGemma ? config.gemmaModel : null,
        'context': config.llmContext,
        'threads': config.llmThreads,
        'voice': config.voice,
        'stt': config.sttModel,
      });
      modelsReady = true;
      modelState = 'ready';
      await _loadDecisionModel();
      await loadIntents();
    } catch (e) {
      modelsReady = false;
      modelState = 'failed';
      modelError = e.toString();
    }
    await refreshStatus();
  }

  Future<void> _loadDecisionModel() async {
    decisionReady = false;
    if (!config.usesSmallModel) {
      try {
        await api.call('decisionUnload');
      } catch (_) {}
      return;
    }
    try {
      await api.call('decisionLoad', {'model': config.decisionModel, 'context': 1024, 'threads': 4});
      decisionReady = true;
    } catch (e) {
      modelError = 'Decision model: $e';
    }
  }

  /// On-device topic detection; null when the embedding model is missing.
  IntentDetector? intentDetector;
  String intentStatus = 'not loaded';

  /// Loads the embedding model and embeds every configured topic example.
  Future<void> loadIntents() async {
    intentDetector = null;
    try {
      final started = DateTime.now();
      await api.call('embedLoad', {'model': config.embeddingModel, 'threads': 4});
      final detector = IntentDetector(intents: config.intents, embed: _embed, threshold: config.intentThreshold);
      await detector.prepare();
      intentDetector = detector;
      intentStatus = 'ready (${config.intents.length} topics, '
          '${DateTime.now().difference(started).inMilliseconds} ms)';
    } catch (e) {
      intentStatus = 'off: $e';
    }
    debugLog('intents $intentStatus');
    notifyListeners();
  }

  Future<List<List<double>>> _embed(List<String> texts) async => [
        for (final v in await api.call<List>('embed', {'texts': texts}) ?? const [])
          [for (final x in v as List) (x as num).toDouble()],
      ];

  TieredResponder? _tieredFor(Agent agent) {
    if (!config.usesSmallModel || !decisionReady) return null;
    // Models trained on conversations (receptionist-decision-v2…) read the
    // whole conversation; the first fine-tune reads only the latest line.
    final style = config.decisionModel.contains('-v2') ? DecisionStyle.context : DecisionStyle.tuned;
    final router = DecisionRouter(NativeDecisionBackend(api, engine: 'decision'),
        formatForModel(config.decisionModel), style: style);
    return TieredResponder(router: router, agent: agent, phrases: phrases, ownerName: config.ownerName,
        escalateToLargeModel: config.usesGemma)
      ..intents = intentDetector;
  }

  bool get _modelsUsable => modelsReady && (!config.usesSmallModel || decisionReady);

  /// Has the large model write the workflow phrasings once; saved privately.
  Future<String> authorPhrases({String style = 'warm, brief and professional'}) async {
    if (!modelsReady) await loadModels();
    // Gemma is loaded only for this one-off rewrite in small-model mode.
    final temporary = !config.usesGemma;
    if (temporary) {
      await api.call('loadModels', {'llm': config.gemmaModel, 'context': 2048, 'threads': config.llmThreads,
          'voice': config.voice, 'stt': config.sttModel});
    }
    final keys = WorkflowPhrases.defaults.values.keys.toList();
    final grammar = phraseGrammar(keys);
    final prompt = renderGemma('You write short, natural lines for a phone receptionist.', [
      ChatTurn('user', authorPhrasesPrompt(
          config.ownerName, config.assistantName.replaceAll('{owner_name}', config.ownerName), style)),
    ]);
    final String raw;
    try {
      raw = await _withModel(() => model.generate(prompt, grammar: grammar, maxTokens: 400, temperature: 0.3));
    } finally {
      if (temporary) await api.call('llmUnload');
    }
    final authored = WorkflowPhrases.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    phrases = authored;
    await store?.savePhrases(authored);
    notifyListeners();
    return raw;
  }

  Future<List<String>> saveConfig(String text) async {
    final problems = ReceptionistConfig.validate(text);
    if (problems.isNotEmpty) return problems;
    final previous = config;
    await store?.saveConfigText(text);
    config = await store!.loadConfig();
    notifyListeners();
    if (previous.gemmaModel != config.gemmaModel ||
        previous.llmContext != config.llmContext ||
        previous.llmThreads != config.llmThreads ||
        previous.voice != config.voice ||
        previous.sttModel != config.sttModel) {
      unawaited(loadModels());
    } else if (previous.responder != config.responder || previous.decisionModel != config.decisionModel) {
      unawaited(loadModels());
    } else if (previous.decisionModel != config.decisionModel) {
      unawaited(_loadDecisionModel());
    }
    // Topics, examples or the threshold changed: re-embed.
    if (previous.embeddingModel != config.embeddingModel ||
        previous.intentThreshold != config.intentThreshold ||
        jsonEncode([for (final i in previous.intents) i.toJson()]) !=
            jsonEncode([for (final i in config.intents) i.toJson()])) {
      unawaited(loadIntents());
    }
    return const [];
  }

  Future<void> saveCalendar() async {
    calendar.items.sort((a, b) => a.start.compareTo(b.start));
    await store?.saveCalendar(calendar);
    notifyListeners();
  }

  /// Contact-book changes are persisted immediately.
  Future<void> updateContact(String number, void Function(TrackedContact contact) change) async {
    if (number.trim().isEmpty) return;
    final contact = contacts.touch(number);
    change(contact);
    await store?.saveContacts(contacts);
    notifyListeners();
  }

  Future<void> saveContacts() async {
    await store?.saveContacts(contacts);
    notifyListeners();
  }

  /// Puts [number] on Android's block list (needs the default phone app role).
  Future<void> blockNumber(String number, String reason) async {
    try {
      await api.call('blockNumber', {'number': number});
      await store?.addActivity('number_blocked', {'number': number, 'reason': reason});
    } catch (e) {
      await store?.addActivity('block_failed', {'number': number, 'error': e.toString()});
    }
  }

  /// Sets a contact's status from the Contacts tab, keeping the system block list in sync.
  Future<void> setContactStatus(TrackedContact contact, ContactStatus status, {String reason = ''}) async {
    final wasBlocked = contact.status == ContactStatus.blocked;
    contact.status = status;
    if (status == ContactStatus.blocked) {
      contact.blockReason = reason.isEmpty ? 'blocked by owner' : reason;
      for (final number in contact.numbers) {
        await blockNumber(number, contact.blockReason);
      }
    } else if (wasBlocked) {
      contact.blockReason = '';
      for (final number in contact.numbers) {
        try {
          await api.call('unblockNumber', {'number': number});
        } catch (_) {}
      }
    }
    await saveContacts();
  }

  Future<void> setEnabled(bool enabled) async {
    await saveConfig(config.copyWith(enabled: enabled).encode());
  }

  Future<Disposition> classify(String number, {bool sms = false}) async {
    String? name;
    try {
      name = await api.lookupContact(number);
    } catch (_) {}
    return CallerPolicy(config, contacts).classify(number, phoneContactName: name, sms: sms);
  }

  /// Serialises access to the single on-device model.
  Future<T> _withModel<T>(Future<T> Function() work) {
    final result = _llmQueue.then((_) => work());
    _llmQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  // ---------------------------------------------------------------- events

  void _onEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'screen_call':
        unawaited(_onScreen(event));
      case 'call_added':
        unawaited(_onCallAdded(event));
      case 'call_state':
        unawaited(_onCallState(event));
      case 'call_removed':
        unawaited(_onCallRemoved((event['callId'] ?? '').toString()));
      case 'call_audio':
        for (final call in calls.values) {
          call.speaker = event['speaker'] == true;
          call.muted = event['muted'] == true;
        }
        notifyListeners();
      case 'sms':
        final number = (event['number'] ?? '').toString();
        final body = (event['body'] ?? '').toString();
        textsVersion++;
        notifyListeners();
        if (event['stored'] == true) {
          unawaited(_notifyText(number, body, (event['threadId'] as num?)?.toInt() ?? -1));
        }
        // Group and picture messages are shown, never answered by the assistant.
        if (event['group'] != true) unawaited(handleSms(number, body));
      case 'sms_sent':
        textsVersion++;
        notifyListeners();
      case 'open_thread':
        openThreadId = (event['threadId'] as num?)?.toInt();
        notifyListeners();
      case 'compose':
        composeNumber = (event['number'] ?? '').toString();
        composeBody = (event['body'] ?? '').toString();
        notifyListeners();
      case 'dial':
        dialNumber = (event['number'] ?? '').toString();
        notifyListeners();
      case 'call_action':
        final id = (event['callId'] ?? '').toString();
        if (event['action'] == 'pick_up') {
          acceptTransfer();
        } else if (event['action'] == 'not_now') {
          declineTransfer();
        } else if (event['action'] == 'take_over') {
          unawaited(takeOver(id).then((_) => api.call('callNotification', {'callId': id})));
        } else if (event['action'] == 'hang_up') {
          unawaited(api.call('callHangup', {'callId': id}));
        }
      case 'show_call':
        focusCallId = event['callId']?.toString();
        notifyListeners();
      case 'ui_visible':
        uiVisible = event['visible'] == true;
        if (uiVisible) unawaited(refreshStatus());
      case 'models':
        modelState = event['stage'] == 'ready' ? 'ready' : 'loading ${event['stage']}';
        notifyListeners();
      case 'debug_command':
        if (kDebugMode) unawaited(_debugCommand(event));
      case 'probe_result':
        probeResults.add(Map.of(event)..remove('type'));
        unawaited(store?.addActivity('probe', Map.of(event)..remove('type')));
        notifyListeners();
    }
  }

  Future<void> _onScreen(Map<String, dynamic> event) async {
    final number = (event['number'] ?? '').toString();
    final requestId = event['requestId'];
    var decision = 'allow';
    if (config.enabled) {
      final disposition = await classify(number);
      _screened[normalizeNumber(number)] = disposition;
      await refreshStatus();
      final canConverse = status['callAudioHelper'] == true;
      decision = switch (disposition.workflow) {
        Workflow.block => 'reject',
        // Without the call-audio helper the assistant cannot hear the caller,
        // so allowed calls ring normally instead of being silenced.
        _ => !canConverse || config.callAudio.answerAfterSeconds > 0 ? 'allow' : 'silence',
      };
      if (number.trim().isNotEmpty) {
        await updateContact(number, (c) {
          c.addEvent('call',
              disposition.workflow == Workflow.block ? 'call blocked (${disposition.reason})' : 'called', DateTime.now());
          // Someone in the phone's address book is a known contact here too.
          if (disposition.workflow == Workflow.known) {
            if (c.status == ContactStatus.unknown || c.status == ContactStatus.screened) c.status = ContactStatus.known;
            if (c.name.isEmpty && (disposition.name ?? '').isNotEmpty) c.name = disposition.name!;
          }
        });
      }
      await store?.addActivity('call_screened', {
        'number': number,
        'workflow': disposition.workflow.name,
        'reason': disposition.reason,
        'decision': decision,
      });
    }
    await api.call('screenDecision', {'requestId': requestId, 'decision': decision, 'number': number});
  }

  Future<void> _onCallAdded(Map<String, dynamic> event) async {
    final id = event['callId'].toString();
    final number = (event['number'] ?? '').toString();
    final info = CallInfo(id, number, event['incoming'] == true)..state = (event['state'] ?? 'new').toString();
    calls[id] = info;
    // Calls show as notifications; the in-app call screen takes over only for a
    // call placed from the open app (or when the notification is tapped).
    if (!info.incoming && uiVisible && !_pendingCallOuts.containsKey(normalizeNumber(number))) focusCallId = id;
    notifyListeners();
    if (!info.incoming) {
      final task = _pendingCallOuts.remove(normalizeNumber(number));
      if (task != null) {
        info
          ..aiHandled = true
          ..outbound = task;
        task.status = 'dialing';
        notifyListeners();
      }
      return;
    }
    if (info.state != 'ringing') return;
    // Calls that ring through to the owner show as a notification with
    // Answer / Decline; the app's call screen opens only if it is tapped.
    if (!config.enabled && !probeNextCall && !holdNextCall) return;
    final disposition = _screened.remove(normalizeNumber(number)) ?? await classify(number);
    info.disposition = disposition;
    if (!disposition.handled && !probeNextCall && !holdNextCall) {
      // Screening service unavailable or bypassed: reject here instead.
      await api.call('callReject', {'callId': id});
      await store?.addActivity('call_blocked', {'number': number, 'reason': disposition.reason});
      return;
    }
    await refreshStatus();
    if (status['callAudioHelper'] != true && !probeNextCall && !holdNextCall) {
      await api.notifyOwner('Call not answered by the receptionist',
          'The call-audio helper is not running, so the call rang through. Start it with tool/start_call_audio_helper.sh.');
      return;
    }
    info.aiHandled = true;
    final delay = config.callAudio.answerAfterSeconds;
    if (delay > 0) {
      await Future<void>.delayed(Duration(seconds: delay));
      if (calls[id]?.state != 'ringing' || !info.aiHandled) return;
    }
    await api.call('callAnswer', {'callId': id});
  }

  Future<void> _onCallState(Map<String, dynamic> event) async {
    final id = event['callId'].toString();
    final info = calls[id];
    if (info == null) return;
    info.state = (event['state'] ?? '').toString();
    if (info.state == 'active') info.connectedAt ??= DateTime.now();
    notifyListeners();
    if (info.state == 'active' && info.aiHandled && !info.aiStarted) {
      info.aiStarted = true;
      await _startAiCall(info);
    } else if (info.state == 'disconnected') {
      await _onCallRemoved(id);
    }
  }

  Future<void> _startAiCall(CallInfo info) async {
    await refreshStatus();
    final bridge = status['callAudioHelper'] == true;
    info.bridged = bridge;
    if (!bridge) {
      // Without the call-audio helper the assistant would need the speakerphone.
      // Never do that: the call is the owner's, shown as a normal call notification.
      info.aiHandled = false;
      await api.call('callNotification', {'callId': info.callId});
      await api.notifyOwner('The assistant could not take this call',
          'The call-audio helper is not running, so the call is yours. Start it with tool/start_call_audio_helper.sh.');
      notifyListeners();
      return;
    }
    if (bridge) {
      // Audio runs through the background helper: never interrupt the screen.
      await api.call('aiCallNotification', {
        'callId': info.callId,
        'title': 'AI assistant is answering',
        'text': info.disposition?.name ?? (info.number.isEmpty ? 'Unknown caller' : info.number),
      });
    }
    await api.call('enterCallMode');
    if (bridge) {
      // Digital path: caller audio from the downlink, speech into the uplink.
      // The phone stays silent: no speakerphone, microphone muted so the room
      // never reaches the caller, and in-call volume at its minimum.
      await api.call('callSpeaker', {'on': false});
      await api.call('callMute', {'on': true});
      await api.call('callQuiet', {'on': true});
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (holdNextCall) {
      holdNextCall = false;
      debugLog('holding call ${info.callId} for 75 s');
      await api.call('callSpeaker', {'on': false});
      await Future<void>.delayed(const Duration(seconds: 75));
      await api.call('callHangup', {'callId': info.callId});
      return;
    }
    if (probeNextCall) {
      probeNextCall = false;
      probeResults.clear();
      notifyListeners();
      try {
        await api.call('probeCallAudio', {'voice': config.voice});
      } catch (e) {
        probeResults.add({'error': e.toString()});
      }
      notifyListeners();
      await api.call('callHangup', {'callId': info.callId});
      return;
    }
    if (!_modelsUsable) await loadModels();
    final task = info.outbound;
    if (task != null) {
      await _startOutboundSession(info, task, bridge);
      return;
    }
    final disposition = info.disposition ?? await classify(info.number);
    final agent = Agent(config: config, disposition: disposition, channel: Channel.call, model: model, host: host);
    await _startSession(agent, callId: info.callId, bridged: bridge);
  }

  /// Places a call for the owner and pursues [task] when it connects.
  Future<String?> startCallOut(OutboundTask task) async {
    if (!_modelsUsable) {
      await loadModels();
      if (!_modelsUsable) return modelError ?? 'Models are not loaded';
    }
    await refreshStatus();
    if (status['callAudioHelper'] != true) return 'The call-audio helper is not running.';
    _pendingCallOuts[normalizeNumber(task.number)] = task;
    callOuts.insert(0, task);
    await api.call('markAiNumber', {'number': task.number});
    await api.call('placeCall', {'number': task.number});
    await store?.addActivity('callout_started', {'number': task.number, 'objective': task.objective});
    notifyListeners();
    return null;
  }

  Future<void> _startOutboundSession(CallInfo info, OutboundTask task, bool bridged) async {
    final disposition = await classify(info.number);
    final agent = Agent(config: config, disposition: disposition, channel: Channel.call, model: model, host: host);
    final responder = OutboundResponder(
      router: DecisionRouter(NativeDecisionBackend(api, engine: 'decision'), formatForModel(config.decisionModel),
          style: DecisionStyle.context, minProbability: 0.45, minMargin: 0.0),
      agent: agent,
      task: task,
      ownerName: config.ownerName,
      assistantName: config.assistantName.replaceAll('{owner_name}', config.ownerName),
      onBooked: (start, title) async {
        calendar.items.add(bookingItem(start, title));
        await saveCalendar();
      },
    );
    final session = VoiceSession(
      api: api,
      agent: agent,
      config: config,
      callId: info.callId,
      bridged: bridged,
      tiered: responder,
      outbound: true,
      onEnded: (ended) {
        if (task.status != 'done') {
          task
            ..status = 'done'
            ..outcome = task.outcome.isEmpty ? 'call ended' : task.outcome;
        }
        unawaited(store?.addActivity('callout', {
          ...task.toJson(),
          'lines': [for (final line in ended.lines) line.toJson()],
        }));
        // Call-outs build the contact book too, like incoming calls.
        unawaited(updateContact(task.number, (c) {
          if (c.name.isEmpty && task.contactName.isNotEmpty) c.name = task.contactName;
          c.addEvent('call', 'assistant called to ${task.objective}: ${task.outcome}', DateTime.now());
        }));
        unawaited(api.notifyOwner('Call out: ${task.contactName.isEmpty ? task.number : task.contactName}',
            '${task.objective} — ${task.outcome}'));
        if (this.session == ended) this.session = null;
        notifyListeners();
      },
    );
    session.addListener(notifyListeners);
    this.session = session;
    task.status = 'connected';
    notifyListeners();
    await session.start();
  }

  Future<void> _onCallRemoved(String id) async {
    final info = calls.remove(id);
    final current = session;
    if (current != null && current.callId == id) await current.stop(silenceNow: true);
    if (calls.isEmpty) {
      await api.call('leaveCallMode');
      focusCallId = null;
      // Give the call volume back only after Android's end-of-call tone, so
      // the hang-up stays silent too.
      unawaited(Future<void>.delayed(const Duration(seconds: 4), () async {
        if (calls.isEmpty) await api.call('callQuiet', {'on': false});
      }));
    }
    if (info != null) {
      final connected = info.connectedAt;
      await store?.addActivity('call_ended', {
        'number': info.number,
        'ai': info.aiHandled,
        // The assistant spoke on this call (its own log entry covers it).
        'assistant': info.aiStarted || info.outbound != null,
        'incoming': info.incoming,
        'answered': connected != null,
        'seconds': connected == null ? 0 : DateTime.now().difference(connected).inSeconds,
      });
    }
    notifyListeners();
  }

  /// Debug-build automation (see DebugCommandReceiver.kt).
  Future<void> _debugCommand(Map<String, dynamic> event) async {
    final number = (event['number'] ?? '+15555550123').toString();
    switch (event['command']) {
      case 'sms':
        final started = DateTime.now();
        final reply = await handleSms(number, (event['body'] ?? '').toString(), simulate: true);
        debugLog('sms_test reply_ms=${DateTime.now().difference(started).inMilliseconds} reply=$reply');
      case 'sms_reset':
        final threads = await store?.threads() ?? {};
        threads.removeWhere((key, _) => key.startsWith('test:'));
        await store?.saveThreads(threads);
        debugLog('sms_test threads reset');
      case 'speaker_start':
        debugLog('speaker_test start error=${await startSpeakerTest(number)}');
      case 'speaker_stop':
        await session?.stop(silenceNow: true);
      case 'config':
        final problems = await saveConfig((event['json'] ?? '').toString());
        debugLog('config saved problems=$problems');
      case 'calendar':
        calendar = CalendarData.fromJson(
            (jsonDecode((event['json'] ?? '{}').toString()) as Map).cast<String, dynamic>());
        await saveCalendar();
        debugLog('calendar saved items=${calendar.items.length}');
      case 'hold_next':
        holdNextCall = true;
      case 'eval_decision':
        await _evalDecision(event);
      case 'author_phrases':
        debugLog('author_phrases ${await authorPhrases()}');
      case 'eval_context':
        final files = status['filesDir']?.toString();
        final modelName = (event['model'] ?? config.decisionModel).toString();
        await api.call('decisionLoad', {'model': modelName, 'context': 1024, 'threads': 4});
        final report = await runContextEval(
          backend: NativeDecisionBackend(api, engine: 'decision'),
          format: formatForModel(modelName),
          dataset: File('$files/eval/decision_eval_v2.jsonl'),
          modelName: modelName,
        );
        await File('$files/eval/result-context-${modelName.replaceAll('.gguf', '')}.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        debugLog('eval_summary ${jsonEncode(report['summary'])}');
      case 'eval_outbound':
        final files = status['filesDir']?.toString();
        final modelName = (event['model'] ?? config.decisionModel).toString();
        await api.call('decisionLoad', {'model': modelName, 'context': 1024, 'threads': 4});
        final report = await runOutboundEval(
          backend: NativeDecisionBackend(api, engine: 'decision'),
          format: formatForModel(modelName),
          dataset: File('$files/eval/outbound_eval.jsonl'),
          modelName: modelName,
        );
        await File('$files/eval/result-outbound-${modelName.replaceAll('.gguf', '')}.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        debugLog('eval_summary ${jsonEncode(report['summary'])}');
      case 'callout':
        final task = OutboundTask(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          number: (event['number'] ?? '').toString(),
          objective: (event['objective'] ?? 'find a time to talk this week').toString(),
          message: (event['message'] ?? '').toString(),
        );
        debugLog('callout start error=${await startCallOut(task)}');
      case 'decision_sample':
        // Free-text answer to one decision prompt, to inspect a model's behaviour.
        final step = decisionSteps[(event['step'] ?? 'screen_open').toString()]!;
        final model = (event['model'] ?? 'LFM2.5-350M-Q8_0.gguf').toString();
        await api.call('decisionLoad', {'model': model});
        final prompt = renderDecisionPrompt(formatForModel(model), step, (event['caller'] ?? '').toString());
        final text = await api.call<String>('decisionGenerate',
            {'prompt': prompt.text, 'staticPrefix': prompt.staticPrefix, 'grammar': '', 'maxTokens': 24});
        debugLog('decision_sample model=$model output=${jsonEncode(text)}');
      case 'probe_next':
        probeNextCall = true;
        notifyListeners();
      case 'intent':
        // Debug: rank the configured topics for a sentence.
        final watch = Stopwatch()..start();
        final ranked = await intentDetector?.rank((event['text'] ?? '').toString()) ?? const <IntentMatch>[];
        debugLog('intent ms=${watch.elapsedMilliseconds} '
            '${ranked.take(3).map((m) => '${m.intent.name}=${m.score.toStringAsFixed(3)}').join(' ')}');
      case 'unblock':
        // Debug: unblock a number (system block list and contact book).
        final contact = contacts.find(number);
        if (contact != null) await setContactStatus(contact, ContactStatus.unknown);
        debugLog('unblock found=${contact != null} status=${contact?.status.name}');
      case 'enable':
        await setEnabled(event['value'] != 'false');
        debugLog('enabled=${config.enabled}');
    }
  }

  /// Debug: compares decision models on the labeled turns pushed to
  /// files/eval/decision_eval.jsonl. engine=decision loads `model` from
  /// files/models/decision; engine=main uses the resident Gemma.
  Future<void> _evalDecision(Map<String, dynamic> event) async {
    final files = status['filesDir']?.toString();
    if (files == null) return;
    final engine = (event['engine'] ?? 'decision').toString();
    var modelName = config.gemmaModel;
    try {
      if (engine == 'decision') {
        // Phones kill the app above ~6 GB; evaluate the small model alone.
        await api.call('llmUnload');
        modelsReady = false;
        modelName = (event['model'] ?? 'LFM2.5-350M-Q8_0.gguf').toString();
        final started = DateTime.now();
        await api.call('decisionLoad', {
          'model': modelName,
          'threads': int.tryParse(event['threads']?.toString() ?? '') ?? 4,
        });
        debugLog('eval load_ms=${DateTime.now().difference(started).inMilliseconds} model=$modelName');
      } else {
        await api.call('decisionUnload');
        if (!modelsReady || status['llmLoaded'] != true) await loadModels();
      }
      final report = await runDecisionEval(
        backend: NativeDecisionBackend(api, engine: engine),
        format: formatForModel(modelName),
        dataset: File('$files/eval/decision_eval.jsonl'),
        modelName: modelName,
        minProbability: double.tryParse(event['min_probability']?.toString() ?? '') ?? 0.6,
        minMargin: double.tryParse(event['min_margin']?.toString() ?? '') ?? 0.2,
        style: DecisionStyle.values.firstWhere((s) => s.name == event['style'], orElse: () => DecisionStyle.choice),
      );
      final out = File('$files/eval/result-$engine-${modelName.replaceAll('.gguf', '')}-${event['style'] ?? 'choice'}.json');
      await out.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      debugLog('eval_summary ${jsonEncode(report['summary'])}');
    } catch (e) {
      debugLog('eval_failed $e');
    }
  }

  /// Transcript-bearing logs are emitted only by debug builds.
  void debugLog(String message) {
    if (kDebugMode) unawaited(api.log(message));
  }

  // --------------------------------------------------------------- voice

  Future<void> _startSession(Agent agent, {String? callId, bool bridged = false}) async {
    await session?.stop(silenceNow: true);
    // Tasks the owner left for this caller: a message to give, a question to
    // ask, or a warm transfer.
    final pending = callId == null ? const <InboundTask>[] : tasks.pendingFor(agent.disposition.number);
    final tells = pending.where((t) => t.action == InboundAction.tell).toList();
    final ask = pending.where((t) => t.action == InboundAction.ask).firstOrNull;
    final transferTask = pending.where((t) => t.action == InboundAction.transfer).firstOrNull;
    final owner = config.ownerName;
    final notes = [
      for (final t in tells) '$owner asked me to let you know: ${_asSentence(t.text)}',
      if (ask != null) '$owner asked me to ask you: ${_asQuestion(ask.text)}',
    ];
    final topicTasks = callId == null ? const <InboundTask>[] : tasks.topicTasks;
    final responder = _tieredFor(agent)
      ?..topicTell = {for (final t in topicTasks) if (t.action == InboundAction.tell) t.topic: _asSentence(t.text)}
      ..topicAsk = {for (final t in topicTasks) if (t.action == InboundAction.ask) t.topic: _asQuestion(t.text)}
      ..topicTransfer = {for (final t in topicTasks) if (t.action == InboundAction.transfer) t.topic}
      ..onTopicAnswer = (topic, question, answer) async {
        await store?.addActivity('task_answer', {'number': agent.disposition.number, 'topic': topic, 'answer': answer});
        await api.notifyOwner('${agent.disposition.name ?? agent.disposition.number} answered', labelled(topic, '$question $answer'));
      }
      ..onTopic = (match) {
        // Show what the call is about on the assistant's call notification.
        if (callId != null && calls[callId]?.bridged == true && transfer == null) {
          final who = agent.disposition.name ?? (agent.disposition.number.isEmpty ? 'Unknown caller' : agent.disposition.number);
          unawaited(api.call('aiCallNotification',
              {'callId': callId, 'title': 'AI assistant is answering', 'text': labelled(match.label, who)}));
        }
        notifyListeners();
      }
      ..offerTransfer = callId != null &&
          ((config.warmTransfer && agent.disposition.workflow == Workflow.known) || transferTask != null)
      ..pendingQuestion = ask?.text
      ..onAnswer = ask == null
          ? null
          : (answer) async {
              await _finishTask(ask, answer);
              await api.notifyOwner('${agent.disposition.name ?? agent.disposition.number} answered',
                  '${_asQuestion(ask.text)} $answer');
            };
    final created = VoiceSession(
      api: api,
      agent: agent,
      config: config,
      callId: callId,
      bridged: bridged,
      tiered: responder,
      greetingNote: notes.isEmpty ? null : notes.join(' '),
      onTransfer: callId == null
          ? null
          : (said) async {
              final picked = await _requestTransfer(callId, agent, said,
                  topic: responder?.topic?.intent.name, topicLabel: responder?.topic?.label);
              if (transferTask != null) await _finishTask(transferTask, picked ? 'You picked up' : 'You did not pick up');
              return picked;
            },
      onHandOff: callId == null ? null : () => _handOff(callId),
      onEnded: (ended) {
        unawaited(store?.addActivity(callId == null ? 'speaker_test' : 'call_transcript', {
          'number': agent.disposition.number,
          'workflow': agent.disposition.workflow.name,
          'spam': agent.endedAsSpam,
          'name': ?agent.executor.identifiedName,
          'topic': ?agent.executor.topic,
          'topic_kind': ?responder?.topic?.intent.kind.name,
          'reason': ?agent.executor.identifiedReason,
          'message': ?agent.executor.lastMessage,
          'lines': [for (final line in ended.lines) line.toJson()],
        }));
        if (session == ended) session = null;
        if (callId != null) {
          final heard = ended.lines.where((l) => l.speaker == 'caller').length;
          unawaited(updateContact(agent.disposition.number,
              (c) => c.addEvent('call', 'talked with the receptionist ($heard caller turns)', DateTime.now())));
        }
        notifyListeners();
      },
    );
    created.addListener(notifyListeners);
    session = created;
    notifyListeners();
    await _withModel(() async {});
    await created.start();
    // The greeting delivered the owner's messages.
    for (final t in tells) {
      await _finishTask(t, 'Told on their call');
    }
  }

  /// Speaker test mode: the phone's own microphone and speaker stand in for a
  /// caller with [number] (classified exactly like a real call).
  Future<String?> startSpeakerTest(String number) async {
    if (!_modelsUsable) {
      await loadModels();
      if (!_modelsUsable) return modelError ?? 'Models are not loaded';
    }
    final disposition = await classify(number);
    if (!disposition.handled) return 'This caller would be blocked (${disposition.reason}).';
    final agent = Agent(config: config, disposition: disposition, channel: Channel.speakerTest, model: model, host: host);
    await _startSession(agent);
    return null;
  }

  /// Stops the receptionist on a live call and hands it to the user.
  /// Warm transfer: alert the owner (opening the app full screen) and wait for
  /// Pick up / Not now; no answer counts as not now.
  Future<bool> _requestTransfer(String callId, Agent agent, String said, {String? topic, String? topicLabel}) async {
    final name = agent.disposition.name ?? (agent.disposition.number.isEmpty ? 'A contact' : agent.disposition.number);
    final request = TransferRequest(callId, name, said, DateTime.now(), config.transferWaitSeconds, topic: topic);
    transfer = request;
    final answer = Completer<bool>();
    _transferAnswer = answer;
    notifyListeners();
    await api.call('transferRequest',
        {'callId': callId, 'title': '$name is calling', 'body': labelled(topicLabel, said)});
    final picked = await answer.future
        .timeout(Duration(seconds: config.transferWaitSeconds), onTimeout: () => false);
    if (identical(transfer, request)) transfer = null;
    _transferAnswer = null;
    unawaited(store?.addActivity('transfer', {'number': agent.disposition.number, 'picked': picked}));
    if (!picked && calls.containsKey(callId)) {
      await api.call('aiCallNotification', {'callId': callId, 'title': 'AI assistant is answering', 'text': name});
    }
    notifyListeners();
    return picked;
  }

  void acceptTransfer() {
    if (_transferAnswer?.isCompleted == false) _transferAnswer!.complete(true);
  }

  void declineTransfer() {
    if (_transferAnswer?.isCompleted == false) _transferAnswer!.complete(false);
  }

  /// The owner picked up: give them the call, sound on, in the app's call screen.
  Future<void> _handOff(String callId) async {
    await takeOver(callId);
    await api.call('callNotification', {'callId': callId});
    if (calls.containsKey(callId)) focusCallId = callId;
    notifyListeners();
  }

  Future<void> takeOver(String callId) async {
    calls[callId]?.aiHandled = false;
    final current = session;
    if (current != null && current.callId == callId) await current.stop(silenceNow: true);
    await api.call('callMute', {'on': false});
    await api.call('callSpeaker', {'on': false});
    // The owner needs to hear the caller again.
    await api.call('callQuiet', {'on': false});
    notifyListeners();
  }

  // ----------------------------------------------------------------- sms

  /// Handles an incoming text. With [simulate] nothing is sent; the reply is
  /// returned for the in-app SMS tester.
  Future<String?> handleSms(String number, String body, {bool simulate = false}) async {
    if (!config.enabled && !simulate) return null;
    final disposition = await classify(number, sms: true);
    await store?.addActivity(simulate ? 'sms_test_in' : 'sms_in', {
      'number': number,
      'workflow': disposition.workflow.name,
      'reason': disposition.reason,
      'body': body,
    });
    if (!disposition.handled) {
      // Texts from anyone but known contacts get no reply and no notification.
      if (!simulate && !isShortCode(number) && number.trim().isNotEmpty) {
        final alreadyBlocked = disposition.tracked?.status == ContactStatus.blocked;
        await updateContact(number, (c) => c.addEvent('sms', 'text ignored (${disposition.reason})', DateTime.now()));
        // Never block a sender of one-time sign-in codes; later codes would be lost.
        if (config.blockUnknownTexters && !alreadyBlocked && !isVerificationCode(body)) {
          await updateContact(number, (c) {
            c.status = ContactStatus.blocked;
            c.blockReason = 'texted without being a known contact';
          });
          await blockNumber(number, 'unknown texter');
        }
      }
      notifyListeners();
      return simulate ? '(no reply: ${disposition.reason})' : null;
    }
    if (!modelsReady) await loadModels();
    return _withModel(() async {
      // A live call owns the model; texts wait until it ends.
      while (session != null) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final threads = await store?.threads() ?? <String, SmsThread>{};
      final key = '${simulate ? 'test:' : ''}${normalizeNumber(number)}';
      final now = DateTime.now();
      final thread = threads[key] ?? SmsThread(number, [], []);
      if (thread.closedAt != null) {
        if (now.difference(thread.closedAt!) < const Duration(hours: 1)) {
          return simulate ? '(conversation ended; no reply for an hour)' : null;
        }
        thread
          ..closedAt = null
          ..turns.clear();
      }
      thread.replies.removeWhere((t) => now.difference(t) > const Duration(hours: 1));
      if (!simulate && thread.replies.length >= config.smsReplyLimitPerHour) {
        await store?.addActivity('sms_rate_limited', {'number': number});
        return null;
      }
      if (config.usesSmallModel && !config.usesGemma && decisionReady) {
        return _smallModelSms(thread, threads, key, number, body, disposition, simulate, now);
      }
      final history = _trim(thread.turns, 12);
      final agent = Agent(
        config: config,
        disposition: disposition,
        channel: simulate ? Channel.smsTest : Channel.sms,
        model: model,
        host: host,
        history: history,
      );
      String text;
      try {
        final replies = await agent.respond(body);
        // A text gets one message: the final answer, not interim fillers.
        final said = replies.map((r) => r.say.trim()).where((s) => s.isNotEmpty).toList();
        text = said.isEmpty ? '' : dropNumberQuestions(said.last);
      } catch (e) {
        await store?.addActivity('sms_error', {'number': number, 'error': e.toString()});
        return simulate ? '(error: $e)' : null;
      }
      if (text.isNotEmpty) {
        if (!simulate) {
          await api.sendSms(number, text);
          thread.replies.add(now);
        }
        await store?.addActivity(simulate ? 'sms_test_out' : 'sms_out', {'number': number, 'body': text});
      }
      if (agent.ended) thread.closedAt = now;
      if (!simulate) {
        await updateContact(number, (c) {
          if (c.status == ContactStatus.unknown && disposition.workflow == Workflow.known) c.status = ContactStatus.known;
          c.addEvent('sms', 'texted: ${_clip(body)}', now);
        });
      }
      thread.turns
        ..clear()
        ..addAll(agent.turns);
      threads[key] = thread;
      await store?.saveThreads(threads);
      notifyListeners();
      return text;
    });
  }

  /// Texts from known contacts answered by the fine-tuned model alone; the
  /// thread remembers its workflow step between messages.
  Future<String?> _smallModelSms(SmsThread thread, Map<String, SmsThread> threads, String key, String number,
      String body, Disposition disposition, bool simulate, DateTime now) async {
    final agent = Agent(config: config, disposition: disposition,
        channel: simulate ? Channel.smsTest : Channel.sms, model: model, host: host);
    final responder = _tieredFor(agent)!;
    // Start at the first step for this model; resume the thread's saved step
    // only when it belongs to the same model style.
    responder.start();
    final saved = thread.step;
    if (saved != null && responder.knowsStep(saved)) responder.step = saved;
    responder.awaitingMessage = thread.awaitingMessage;
    final turn = await responder.handle(body);
    final text = turn?.say ?? phrases.render('fallback_message', {'owner': config.ownerName, 'caller': ''});
    thread
      ..step = (turn?.ends ?? false) ? null : responder.step
      ..awaitingMessage = responder.awaitingMessage;
    if (turn?.ends ?? false) thread.closedAt = now;
    if (!simulate) {
      await api.sendSms(number, text);
      thread.replies.add(now);
      await updateContact(number, (c) => c.addEvent('sms', 'texted: ${_clip(body)}', now));
    }
    await store?.addActivity(simulate ? 'sms_test_out' : 'sms_out', {'number': number, 'body': text});
    threads[key] = thread;
    await store?.saveThreads(threads);
    notifyListeners();
    return text;
  }

  static String _clip(String text, [int max = 80]) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  static List<ChatTurn> _trim(List<ChatTurn> turns, int max) {
    if (turns.length <= max) return List.of(turns);
    var start = turns.length - max;
    while (start < turns.length && turns[start].role != 'user') {
      start++;
    }
    return turns.sublist(start);
  }
}

/// A known contact waiting on an assistant call for the owner to pick up.
class TransferRequest {
  TransferRequest(this.callId, this.name, this.said, this.started, this.waitSeconds, {this.topic});
  final String callId;
  final String name;

  /// The detected topic, e.g. "Plans".
  final String? topic;

  /// What the caller said they want.
  final String said;
  final DateTime started;
  final int waitSeconds;
}

String _asSentence(String text) {
  final t = text.trim();
  return t.isEmpty || RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
}

String _asQuestion(String text) {
  final t = text.trim().replaceAll(RegExp(r'[.!]+$'), '');
  return t.isEmpty || t.endsWith('?') ? t : '$t?';
}
