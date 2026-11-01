import 'dart:convert';
import 'dart:math' as math;

/// One choice the caller's turn can map to at a workflow step.
class DecisionOption {
  const DecisionOption(this.label, this.description, {this.slots = const {}, this.question = ''});
  final String label;
  final String description;

  /// Yes/no question used by [DecisionStyle.binary].
  final String question;

  /// Slot name → what to extract, e.g. {'name': "the caller's name"}.
  final Map<String, String> slots;
}

/// A point in a prebuilt workflow where the receptionist has just spoken and
/// must decide what the caller wants.
class DecisionStep {
  const DecisionStep(this.id, this.assistantSaid, this.options);
  final String id;
  final String assistantSaid;
  final List<DecisionOption> options;

  /// The escape hatch: anything off-script goes to the large model.
  static const escalate = DecisionOption('other',
      'asks a question, makes small talk, says something unclear, or anything that does not fit the other options');

  List<DecisionOption> get allOptions => [...options, escalate];
}

const _identify = DecisionOption('identify', 'says who they are or why they are calling',
    question: 'Is the caller saying who they are or why they are calling?',
    slots: {'name': "the caller's name or company, or empty", 'reason': 'why they are calling, or empty'});
const _spam = DecisionOption('spam',
    'is a sales pitch, robocall, survey, warranty, prize, loan or debt offer, or a scam',
    question: 'Is this a sales pitch, robocall, survey, prize, loan or debt offer, or a scam?');
const _message = DecisionOption('message', 'wants to leave a message or asks for someone to call them back',
    question: 'Does the caller want to leave a message or be called back?',
    slots: {'message': 'the message to pass on, in their words'});
const _availability = DecisionOption('availability',
    'asks when the owner is free, wants to meet, or asks about a day or time',
    question: 'Is the caller asking when someone is free, or about a day or time to meet?',
    slots: {'day': 'the day they mention, or empty', 'time': 'the time they mention, or empty'});
const _goodbye = DecisionOption('goodbye', 'says goodbye, thanks and ends, or has nothing else',
    question: 'Is the caller saying goodbye or that they need nothing else?');

/// Built-in workflow steps used by the receptionist and the evaluation.
const decisionSteps = <String, DecisionStep>{
  'screen_open': DecisionStep('screen_open', 'May I ask who is calling and what it is about?',
      [_identify, _spam, _message, _goodbye]),
  'known_open': DecisionStep('known_open', "Sam can't come to the phone right now. How can I help?",
      [_availability, _message, _goodbye]),
  'anything_else': DecisionStep('anything_else', 'Is there anything else I can help you with?',
      [_goodbye, _message, _availability]),
};

enum PromptFormat { gemma, chatml }

/// `choice`: pick one option word at once, few-shot (Gemma-size models).
/// `binary`: one yes/no question per option.
/// `tuned`: compact single-turn prompts (first fine-tuned model).
/// `context`: the conversation so far (context-aware fine-tuned model).
enum DecisionStyle { choice, binary, tuned, context }

// Must match tool/finetune/generate_dialogues.py exactly.
const contextDecisionSystem =
    "Decide the receptionist's next action from the phone conversation. Answer with one option word.";
const contextMaxLines = 7;

const _clarify = DecisionOption('clarify', "the caller's intent or objective is not clear yet");

/// Option sets for the context-aware model, by workflow. `line` and
/// `outbound` are used when the assistant places a call itself.
const contextSteps = <String, DecisionStep>{
  'screen': DecisionStep('screen', '', [_identify, _message, _clarify, _spam, _goodbye]),
  'known': DecisionStep('known', '', [_availability, _message, _clarify, _goodbye]),
  'line': DecisionStep('line', '', [
    DecisionOption('person', 'a live person answered'),
    DecisionOption('voicemail', 'an answering machine or voicemail greeting'),
    DecisionOption('menu', 'an automated phone menu'),
    DecisionOption('hold', 'a hold message or hold music'),
  ]),
  'outbound': DecisionStep('outbound', '', [
    DecisionOption('offer_time', 'proposes a specific day or time',
        slots: {'day': 'the day they offer, or empty', 'time': 'the time they offer, or empty'}),
    DecisionOption('ask_time', 'asks when the owner is free'),
    DecisionOption('confirm', 'agrees or confirms'),
    DecisionOption('ask_info', 'asks for a name, number or details'),
    DecisionOption('transfer', 'will transfer the call or asks to hold'),
    DecisionOption('wrong_person', 'says this is the wrong person or department'),
    DecisionOption('decline', 'cannot help or has nothing available'),
    DecisionOption('goodbye', 'is ending the call'),
  ]),
};

