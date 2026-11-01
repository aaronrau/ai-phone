import 'dart:convert';
import 'dart:io';

import 'decision.dart';
import 'native.dart';
import 'outbound.dart';
import 'tiered.dart';

/// Runs a decision model on the device through the native bridge.
class NativeDecisionBackend implements DecisionBackend {
  NativeDecisionBackend(this.api, {required this.engine});
  final NativeApi api;

  /// `decision` (small model) or `main` (Gemma).
  final String engine;

  @override
  Future<(List<double>, int)> score(RenderedPrompt prompt, List<String> options) async {
    final result = (await api.call<Map>('decide', {
      'engine': engine,
      'prompt': prompt.text,
      'staticPrefix': prompt.staticPrefix,
      'options': options,
    }))!;
    return (
      [for (final v in result['logProbs'] as List) (v as num).toDouble()],
      (result['ms'] as num).toInt(),
    );
  }

  @override
  Future<String> extract(RenderedPrompt prompt, String grammar) async {
    if (engine == 'main') {
      return (await api.call<String>('llmGenerate', {
            'id': 'slots',
            'prompt': prompt.text,
            'grammar': grammar,
            'maxTokens': 80,
            'temperature': 0.0,
          })) ??
          '';
    }
    return (await api.call<String>('decisionGenerate', {
          'prompt': prompt.text,
          'staticPrefix': prompt.staticPrefix,
          'grammar': grammar,
          'maxTokens': 80,
        })) ??
        '';
  }
}

