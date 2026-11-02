import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent.dart';
import 'tools.dart';

/// Thin wrapper over the Android bridge (see NativeBridge.kt).
class NativeApi {
  NativeApi._() : _handler = null, _testEvents = null;
  static final NativeApi instance = NativeApi._();

  /// A stand-in for the Android side (tests): [handler] answers method calls
  /// and [events] replaces the native event stream.
  @visibleForTesting
  NativeApi.fake({required Future<Object?> Function(String method, Map<String, dynamic> args) handler,
      required Stream<Map<String, dynamic>> events})
      // Named parameters cannot be private, so these are assigned here.
      // ignore: prefer_initializing_formals
      : _handler = handler,
        // ignore: prefer_initializing_formals
        _testEvents = events;

  final Future<Object?> Function(String method, Map<String, dynamic> args)? _handler;
  final Stream<Map<String, dynamic>>? _testEvents;

  static const _methods = MethodChannel('receptionist/native');
  static const _events = EventChannel('receptionist/events');

  late final Stream<Map<String, dynamic>> events = _testEvents ??
      _events.receiveBroadcastStream().map((e) => (e as Map).cast<String, dynamic>()).asBroadcastStream();

  Future<T?> call<T>(String method, [Map<String, dynamic>? args]) async {
    final handler = _handler;
    if (handler != null) return await handler(method, args ?? const {}) as T?;
    return _methods.invokeMethod<T>(method, args);
  }

  Future<Map<String, dynamic>> status() async =>
      ((await call<Map>('status')) ?? const {}).cast<String, dynamic>();

  Future<void> log(String message) => call('log', {'message': message});

  /// [cache]: a fixed line (greeting, hold line) whose audio is saved and
  /// replayed instead of rendered each time.
  Future<void> speak(String id, String text, String voice, {bool cache = false}) =>
      call('speak', {'id': id, 'text': text, 'voice': voice, if (cache) 'cache': true});

  Future<void> stopSpeaking() => call('stopSpeaking');

  /// Hold music in every pause between sentences (a caller waiting on hold).
  Future<void> holdMusic(bool on) => call('holdMusic', {'on': on});

  Future<void> setPlayback({String? usage, double? gain}) =>
      call('setPlayback', {'usage': usage, 'gain': gain});

  Future<void> listenStart(String session, {required String source, double? endSilence}) =>
      call('listenStart', {'session': session, 'source': source, 'endSilence': endSilence});

  Future<void> listenStop() => call('listenStop');

  Future<String?> lookupContact(String number) => call<String>('lookupContact', {'number': number});

  Future<List<CalendarEvent>> calendar(DateTime start, DateTime end) async {
    final rows = await call<List>('calendarEvents', {
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
    });
    return [
      for (final row in rows ?? const [])
        CalendarEvent(
          DateTime.fromMillisecondsSinceEpoch((row['start'] as num).toInt()),
          DateTime.fromMillisecondsSinceEpoch((row['end'] as num).toInt()),
          (row['title'] ?? '').toString(),
          allDay: row['allDay'] == true,
          busy: row['busy'] != false,
        ),
    ];
  }

  /// Shows a notification. The assistant's updates are silent; only [urgent]
  /// ones alert with sound.
  Future<void> notifyOwner(String title, String body, {bool urgent = false}) =>
      call('notifyOwner', {'title': title, 'body': body, 'urgent': urgent});
  Future<void> sendSms(String number, String text) => call('smsSend', {'number': number, 'text': text});
}

/// Gemma through the native bridge, with streamed tokens routed by request ID.
class NativeLanguageModel implements LanguageModel {
  NativeLanguageModel(this.api) {
    api.events.where((e) => e['type'] == 'token').listen((e) {
      if (e['id'] == _activeId) _onToken?.call((e['text'] ?? '').toString());
    });
  }

  final NativeApi api;
  int _counter = 0;
  String? _activeId;
  void Function(String)? _onToken;
  bool _cancelled = false;

  @override
  Future<String> generate(String prompt,
      {required String grammar, int maxTokens = 160, double temperature = 0.4, void Function(String)? onToken}) async {
    final id = 'gen-${++_counter}';
    _activeId = id;
    _onToken = onToken;
    _cancelled = false;
    try {
      final text = await api.call<String>('llmGenerate', {
        'id': id,
        'prompt': prompt,
        'grammar': grammar,
        'maxTokens': maxTokens,
        'temperature': temperature,
      });
      // Token events are posted before the result; let them drain.
      await Future<void>.delayed(Duration.zero);
      return text ?? '';
    } on PlatformException catch (e) {
      if (_cancelled || (e.message ?? '').contains('Cancelled')) throw GenerationCancelled();
      rethrow;
    } finally {
      if (_activeId == id) {
        _activeId = null;
        _onToken = null;
      }
    }
  }

  @override
  Future<void> prefill(String prompt) async {
    try {
      await api.call('llmPrefill', {'prompt': prompt});
    } on PlatformException catch (e) {
      if (!(e.message ?? '').contains('Cancelled')) rethrow;
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    api.call('llmCancel');
  }
}
