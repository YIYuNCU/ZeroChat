import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/core/message_store.dart';
import 'package:zerochat/models/message.dart';

void main() {
  test('local user messages begin in the sending state', () {
    final message = Message(
      id: 'message-1',
      senderId: 'me',
      receiverId: 'ai',
      content: 'hello',
      timestamp: DateTime(2026),
    );

    final stored = MessageStore.prepareMessageForLocalInsert(message);

    expect(stored.sendStatus, MessageSendStatus.sending);
  });

  test('a snapshot is stale after a local user message change', () {
    expect(MessageStore.isSnapshotRevisionCurrent(5, 5), isTrue);
    expect(MessageStore.isSnapshotRevisionCurrent(5, 6), isFalse);
  });
}
