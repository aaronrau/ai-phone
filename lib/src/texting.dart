import 'dart:typed_data';

import 'native.dart';

/// One conversation in the phone's message store.
class TextThread {
  TextThread({
    required this.id,
    required this.addresses,
    required this.snippet,
    required this.date,
    required this.unread,
  });

  factory TextThread.fromMap(Map map) => TextThread(
        id: (map['threadId'] as num).toInt(),
        addresses: [for (final a in (map['addresses'] as List? ?? const [])) a.toString()],
        snippet: (map['snippet'] ?? '').toString(),
        date: DateTime.fromMillisecondsSinceEpoch((map['date'] as num? ?? 0).toInt()),
        unread: map['unread'] == true,
      );

  final int id;
  final List<String> addresses;
  final String snippet;
  final DateTime date;
  final bool unread;
}

/// One text or picture message.
class TextMessage {
  TextMessage({
    required this.id,
    required this.address,
    required this.body,
    required this.date,
    required this.outgoing,
    this.failed = false,
    this.pending = false,
    this.images = const [],
  });

  factory TextMessage.fromMap(Map map) => TextMessage(
        id: (map['id'] ?? '').toString(),
        address: (map['address'] ?? '').toString(),
        body: (map['body'] ?? '').toString(),
        date: DateTime.fromMillisecondsSinceEpoch((map['date'] as num? ?? 0).toInt()),
        outgoing: map['outgoing'] == true,
        failed: map['failed'] == true,
        pending: map['pending'] == true,
        images: [for (final i in (map['images'] as List? ?? const [])) (i as num).toInt()],
      );

  final String id;
  final String address;
  final String body;
  final DateTime date;
  final bool outgoing;
  final bool failed;
  final bool pending;

  /// MMS picture part IDs, loaded with [Texting.picture].
  final List<int> images;
}

/// The phone's text messages, read and written through the native store.
class Texting {
  Texting(this.api);
  final NativeApi api;

  Future<List<TextThread>> threads() async =>
      [for (final row in await api.call<List>('smsThreads', {'limit': 300}) ?? const []) TextThread.fromMap(row as Map)];

  Future<List<TextMessage>> messages(int threadId) async => [
        for (final row in await api.call<List>('smsMessages', {'threadId': threadId, 'limit': 400}) ?? const [])
          TextMessage.fromMap(row as Map),
      ];

  Future<int> threadFor(String number) async => (await api.call<num>('smsThreadFor', {'number': number}))?.toInt() ?? -1;

  Future<void> markRead(int threadId) => api.call('smsMarkRead', {'threadId': threadId});

  Future<void> deleteThread(int threadId) => api.call('smsDeleteThread', {'threadId': threadId});

  /// Sends a text; returns its thread ID.
  Future<int> send(String number, String text) async =>
      (await api.call<num>('smsSend', {'number': number, 'text': text}))?.toInt() ?? -1;

  Future<Uint8List?> picture(int partId) => api.call<Uint8List>('mmsPart', {'partId': partId});
}

final _codeWords = RegExp(
    r'\b(code|passcode|pass code|otp|verification|verify|one[- ]time|2fa|security code|sign[- ]in|log[- ]?in|pin)\b',
    caseSensitive: false);
// 4-8 digits that are not part of a phone number such as 555-555-0100.
final _codeDigits = RegExp(r'(?<!\d)(?<!\d-)\d{4,8}(?!-?\d)');

/// One-time sign-in codes are always shown, even from unknown senders.
bool isVerificationCode(String body) => _codeWords.hasMatch(body) && _codeDigits.hasMatch(body);
