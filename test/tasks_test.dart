import 'package:android_ai_receptionist/src/tasks.dart';
import 'package:android_ai_receptionist/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('open tasks match the caller whatever the number format, oldest first', () {
    final book = TaskBook.empty()
      ..add(InboundTask(id: '1', number: '+1 (555) 555-0100', action: InboundAction.tell, text: 'Dinner at 7',
          created: DateTime(2026, 1, 1)))
      ..add(InboundTask(id: '2', number: '5555550100', action: InboundAction.ask, text: 'Which day?',
          created: DateTime(2026, 1, 2)))
      ..add(InboundTask(id: '3', number: '+15555550199', action: InboundAction.transfer))
      ..add(InboundTask(id: '4', number: '+15555550100', action: InboundAction.tell, doneAt: DateTime(2026, 1, 3)));
    expect(book.pendingFor('+15555550100').map((t) => t.id), ['1', '2']);
    expect(book.pendingFor('+15555550123'), isEmpty);
    final round = TaskBook.fromJson(book.toJson());
    expect(round.inbound.map((t) => t.action), book.inbound.map((t) => t.action));
    expect(round.inbound.firstWhere((t) => t.id == '4').done, isTrue);
  });

  test("the owner's note goes into the greeting", () {
    const greeting = "Hi Jordan, you've reached Sam's AI Assistant. How can I help?";
    expect(withNote(greeting, 'Sam asked me to let you know: dinner moved to 7.'),
        "Hi Jordan, you've reached Sam's AI Assistant. Sam asked me to let you know: dinner moved to 7. How can I help?");
    expect(withNote(greeting, 'Sam asked me to ask you: which day works?'),
        "Hi Jordan, you've reached Sam's AI Assistant. Sam asked me to ask you: which day works?");
    expect(withNote(greeting, null), greeting);
  });
}