/// Scores a model on the labeled turns in `decision_eval.jsonl`.
Future<Map<String, dynamic>> runDecisionEval({
  required DecisionBackend backend,
  required PromptFormat format,
  required File dataset,
  required String modelName,
  double minProbability = 0.6,
  double minMargin = 0.2,
  DecisionStyle style = DecisionStyle.choice,
}) async {
  final router = DecisionRouter(backend, format, minProbability: minProbability, minMargin: minMargin, style: style);
  final rows = [
    for (final line in await dataset.readAsLines())
      if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast<String, dynamic>(),
  ];
  final results = <Map<String, dynamic>>[];
  var correct = 0, routedCorrect = 0, routed = 0, slotChecks = 0, slotHits = 0;
  final scoreTimes = <int>[], extractTimes = <int>[];
  for (final row in rows) {
    final step = decisionSteps[row['step']]!;
    final caller = row['caller'] as String;
    final gold = row['label'] as String;
    final result = await router.route(step, caller);
    final ok = result.label == gold;
    if (ok) correct++;
    if (!result.escalate) {
      routed++;
      if (ok) routedCorrect++;
    }
    final goldSlots = (row['slots'] as Map?)?.cast<String, dynamic>() ?? const {};
    var slotOk = true;
    if (goldSlots.isNotEmpty && !result.escalate && ok) {
      for (final entry in goldSlots.entries) {
        slotChecks++;
        final value = (result.slots[entry.key] ?? '').toLowerCase();
        final hit = value.contains(entry.value.toString().toLowerCase());
        if (hit) slotHits++;
        slotOk &= hit;
      }
    }
    scoreTimes.add(result.scoreMs);
    if (result.extractMs > 0) extractTimes.add(result.extractMs);
    results.add({
      'step': row['step'],
      'caller': caller,
      'gold': gold,
      'predicted': result.label,
      'probability': double.parse(result.probability.toStringAsFixed(3)),
      'margin': double.parse(result.margin.toStringAsFixed(3)),
      'escalate': result.escalate,
      'slots': result.slots,
      'slots_ok': slotOk,
      'score_ms': result.scoreMs,
      'extract_ms': result.extractMs,
    });
  }
  int median(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  int p90(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    return sorted[(sorted.length * 0.9).floor().clamp(0, sorted.length - 1)];
  }

  // Escalation that would have been right: off-script turns, or turns the
  // model would otherwise have gotten wrong.
  final summary = {
    'model': modelName,
    'style': style.name,
    'turns': rows.length,
    'accuracy': double.parse((correct / rows.length).toStringAsFixed(3)),
    'handled_by_small_model': routed,
    'escalated': rows.length - routed,
    'accuracy_when_handled': routed == 0 ? 0 : double.parse((routedCorrect / routed).toStringAsFixed(3)),
    'wrong_and_not_escalated': routed - routedCorrect,
    'slot_accuracy': slotChecks == 0 ? null : double.parse((slotHits / slotChecks).toStringAsFixed(3)),
    'score_ms_median': median(scoreTimes),
    'score_ms_p90': p90(scoreTimes),
    'extract_ms_median': median(extractTimes),
    'min_probability': minProbability,
    'min_margin': minMargin,
  };
  return {'summary': summary, 'results': results};
}

/// Scores the context-aware model on `decision_eval_v2.jsonl` (conversations
/// built from published scam scripts, look-alike legitimate calls and
/// ambiguous openings). A "wrongful hang-up" is a non-spam turn classified as
/// spam with enough confidence to end the call.
Future<Map<String, dynamic>> runContextEval({
  required DecisionBackend backend,
  required PromptFormat format,
  required File dataset,
  required String modelName,
}) async {
  final router = DecisionRouter(backend, format, style: DecisionStyle.context);
  final rows = [
    for (final line in await dataset.readAsLines())
      if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast<String, dynamic>(),
  ];
  final results = <Map<String, dynamic>>[];
  var correct = 0, spamGold = 0, spamCaught = 0, wrongfulHangups = 0, clarifyGold = 0, clarifyHit = 0;
  final times = <int>[];
  for (final row in rows) {
    final lines = [
      for (final c in row['context'] as List) ConversationLine((c as List)[0] == 'assistant', c[1].toString()),
      ConversationLine(false, row['caller'] as String),
    ];
    router.conversation = lines;
    final step = contextSteps[row['workflow']]!;
    final result = await router.route(step, row['caller'] as String, extractSlots: false);
    final gold = row['label'] as String;
    if (result.label == gold) correct++;
    // Same hang-up rule as the live receptionist.
    final hangsUp = shouldHangUpAsSpam(result.label, result.probability, row['caller'] as String);
    if (gold == 'spam') {
      spamGold++;
      if (hangsUp) spamCaught++;
    } else if (hangsUp) {
      wrongfulHangups++;
    }
    if (gold == 'clarify') {
      clarifyGold++;
      if (result.label == 'clarify') clarifyHit++;
    }
    times.add(result.scoreMs);
    results.add({
      'caller': row['caller'],
      'turn': lines.where((l) => !l.assistant).length,
      'gold': gold,
      'predicted': result.label,
      'probability': double.parse(result.probability.toStringAsFixed(3)),
      'ms': result.scoreMs,
    });
  }
  times.sort();
  return {
    'summary': {
      'model': modelName,
      'turns': rows.length,
      'accuracy': double.parse((correct / rows.length).toStringAsFixed(3)),
      'spam_caught': '$spamCaught/$spamGold',
      'wrongful_hangups': wrongfulHangups,
      'clarify_asked': '$clarifyHit/$clarifyGold',
      'ms_median': times.isEmpty ? 0 : times[times.length ~/ 2],
    },
    'results': results,
  };
}

/// Scores outbound decisions (`outbound_eval.jsonl`): what answered the call
/// (person, voicemail, menu, hold) and the other side's turns while
/// scheduling.
Future<Map<String, dynamic>> runOutboundEval({
  required DecisionBackend backend,
  required PromptFormat format,
  required File dataset,
  required String modelName,
}) async {
  final router = DecisionRouter(backend, format, style: DecisionStyle.context);
  final rows = [
    for (final line in await dataset.readAsLines())
      if (line.trim().isNotEmpty) (jsonDecode(line) as Map).cast<String, dynamic>(),
  ];
  var correct = 0, lineCorrect = 0, lineTotal = 0;
  final results = <Map<String, dynamic>>[];
  final times = <int>[];
  for (final row in rows) {
    final lines = [
      for (final c in row['context'] as List)
        ConversationLine((c as List)[0] == 'assistant', c[1].toString(), otherSpeaker: 'Other'),
      ConversationLine(false, row['other'] as String, otherSpeaker: 'Other'),
    ];
    router.conversation = lines;
    final result = await router.route(contextSteps[row['step']]!, row['other'] as String, extractSlots: false);
    var predicted = outboundOverride(row['step'] as String, row['other'] as String, result.label);
    if (row['step'] == 'line' && predicted != 'person' && chooseMenuDigit(row['other'] as String, 'book an appointment') != null) {
      predicted = 'menu';
    }
    final ok = predicted == row['label'];
    if (ok) correct++;
    if (row['step'] == 'line') {
      lineTotal++;
      if (ok) lineCorrect++;
    }
    times.add(result.scoreMs);
    results.add({'other': row['other'], 'gold': row['label'], 'predicted': predicted, 'model': result.label,
        'probability': double.parse(result.probability.toStringAsFixed(3))});
  }
  times.sort();
  return {
    'summary': {
      'model': modelName,
      'turns': rows.length,
      'accuracy': double.parse((correct / rows.length).toStringAsFixed(3)),
      'answered_by_detection': '$lineCorrect/$lineTotal',
      'conversation': '${correct - lineCorrect}/${rows.length - lineTotal}',
      'ms_median': times.isEmpty ? 0 : times[times.length ~/ 2],
    },
    'results': results,
  };
}
