import 'package:android_ai_receptionist/src/texting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one-time codes are recognized so they always notify', () {
    expect(isVerificationCode('Your verification code is 482913. Do not share it.'), isTrue);
    expect(isVerificationCode('G-123456 is your Google sign-in code'), isTrue);
    expect(isVerificationCode('Use 7731 to log in'), isTrue);
    expect(isVerificationCode('Meet at 1200 Main St'), isFalse);
    expect(isVerificationCode('Your code word is banana'), isFalse);
    expect(isVerificationCode('Call me at 555-555-0100 about the code review'), isFalse);
  });

  test('threads and messages decode from the native store', () {
    final thread = TextThread.fromMap({
      'threadId': 7,
      'addresses': ['+15555550100'],
      'snippet': 'See you soon',
      'date': 1700000000000,
      'unread': true,
    });
    expect(thread.id, 7);
    expect(thread.unread, isTrue);
    final message = TextMessage.fromMap({
      'id': 'mms-3',
      'address': '+15555550100',
      'body': 'Look',
      'date': 1700000000000,
      'outgoing': false,
      'images': [12, 13],
    });
    expect(message.images, [12, 13]);
    expect(message.outgoing, isFalse);
  });
}
