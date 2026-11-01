import 'dart:math' as math;

import 'package:android_ai_receptionist/src/intents.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bag-of-words stand-in for the on-device embedding model.
Future<List<List<double>>> fakeEmbed(List<String> texts) async => [
      for (final t in texts)
        () {
          final v = List<double>.filled(64, 0);
          for (final w in t.toLowerCase().split(RegExp(r'[^a-z]+')).where((w) => w.length > 2)) {
            v[w.hashCode % 64] += 1;
          }
          final n = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
          return n == 0 ? v : [for (final x in v) x / n];
        }(),
    ];

void main() {
  final detector = IntentDetector(intents: IntentDef.defaults, embed: fakeEmbed, threshold: 0.5);

  test('the closest topic wins and carries its kind', () async {
    final plans = await detector.detect('Are we still meeting for coffee tomorrow?');
    expect(plans!.intent.name, 'Plans');
    expect(plans.intent.kind, IntentKind.reason);
    final talk = await detector.detect('Can I talk to him please?');
    expect(talk!.intent.kind, IntentKind.vague);
    final sales = await detector.detect('Your car warranty is about to expire');
    expect(sales!.intent.kind, IntentKind.spam);
  });

  test('nothing close enough means no topic', () async {
    expect(await detector.detect('zebra quantum marmalade'), isNull);
    expect(await detector.detect('   '), isNull);
  });

  test('topics round-trip through the configuration', () {
    final json = [for (final i in IntentDef.defaults) i.toJson()];
    final back = [for (final j in json) IntentDef.fromJson(j)];
    expect(back.map((i) => i.name), IntentDef.defaults.map((i) => i.name));
    expect(back.first.examples, IntentDef.defaults.first.examples);
  });

  test('notification text starts with the intent label', () {
    expect(intentLabel('Plans', IntentKind.reason), 'Plans');
    expect(intentLabel('Wants to talk', IntentKind.vague), 'Wants to talk (not a reason)');
    expect(intentLabel('Sales', IntentKind.spam), 'Spam: Sales');
    expect(labelled('Plans', 'Call me about dinner.'), 'Plans · Call me about dinner.');
    expect(labelled(null, 'Call me about dinner.'), 'Call me about dinner.');
  });
}