/// One line of the conversation as the model sees it.
class ConversationLine {
  const ConversationLine(this.assistant, this.text, {this.otherSpeaker = 'Caller'});
  final bool assistant;
  final String text;

  /// How the other party is labelled: "Caller" inbound, "Other" when the
  /// assistant placed the call.
  final String otherSpeaker;
  String get rendered =>
      '${assistant ? 'Assistant' : otherSpeaker}: ${text.replaceAll(RegExp(r'\s+'), ' ').trim()}';
}

RenderedPrompt renderContextDecisionPrompt(PromptFormat format, DecisionStep step, List<ConversationLine> lines) {
  final recent = lines.length > contextMaxLines ? lines.sublist(lines.length - contextMaxLines) : lines;
  return _render(format, contextDecisionSystem,
      'Conversation:\n${recent.map((l) => l.rendered).join('\n')}\n'
      'Choose one: ${step.allOptions.map((o) => o.label).join(', ')}');
}

// Must match tool/finetune/generate_data.py exactly.
const tunedDecisionSystem = "Classify the caller's turn in a phone call. Answer with one option word.";
const tunedSlotSystem = "Extract details from the caller's words as JSON. Copy their words; use \"\" when not said.";

RenderedPrompt renderTunedDecisionPrompt(PromptFormat format, DecisionStep step, String callerSaid) =>
    _render(format, tunedDecisionSystem,
        'Assistant: "${_clean(step.assistantSaid)}"\nCaller: "${_clean(callerSaid)}"\n'
        'Choose one: ${step.allOptions.map((o) => o.label).join(', ')}');

RenderedPrompt renderTunedSlotPrompt(PromptFormat format, DecisionOption option, String callerSaid) =>
    _render(format, tunedSlotSystem, 'Caller: "${_clean(callerSaid)}"\nFields: ${option.slots.keys.join(', ')}');

PromptFormat formatForModel(String modelFile) =>
    modelFile.toLowerCase().contains('gemma') ? PromptFormat.gemma : PromptFormat.chatml;

const _decisionSystem = 'You read one turn of a phone call handled by an assistant and decide what the caller '
    'wants. Reply with exactly one option word from the list and nothing else.';

const _slotSystem = 'You extract details from what a caller said on the phone. Copy their words; never invent. '
    'Use an empty string when a detail was not said.';

/// A rendered prompt plus the static prefix worth caching between turns.
class RenderedPrompt {
  RenderedPrompt(this.text, this.staticPrefix);
  final String text;
  final String staticPrefix;
}

RenderedPrompt _render(PromptFormat format, String system, String user) {
  switch (format) {
    case PromptFormat.gemma:
      final prefix = '<bos><|turn>system\n$system<turn|>\n';
      return RenderedPrompt('$prefix<|turn>user\n$user<turn|>\n<|turn>model\n', prefix);
    case PromptFormat.chatml:
      final prefix = '<|im_start|>system\n$system<|im_end|>\n';
      return RenderedPrompt('$prefix<|im_start|>user\n$user<|im_end|>\n<|im_start|>assistant\n', prefix);
  }
}

String _clean(String text) => text.replaceAll('"', "'").replaceAll(RegExp(r'\s+'), ' ').trim();

