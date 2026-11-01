import 'dart:io';

import 'package:android_ai_receptionist/src/config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Keeps config/receptionist.example.json valid and complete.
void main() {
  test('example configuration is valid', () {
    final text = File('config/receptionist.example.json').readAsStringSync();
    expect(ReceptionistConfig.validate(text), isEmpty);
  });
}
