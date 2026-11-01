import 'dart:convert';
import 'intents.dart';

typedef Json = Map<String, dynamic>;

/// A contact the receptionist recognises. `workflow` may be `known` (default)
/// or `block` to always reject this number.
class ContactEntry {
  ContactEntry({
    required this.name,
    required this.numbers,
    this.relationship = '',
    this.notes = '',
    this.workflow = 'known',
  });

  final String name;
  final List<String> numbers;
  final String relationship;
  final String notes;
  final String workflow;

  factory ContactEntry.fromJson(Json json) => ContactEntry(
        name: (json['name'] ?? '').toString(),
        numbers: [for (final n in (json['numbers'] as List? ?? const [])) n.toString()],
        relationship: (json['relationship'] ?? '').toString(),
        notes: (json['notes'] ?? '').toString(),
        workflow: (json['workflow'] ?? 'known').toString(),
      );

  Json toJson() => {
        'name': name,
        'numbers': numbers,
        if (relationship.isNotEmpty) 'relationship': relationship,
        if (notes.isNotEmpty) 'notes': notes,
        if (workflow != 'known') 'workflow': workflow,
      };
}

/// Decides which unknown callers/texters are screened instead of blocked.
/// Types: `any`, `prefix` (number starts with value), `regex`, `withheld`.
class ScreeningRule {
  ScreeningRule(this.type, [this.value = '']);
  final String type;
  final String value;

  factory ScreeningRule.fromJson(Json json) =>
      ScreeningRule((json['type'] ?? '').toString(), (json['value'] ?? '').toString());
  Json toJson() => {'type': type, if (value.isNotEmpty) 'value': value};
}

/// Prompt and tool selection for one workflow (`known` or `screen`).
class WorkflowConfig {
  WorkflowConfig({
    required this.instructions,
    required this.greeting,
    required this.smsInstructions,
    required this.tools,
  });

  final String instructions;
  final String greeting;
  final String smsInstructions;
  final List<String> tools;

  factory WorkflowConfig.fromJson(Json json, WorkflowConfig fallback) => WorkflowConfig(
        instructions: (json['instructions'] ?? fallback.instructions).toString(),
        greeting: (json['greeting'] ?? fallback.greeting).toString(),
        smsInstructions: (json['sms_instructions'] ?? fallback.smsInstructions).toString(),
        tools: json['tools'] is List
            ? [for (final t in json['tools'] as List) t.toString()]
            : fallback.tools,
      );

  Json toJson() => {
        'instructions': instructions,
        'greeting': greeting,
        'sms_instructions': smsInstructions,
        'tools': tools,
      };
}

/// A user-defined tool. `action` is one of:
/// `notify` (send the owner a notification from `template`),
/// `record` (save `template` to the activity log), or
/// `reply` (return `template` to the model as the tool result).
/// Templates use `{arg}` placeholders plus `{caller}` and `{number}`.
class CustomTool {
  CustomTool({
    required this.name,
    required this.description,
    required this.args,
    required this.action,
    required this.template,
  });

  final String name;
  final String description;
  final Map<String, String> args;
  final String action;
  final String template;

  factory CustomTool.fromJson(Json json) => CustomTool(
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        args: {
          for (final e in ((json['args'] as Map?) ?? const {}).entries)
            e.key.toString(): e.value.toString(),
        },
        action: (json['action'] ?? 'record').toString(),
        template: (json['template'] ?? '').toString(),
      );

  Json toJson() => {
        'name': name,
        'description': description,
        'args': args,
        'action': action,
        'template': template,
      };
}

class CallAudioConfig {
  CallAudioConfig({
    this.gain = 1.0,
    this.endSilenceSeconds = 1.0,
    this.answerAfterSeconds = 0,
    this.maxCallSeconds = 300,
    this.speakerCaptureSource = 'voice_communication',
    this.speakerPlaybackUsage = 'media',
  });

  /// Calls always run through the shell call-audio helper (caller audio from
  /// the downlink, speech into the uplink). The speaker fields only apply to
  /// the in-app speaker test.
  final double gain;
  final double endSilenceSeconds;
  final int answerAfterSeconds;
  final int maxCallSeconds;
  final String speakerCaptureSource;
  final String speakerPlaybackUsage;