/// Worked examples, given as earlier chat turns in the cached static prefix.
/// None of them appear in the evaluation set.
const _examples = <(String, String, List<String>, String)>[
  ('May I ask who is calling and what it is about?', 'Hey, it\'s Rachel from the vet, Biscuit\'s vaccines are due.',
      ['identify', 'spam', 'message', 'goodbye', 'other'], 'identify'),
  ('May I ask who is calling and what it is about?', 'This is a courtesy call about lowering your energy bill today.',
      ['identify', 'spam', 'message', 'goodbye', 'other'], 'spam'),
  ('May I ask who is calling and what it is about?', 'Could you have Sam ring me back about the quote?',
      ['identify', 'spam', 'message', 'goodbye', 'other'], 'message'),
  ('May I ask who is calling and what it is about?', 'Is this the right number for the pharmacy?',
      ['identify', 'spam', 'message', 'goodbye', 'other'], 'other'),
  ('May I ask who is calling and what it is about?', 'Ah, okay, I\'ll just try later, thanks.',
      ['identify', 'spam', 'message', 'goodbye', 'other'], 'goodbye'),
  ('How can I help?', 'Is Sam around next Tuesday evening?', ['availability', 'message', 'goodbye', 'other'], 'availability'),
  ('How can I help?', 'Tell Sam the plumber is coming at nine.', ['availability', 'message', 'goodbye', 'other'], 'message'),
  ('How can I help?', 'Where did Sam park the car?', ['availability', 'message', 'goodbye', 'other'], 'other'),
  ('How can I help?', 'Oh nothing, bye now.', ['availability', 'message', 'goodbye', 'other'], 'goodbye'),
  ('Is there anything else I can help you with?', 'No, that covers it.',
      ['goodbye', 'message', 'availability', 'other'], 'goodbye'),
  ('Is there anything else I can help you with?', 'Also ask Sam to grab milk on the way home.',
      ['goodbye', 'message', 'availability', 'other'], 'message'),
  ('Is there anything else I can help you with?', 'Can you spell your name?',
      ['goodbye', 'message', 'availability', 'other'], 'other'),
];

const _optionHelp = {
  'identify': 'says who they are or why they are calling',
  'spam': 'sales pitch, robocall, survey, warranty, prize, loan, debt or scam',
  'message': 'wants to leave a message or be called back',
  'availability': 'asks when the owner is free, or about a day or time to meet',
  'goodbye': 'ends the call or has nothing else',
  'other': 'a question, small talk, unclear, or anything else',
};

String _turn(String assistantSaid, String callerSaid, List<String> labels) =>
    'Assistant: "${_clean(assistantSaid)}"\nCaller: "${_clean(callerSaid)}"\nChoose one: ${labels.join(', ')}';

/// Few-shot decision prompt: the examples are prior chat turns, the answer is
/// a single option word scored by its log-probability.
RenderedPrompt renderDecisionPrompt(PromptFormat format, DecisionStep step, String callerSaid) {
  final glossary = _optionHelp.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  final system = '$_decisionSystem\n\nOption meanings:\n$glossary';
  final shots = [for (final e in _examples) (_turn(e.$1, e.$2, e.$3), e.$4)];
  final labels = [for (final o in step.allOptions) o.label];
  final question = _turn(step.assistantSaid, callerSaid, labels);
  switch (format) {
    case PromptFormat.gemma:
      final prefix = StringBuffer('<bos><|turn>system\n$system<turn|>\n');
      for (final (q, a) in shots) {
        prefix.write('<|turn>user\n$q<turn|>\n<|turn>model\n$a<turn|>\n');
      }
      return RenderedPrompt('$prefix<|turn>user\n$question<turn|>\n<|turn>model\n', prefix.toString());
    case PromptFormat.chatml:
      final prefix = StringBuffer('<|im_start|>system\n$system<|im_end|>\n');
      for (final (q, a) in shots) {
        prefix.write('<|im_start|>user\n$q<|im_end|>\n<|im_start|>assistant\n$a<|im_end|>\n');
      }
      return RenderedPrompt('$prefix<|im_start|>user\n$question<|im_end|>\n<|im_start|>assistant\n', prefix.toString());
  }
}

