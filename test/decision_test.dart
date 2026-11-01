import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:android_ai_receptionist/src/decision.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeBackend implements DecisionBackend {
  FakeBackend(this.probabilities, this.slots);
  final Map<String, double> probabilities;
  final String slots;
  final prompts = <String>[];

  @override
  Future<(List<double>, int)> score(RenderedPrompt prompt, List<String> options) async {
    prompts.add(prompt.text);
    return ([for (final o in options) math.log(probabilities[o] ?? 1e-6)], 5);
  }

  @override
  Future<String> extract(RenderedPrompt prompt, String grammar) async => slots;
}

void main() {
  final step = decisionSteps['screen_open']!;

  test('confident choice with grounded slots is handled locally', () async {
    final backend = FakeBackend({'identify': 0.9, 'spam': 0.05, 'other': 0.05}, '{"name": "Alex", "reason": "dental cleaning"}');
    final router = DecisionRouter(backend, PromptFormat.chatml);
    final result = await router.route(step, 'Hi, this is Alex calling about a dental cleaning.');
    expect(result.label, 'identify');
    expect(result.escalate, isFalse);
    expect(result.slots['name'], 'Alex');
    expect(backend.prompts.single, contains('<|im_start|>assistant\n'));
    expect(backend.prompts.single, contains('Choose one: identify, spam, message, goodbye, other'));
    expect(backend.prompts.single, contains("Rachel from the vet"));
  });

  test('low confidence, other and ungrounded slots escalate', () async {
    final unsure = await DecisionRouter(FakeBackend({'identify': 0.5, 'spam': 0.4}, '{}'), PromptFormat.chatml)
        .route(step, 'umm well');
    expect(unsure.escalate, isTrue);
    final other = await DecisionRouter(FakeBackend({'other': 0.95}, '{}'), PromptFormat.gemma)
        .route(step, 'Are you a robot?');
    expect(other.escalate, isTrue);
    final invented = await DecisionRouter(
            FakeBackend({'identify': 0.95}, '{"name": "Robert Smith", "reason": "insurance"}'), PromptFormat.chatml)
        .route(step, 'Hi, this is Alex about my cleaning.');
    expect(invented.escalate, isTrue);
  });

  test('binary style asks one yes/no question per option', () async {
    // Neutral baseline 0.5 everywhere; the caller's words raise "identify".
    final backend = _YesNo((p) => p.contains('Alex') && p.contains('saying who they are') ? 0.92 : 0.5);
    final result = await DecisionRouter(backend, PromptFormat.chatml, style: DecisionStyle.binary)
        .route(step, 'This is Alex from the dentist.', extractSlots: false);
    expect(backend.prompts.length, step.options.length * 2); // baseline + caller
    expect(backend.prompts.last, contains('Question: Is the caller saying goodbye'));
    expect(result.label, 'identify');
    expect(result.escalate, isFalse);
    final none = await DecisionRouter(_YesNo((p) => 0.5), PromptFormat.chatml, style: DecisionStyle.binary)
        .route(step, 'Are you a robot?', extractSlots: false);
    expect(none.escalate, isTrue);
  });

  test('binary style removes a uniform yes bias', () async {
    // Says yes to everything, but more strongly for the true option.
    final backend = _YesNo((p) => p.contains('Alex') && p.contains('saying who they are') ? 0.9995 : 0.95);
    final result = await DecisionRouter(backend, PromptFormat.chatml, style: DecisionStyle.binary)
        .route(step, 'This is Alex from the dentist.', extractSlots: false);
    expect(result.label, 'identify');
    expect(result.escalate, isFalse);
  });

  test('tuned prompts match the fine-tuning format', () {
    final generator = File('tool/finetune/generate_data.py').readAsStringSync();
    expect(generator, contains("DECISION_SYSTEM = \"$tunedDecisionSystem\""));
    final prompt = renderTunedDecisionPrompt(PromptFormat.chatml, step, 'Hi there').text;
    expect(prompt, endsWith('Choose one: identify, spam, message, goodbye, other<|im_end|>\n<|im_start|>assistant\n'));
    expect(prompt, contains('Assistant: "May I ask who is calling and what it is about?"\nCaller: "Hi there"'));
  });

  test('slot grammar lists exactly the option slots', () {
    final grammar = slotGrammar(step.options.first);
    expect(grammar, contains(r'\"name\": '));
    expect(grammar, contains(r'\"reason\": '));
  });

  test('few-shot examples never leak evaluation turns', () {
    final eval = File('test/fixtures/decision_eval.jsonl').readAsStringSync().toLowerCase();
    final prompt = renderDecisionPrompt(PromptFormat.chatml, step, 'x').staticPrefix;
    for (final line in RegExp(r'Caller: "([^"]+)"').allMatches(prompt)) {
      expect(eval.contains(line.group(1)!.toLowerCase()), isFalse, reason: line.group(1));
    }
  });

  test('evaluation set labels match their steps', () {
    final lines = File('test/fixtures/decision_eval.jsonl').readAsLinesSync().where((l) => l.trim().isNotEmpty);
    expect(lines.length, greaterThan(80));
    for (final line in lines) {
      final row = jsonDecode(line) as Map<String, dynamic>;
      final step = decisionSteps[row['step']];
      expect(step, isNotNull, reason: line);
      expect(step!.allOptions.map((o) => o.label), contains(row['label']), reason: line);
    }
  });
}

class _YesNo implements DecisionBackend {
  _YesNo(this.yes);
  final double Function(String prompt) yes;
  final prompts = <String>[];

  @override
  Future<(List<double>, int)> score(RenderedPrompt prompt, List<String> options) async {
    prompts.add(prompt.text);
    final p = yes(prompt.text);
    return ([math.log(p), math.log(1 - p)], 3);
  }

  @override
  Future<String> extract(RenderedPrompt prompt, String grammar) async => '{}';
}