  factory CallAudioConfig.fromJson(Json json) {
    final d = CallAudioConfig();
    return CallAudioConfig(
      gain: (json['gain'] as num?)?.toDouble() ?? d.gain,
      endSilenceSeconds: (json['end_silence_seconds'] as num?)?.toDouble() ?? d.endSilenceSeconds,
      answerAfterSeconds: (json['answer_after_seconds'] as num?)?.toInt() ?? d.answerAfterSeconds,
      maxCallSeconds: (json['max_call_seconds'] as num?)?.toInt() ?? d.maxCallSeconds,
      speakerCaptureSource: (json['speaker_capture_source'] ?? d.speakerCaptureSource).toString(),
      speakerPlaybackUsage: (json['speaker_playback_usage'] ?? d.speakerPlaybackUsage).toString(),
    );
  }

  Json toJson() => {
        'gain': gain,
        'end_silence_seconds': endSilenceSeconds,
        'answer_after_seconds': answerAfterSeconds,
        'max_call_seconds': maxCallSeconds,
        'speaker_capture_source': speakerCaptureSource,
        'speaker_playback_usage': speakerPlaybackUsage,
      };
}

class ReceptionistConfig {
  ReceptionistConfig({
    required this.enabled,
    required this.ownerName,
    required this.assistantName,
    required this.context,
    required this.voice,
    required this.gemmaModel,
    required this.llmThreads,
    required this.llmContext,
    required this.temperature,
    required this.callAudio,
    required this.contacts,
    required this.blockedNumbers,
    required this.usePhoneContacts,
    required this.screeningRules,
    required this.known,
    required this.screen,
    required this.customTools,
    required this.smsReplyLimitPerHour,
    required this.ownerPronouns,
    required this.sttModel,
    required this.blockUnknownTexters,
    required this.warmTransfer,
    required this.embeddingModel,
    required this.intents,
    required this.intentThreshold,
    required this.transferWaitSeconds,
    required this.responder,
    required this.decisionModel,
  });

  final bool enabled;
  final String ownerName;
  final String assistantName;
  final String context;
  final String voice;
  final String gemmaModel;
  final int llmThreads;
  final int llmContext;
  final double temperature;
  final CallAudioConfig callAudio;
  final List<ContactEntry> contacts;
  final List<String> blockedNumbers;
  final bool usePhoneContacts;
  final List<ScreeningRule> screeningRules;
  final WorkflowConfig known;
  final WorkflowConfig screen;
  final List<CustomTool> customTools;
  final int smsReplyLimitPerHour;

  /// How the assistant refers to the owner, e.g. `they/them`, `she/her`.
  final String ownerPronouns;

  /// Speech-to-text model: `parakeet-0.6b` (default), `parakeet-110m`, or a
  /// Whisper export (`tiny.en`, `base.en`, `small.en`).
  final String sttModel;

  /// Add senders of texts from non-contacts to Android's block list, so their
  /// later texts (and calls) never reach the phone.
  final bool blockUnknownTexters;

  /// When a known contact calls, ask the owner to pick up before taking a message.
  final bool warmTransfer;

  /// How long the caller waits for the owner to pick up.
  final int transferWaitSeconds;

  /// On-device sentence-embedding model (models/embedding/) for topic detection.
  final String embeddingModel;

  /// Topics and intents the assistant recognises in what callers say.
  final List<IntentDef> intents;

  /// Minimum similarity for a topic match (0..1).
  final double intentThreshold;

  /// `small_model`: the fine-tuned decision model answers everything (Gemma is
  /// never loaded); anything it cannot handle becomes "take a message".
  /// `tiered`: the small model handles routine turns, Gemma the rest.
  /// `gemma`: Gemma answers every turn.
  final String responder;

  bool get usesSmallModel => responder != 'gemma';
  bool get usesGemma => responder != 'small_model';

  /// Decision model file under models/decision/.
  final String decisionModel;

  static final WorkflowConfig defaultKnown = WorkflowConfig(
    instructions:
        'The caller is someone {owner_name} knows: {caller_name}{caller_details}. Be warm and brief. '
        '{owner_name} is not available right now. Help them by taking a message or checking '
        "{owner_name}'s availability when they want to meet or talk. When they have nothing else, "
        'say goodbye and use end_conversation.',
    greeting: "Hi {caller_first_name}, you've reached {assistant_name}. How can I help?",
    smsInstructions: 'Reply as a short, friendly text message (one or two sentences).',
    tools: ['take_message', 'check_availability', 'remember', 'end_conversation'],
  );