const _binarySystem = 'You answer yes or no about what a caller just said on a phone call. '
    'Answer with one word: yes or no.';

/// Yes/no question for one option. Everything up to the question is the
/// static prefix, so the caller's words are read once per turn.
RenderedPrompt renderBinaryPrompt(PromptFormat format, DecisionStep step, String callerSaid, DecisionOption option) {
  final context = 'The assistant said: "${_clean(step.assistantSaid)}"\nThe caller said: "${_clean(callerSaid)}"\n';
  final question = 'Question: ${option.question}';
  switch (format) {
    case PromptFormat.gemma:
      final prefix = '<bos><|turn>system\n$_binarySystem<turn|>\n<|turn>user\n$context';
      return RenderedPrompt('$prefix$question<turn|>\n<|turn>model\n', prefix);
    case PromptFormat.chatml:
      final prefix = '<|im_start|>system\n$_binarySystem<|im_end|>\n<|im_start|>user\n$context';
      return RenderedPrompt('$prefix$question<|im_end|>\n<|im_start|>assistant\n', prefix);
  }
}

/// Answer strings scored for each option, in order.
List<String> decisionAnswers(DecisionStep step) => [for (final o in step.allOptions) o.label];

RenderedPrompt renderSlotPrompt(PromptFormat format, DecisionOption option, String callerSaid) {
  final fields = option.slots.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  final user = 'The caller said: "${_clean(callerSaid)}"\n\nExtract as JSON:\n$fields';
  return _render(format, _slotSystem, user);
}

/// GBNF for `{"slot": "...", ...}` with exactly the option's slots.
String slotGrammar(DecisionOption option) {
  String literal(String text) => '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  final keys = option.slots.keys.toList();
  final body = StringBuffer(literal('{'));
  for (var i = 0; i < keys.length; i++) {
    body.write(' ${literal('${i == 0 ? '' : ', '}"${keys[i]}": ')} str');
  }
  body.write(' "}"');
  return [
    'root ::= $body',
    r'str ::= "\"" chr{0,120} "\""',
    r'chr ::= [^"\\\x00-\x1F] | "\\" ["\\/nt]',
  ].join('\n');
}

/// The small (or large) model behind a decision.
abstract class DecisionBackend {
  /// Normalised log-probabilities for each option, in order.
  Future<(List<double>, int)> score(RenderedPrompt prompt, List<String> options);
  Future<String> extract(RenderedPrompt prompt, String grammar);
}

class RouteResult {
  RouteResult({
    required this.label,
    required this.probability,
    required this.margin,
    required this.escalate,
    required this.slots,
    required this.scoreMs,
    required this.extractMs,
    required this.probabilities,
  });

  final String label;
  final double probability;

  /// Top probability minus the runner-up's.
  final double margin;

  /// True when the large model should handle this turn.
  final bool escalate;
  final Map<String, String> slots;
  final int scoreMs;
  final int extractMs;
  final Map<String, double> probabilities;
}

class DecisionRouter {
  DecisionRouter(this.backend, this.format,
      {this.minProbability = 0.6, this.minMargin = 0.2, this.style = DecisionStyle.choice});
  final DecisionBackend backend;
  final PromptFormat format;
  final double minProbability;
  final double minMargin;
  final DecisionStyle style;

  /// Conversation so far (ending with the caller's latest line) for [DecisionStyle.context].
  List<ConversationLine>? conversation;

  Future<(Map<String, double>, int)> _choice(DecisionStep step, String callerSaid) async {
    final options = step.allOptions;
    final prompt = switch (style) {
      DecisionStyle.context => renderContextDecisionPrompt(
          format, step, conversation ?? [ConversationLine(false, callerSaid)]),
      DecisionStyle.tuned => renderTunedDecisionPrompt(format, step, callerSaid),
      _ => renderDecisionPrompt(format, step, callerSaid),
    };
    final (logProbs, ms) = await backend.score(prompt, decisionAnswers(step));
    return ({for (var i = 0; i < options.length; i++) options[i].label: math.exp(logProbs[i])}, ms);
  }

