import 'dart:convert';

/// One model turn: words for the other party plus an optional tool call.
class AgentReply {
  AgentReply(this.say, this.toolName, this.args, this.raw);

  final String say;
  final String? toolName;
  final Map<String, String> args;
  final String raw;

  /// Parses `{"say": "...", "tool": null | {"name": "...", "args": {...}}}`.
  /// Falls back to treating unparseable output as plain speech.
  factory AgentReply.parse(String raw) {
    final text = raw.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final decoded = jsonDecode(text.substring(start, end + 1));
        if (decoded is Map) {
          final tool = decoded['tool'];
          String? name;
          final args = <String, String>{};
          if (tool is Map) {
            name = tool['name']?.toString();
            final rawArgs = tool['args'];
            if (rawArgs is Map) {
              for (final e in rawArgs.entries) {
                args[e.key.toString()] = e.value?.toString() ?? '';
              }
            }
          } else if (tool is String && tool.isNotEmpty && tool != 'none' && tool != 'null') {
            name = tool;
          }
          return AgentReply((decoded['say'] ?? '').toString().trim(), name, args, raw);
        }
      } on FormatException {
        // fall through
      }
    }
    final partial = SayExtractor()..add(text);
    final say = partial.text.isNotEmpty ? partial.text : text.replaceAll(RegExp(r'[{}"]'), '');
    return AgentReply(say.trim(), null, const {}, raw);
  }
}

/// Incrementally decodes the `say` string from streamed JSON tokens, so speech
/// can start before the model has finished the whole reply.
class SayExtractor {
  static const _key = '"say"';
  final StringBuffer _raw = StringBuffer();
  final StringBuffer _text = StringBuffer();
  int _scan = 0;
  bool _inString = false;
  bool _done = false;
  bool _escape = false;
  String _unicode = '';
  int _unicodeLeft = 0;

  String get text => _text.toString();
  bool get done => _done;

  /// Adds streamed text; returns newly decoded `say` characters.
  String add(String chunk) {
    if (_done) return '';
    _raw.write(chunk);
    final raw = _raw.toString();
    final out = StringBuffer();
    if (!_inString) {
      final key = raw.indexOf(_key);
      if (key < 0) return '';
      final colon = raw.indexOf(':', key + _key.length);
      if (colon < 0) return '';
      final quote = raw.indexOf('"', colon + 1);
      if (quote < 0) return '';
      _inString = true;
      _scan = quote + 1;
    }
    while (_scan < raw.length && !_done) {
      final c = raw[_scan++];
      if (_unicodeLeft > 0) {
        _unicode += c;
        if (--_unicodeLeft == 0) {
          final code = int.tryParse(_unicode, radix: 16);
          if (code != null) out.writeCharCode(code);
          _unicode = '';
        }
      } else if (_escape) {
        _escape = false;
        switch (c) {
          case 'n':
            out.write(' ');
          case 't':
            out.write(' ');
          case 'u':
            _unicodeLeft = 4;
          case 'b' || 'f' || 'r':
            break;
          default:
            out.write(c);
        }
      } else if (c == '\\') {
        _escape = true;
      } else if (c == '"') {
        _done = true;
      } else {
        out.write(c);
      }
    }
    _text.write(out);
    return out.toString();
  }
}

/// Splits streamed speech into sentence-sized chunks for TTS.
class SentenceChunker {
  SentenceChunker({this.minLength = 12});
  final int minLength;
  final StringBuffer _pending = StringBuffer();

  /// Returns complete sentences ready to speak.
  List<String> add(String text) {
    _pending.write(text);
    final ready = <String>[];
    var value = _pending.toString();
    while (true) {
      final match = RegExp(r'[.!?](?=\s)').allMatches(value).where((m) => m.end >= minLength).firstOrNull;
      if (match == null) break;
      final sentence = value.substring(0, match.end).trim();
      if (sentence.isNotEmpty) ready.add(sentence);
      value = value.substring(match.end);
    }
    _pending
      ..clear()
      ..write(value);
    return ready;
  }

  String flush() {
    final rest = _pending.toString().trim();
    _pending.clear();
    return rest;
  }
}

/// Removes characters the TTS cannot pronounce and markup the model may emit.
String speakable(String text) => text
    .replaceAll(RegExp(r'[*_#`~<>\[\]{}|]'), ' ')
    .replaceAll(RegExp(r'[^\x20-\x7EÀ-ɏ‘’“”]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

final _numberQuestion = RegExp(
    r"[^.!?]*\b(phone|call ?back|contact|your|best|a|the)\s+(phone\s+)?number\b[^.!?]*\?",
    caseSensitive: false);

/// Removes questions asking for the caller's phone number; caller ID already
/// provides it and small models ask anyway.
String dropNumberQuestions(String text) =>
    text.replaceAll(_numberQuestion, '').replaceAll(RegExp(r'\s+'), ' ').trim();