  static final WorkflowConfig defaultScreen = WorkflowConfig(
    instructions: 'The caller is not in the contact list. First find out who they are and why they '
        'are calling, then use record_caller. Do not share any information about {owner_name}, '
        'including their schedule. For a genuine personal or business reason, offer to take a message. '
        'Sales, marketing, warranties, surveys, donations, prize or debt notices, robocalls, and callers who '
        "won't say who they are are spam: never take a message for them. Say a short polite no and use "
        'mark_spam in the same reply; it also ends the call. Example: caller "We\'re calling about your '
        'car\'s extended warranty." -> {"say": "Thanks, but we\'re not interested. Goodbye.", "tool": '
        '{"name": "mark_spam", "args": {"reason": "car warranty sales call"}}}',
    greeting: "Hi, you've reached {assistant_name}. How can I help?",
    smsInstructions: 'Reply as a short, polite text message. Ask who they are if they have not said.',
    tools: ['record_caller', 'take_message', 'remember', 'mark_spam', 'end_conversation'],
  );

  factory ReceptionistConfig.defaults() => ReceptionistConfig.fromJson(const {});

  factory ReceptionistConfig.fromJson(Json json) {
    return ReceptionistConfig(
      enabled: json['enabled'] != false,
      ownerName: (json['owner_name'] ?? 'the owner').toString(),
      assistantName: (json['assistant_name'] ?? "{owner_name}'s AI Assistant").toString(),
      context: (json['context'] ?? '').toString(),
      voice: (json['voice'] ?? 'british_female').toString(),
      gemmaModel: (json['gemma_model'] ?? 'gemma4-e2b-mobile-qat.gguf').toString(),
      llmThreads: (json['llm_threads'] as num?)?.toInt() ?? 6,
      llmContext: (json['llm_context'] as num?)?.toInt() ?? 4096,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.4,
      callAudio: CallAudioConfig.fromJson((json['call_audio'] as Map?)?.cast<String, dynamic>() ?? const {}),
      contacts: [
        for (final c in (json['contacts'] as List? ?? const []))
          ContactEntry.fromJson((c as Map).cast<String, dynamic>()),
      ],
      blockedNumbers: [for (final n in (json['blocked_numbers'] as List? ?? const [])) n.toString()],
      usePhoneContacts: json['use_phone_contacts'] != false,
      screeningRules: json['screening_rules'] is List
          ? [
              for (final r in json['screening_rules'] as List)
                ScreeningRule.fromJson((r as Map).cast<String, dynamic>()),
            ]
          : [ScreeningRule('any')],
      known: WorkflowConfig.fromJson(
          (json['workflows']?['known'] as Map?)?.cast<String, dynamic>() ?? const {}, defaultKnown),
      screen: WorkflowConfig.fromJson(
          (json['workflows']?['screen'] as Map?)?.cast<String, dynamic>() ?? const {}, defaultScreen),
      customTools: [
        for (final t in (json['custom_tools'] as List? ?? const []))
          CustomTool.fromJson((t as Map).cast<String, dynamic>()),
      ],
      smsReplyLimitPerHour: (json['sms_reply_limit_per_hour'] as num?)?.toInt() ?? 6,
      ownerPronouns: (json['owner_pronouns'] ?? 'they/them').toString(),
      sttModel: (json['stt_model'] ?? 'parakeet-0.6b').toString(),
      blockUnknownTexters: json['block_unknown_texters'] != false,
      warmTransfer: json['warm_transfer'] != false,
      transferWaitSeconds: (json['transfer_wait_seconds'] as num?)?.toInt() ?? 25,
      embeddingModel: (json['embedding_model'] ?? 'bge-small-en-v1.5-q8_0.gguf').toString(),
      intents: json['intents'] is List
          ? [for (final i in json['intents'] as List) if (i is Map) IntentDef.fromJson(i.cast<String, dynamic>())]
          : IntentDef.defaults,
      intentThreshold: (json['intent_threshold'] as num?)?.toDouble() ?? 0.70,
      responder: (json['responder'] ?? (json['fast_decisions'] == true ? 'tiered' : 'small_model')).toString(),
      decisionModel: (json['decision_model'] ?? 'receptionist-decision-v2-350m-q8_0.gguf').toString(),
    );
  }