  /// Log-odds of "yes" for a neutral caller line, per step and option. Tiny
  /// models answer "yes" to almost everything; subtracting this baseline
  /// (contextual calibration) leaves the evidence that is in the caller's words.
  final Map<String, double> _baseline = {};

  Future<(double, int)> _yesLogOdds(DecisionStep step, String callerSaid, DecisionOption option) async {
    final (logProbs, took) =
        await backend.score(renderBinaryPrompt(format, step, callerSaid, option), const ['yes', 'no']);
    return (logProbs[0] - logProbs[1], took);
  }

  /// Calibrated yes-evidence per option, turned into probabilities with a
  /// softmax that includes "other" at zero evidence.
  Future<(Map<String, double>, int)> _binary(DecisionStep step, String callerSaid) async {
    final evidence = <String, double>{};
    var ms = 0;
    for (final option in step.options) {
      final key = '${step.id}/${option.label}';
      if (!_baseline.containsKey(key)) {
        final (base, took) = await _yesLogOdds(step, 'Hello.', option);
        _baseline[key] = base;
        ms += took;
      }
      final (odds, took) = await _yesLogOdds(step, callerSaid, option);
      evidence[option.label] = odds - _baseline[key]!;
      ms += took;
    }
    evidence[DecisionStep.escalate.label] = 0;
    final maxEvidence = evidence.values.fold<double>(-1e9, math.max);
    final total = evidence.values.fold<double>(0, (sum, v) => sum + math.exp(v - maxEvidence));
    return ({for (final e in evidence.entries) e.key: math.exp(e.value - maxEvidence) / total}, ms);
  }

  /// [extractFor], when given, limits slot extraction to those labels (e.g.
  /// skip it for turns the caller will hand to the large model anyway).
  Future<RouteResult> route(DecisionStep step, String callerSaid,
      {bool extractSlots = true, Set<String>? extractFor}) async {
    final options = step.allOptions;
    final (probabilities, scoreMs) =
        style == DecisionStyle.binary ? await _binary(step, callerSaid) : await _choice(step, callerSaid);
    final ranked = probabilities.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    final margin = best.value - (ranked.length > 1 ? ranked[1].value : 0);
    final option = options.firstWhere((o) => o.label == best.key);
    var escalate = option.label == DecisionStep.escalate.label || best.value < minProbability || margin < minMargin;
    var slots = <String, String>{};
    var extractMs = 0;
    if (!escalate && extractSlots && option.slots.isNotEmpty && (extractFor?.contains(option.label) ?? true)) {
      final started = DateTime.now();
      final slotPrompt = style == DecisionStyle.tuned || style == DecisionStyle.context
          ? renderTunedSlotPrompt(format, option, callerSaid)
          : renderSlotPrompt(format, option, callerSaid);
      final raw = await backend.extract(slotPrompt, slotGrammar(option));
      extractMs = DateTime.now().difference(started).inMilliseconds;
      try {
        slots = {
          for (final e in (jsonDecode(raw) as Map).entries) e.key.toString(): e.value.toString().trim(),
        };
      } on FormatException {
        escalate = true;
      }
      // Never trust a slot value the caller did not actually say.
      for (final entry in slots.entries) {
        if (entry.value.isNotEmpty && !groundedIn(entry.value, callerSaid)) {
          escalate = true;
        }
      }
    }
    return RouteResult(
      label: option.label,
      probability: best.value,
      margin: margin,
      escalate: escalate,
      slots: slots,
      scoreMs: scoreMs,
      extractMs: extractMs,
      probabilities: probabilities,
    );
  }
}

/// True when most words of [value] appear in [source].
bool groundedIn(String value, String source) {
  List<String> words(String s) =>
      s.toLowerCase().replaceAll(RegExp(r"[^a-z0-9' ]"), ' ').split(' ').where((w) => w.length > 2).toList();
  final wanted = words(value);
  if (wanted.isEmpty) return true;
  final have = words(source).toSet();
  final found = wanted.where(have.contains).length;
  return found / wanted.length >= 0.6;
}