  Json toJson() => {
        'enabled': enabled,
        'owner_name': ownerName,
        'owner_pronouns': ownerPronouns,
        'assistant_name': assistantName,
        'context': context,
        'voice': voice,
        'gemma_model': gemmaModel,
        'llm_threads': llmThreads,
        'llm_context': llmContext,
        'temperature': temperature,
        'call_audio': callAudio.toJson(),
        'contacts': [for (final c in contacts) c.toJson()],
        'blocked_numbers': blockedNumbers,
        'use_phone_contacts': usePhoneContacts,
        'screening_rules': [for (final r in screeningRules) r.toJson()],
        'workflows': {'known': known.toJson(), 'screen': screen.toJson()},
        'custom_tools': [for (final t in customTools) t.toJson()],
        'sms_reply_limit_per_hour': smsReplyLimitPerHour,
        'stt_model': sttModel,
        'block_unknown_texters': blockUnknownTexters,
        'warm_transfer': warmTransfer,
        'transfer_wait_seconds': transferWaitSeconds,
        'embedding_model': embeddingModel,
        'intents': [for (final i in intents) i.toJson()],
        'intent_threshold': intentThreshold,
        'responder': responder,
        'decision_model': decisionModel,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  ReceptionistConfig copyWith({bool? enabled}) =>
      ReceptionistConfig.fromJson({...toJson(), 'enabled': ?enabled});

  /// Returns human-readable problems; empty when valid.
  static List<String> validate(String text) {
    final problems = <String>[];
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      return ['Invalid JSON: ${e.message}'];
    }
    if (decoded is! Map) return ['The configuration must be a JSON object.'];
    final config = ReceptionistConfig.fromJson(decoded.cast<String, dynamic>());
    const builtIn = {
      'take_message', 'check_availability', 'record_caller', 'end_conversation', 'notify_owner',
      'remember', 'mark_spam',
    };
    final custom = {for (final t in config.customTools) t.name};
    final namePattern = RegExp(r'^[a-z][a-z0-9_]{1,40}$');
    for (final tool in config.customTools) {
      if (!namePattern.hasMatch(tool.name)) problems.add('Custom tool "${tool.name}" needs a snake_case name.');
      if (builtIn.contains(tool.name)) problems.add('Custom tool "${tool.name}" replaces a built-in tool.');
      if (!{'notify', 'record', 'reply'}.contains(tool.action)) {
        problems.add('Custom tool "${tool.name}" action must be notify, record or reply.');
      }
      for (final arg in tool.args.keys) {
        if (!namePattern.hasMatch(arg)) problems.add('Custom tool "${tool.name}" argument "$arg" needs a snake_case name.');
      }
    }
    for (final workflow in {'known': config.known, 'screen': config.screen}.entries) {
      for (final tool in workflow.value.tools) {
        if (!builtIn.contains(tool) && !custom.contains(tool)) {
          problems.add('Workflow ${workflow.key} uses unknown tool "$tool".');
        }
      }
    }
    for (final rule in config.screeningRules) {
      if (!{'any', 'prefix', 'regex', 'withheld'}.contains(rule.type)) {
        problems.add('Unknown screening rule type "${rule.type}".');
      }
      if (rule.type == 'regex') {
        try {
          RegExp(rule.value);
        } on FormatException {
          problems.add('Invalid screening regex "${rule.value}".');
        }
      }
    }
    for (final contact in config.contacts) {
      if (contact.numbers.isEmpty) problems.add('Contact "${contact.name}" has no numbers.');
      if (!{'known', 'block'}.contains(contact.workflow)) {
        problems.add('Contact "${contact.name}" workflow must be known or block.');
      }
    }
    if (!{'small_model', 'tiered', 'gemma'}.contains(config.responder)) {
      problems.add('responder must be small_model, tiered or gemma.');
    }
    if (!{'parakeet-0.6b', 'parakeet-110m', 'tiny.en', 'base.en', 'small.en'}.contains(config.sttModel)) {
      problems.add('stt_model must be parakeet-0.6b, parakeet-110m, tiny.en, base.en or small.en.');
    }
    if (config.llmThreads < 1 || config.llmThreads > 8) problems.add('llm_threads must be 1–8.');
    if (config.llmContext < 1024 || config.llmContext > 16384) problems.add('llm_context must be 1024–16384.');
    return problems;
  }
}
