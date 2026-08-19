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

  test('snapshot merge retains a locally rendered AI message', () {
    final timestamp = DateTime(2026);
    final serverMessage = Message(
      id: 'server-message',
      senderId: 'me',
      receiverId: 'ai',
      content: 'hello',
      timestamp: timestamp,
    );
    final localAiMessage = Message(
      id: 'local-ai-message',
      senderId: 'ai',
      receiverId: 'me',
      content: 'reply',
      timestamp: timestamp.add(const Duration(seconds: 1)),
      sendStatus: MessageSendStatus.sending,
    );

    final merged = MessageStore.mergeSnapshotWithLocalMessages(
      [serverMessage],
      [serverMessage, localAiMessage],
    );

    expect(merged.map((message) => message.id), [
      'server-message',
      'local-ai-message',
    ]);
  });

  test('snapshot merge accepts server deletes and updates for sent messages', () {
    final timestamp = DateTime(2026);
    final localSentMessage = Message(
      id: 'message-1',
      senderId: 'ai',
      receiverId: 'me',
      content: 'old',
      timestamp: timestamp,
    );
    final serverUpdatedMessage = localSentMessage.copyWith(content: 'new');

    final updated = MessageStore.mergeSnapshotWithLocalMessages(
      [serverUpdatedMessage],
      [localSentMessage],
    );
    final deleted = MessageStore.mergeSnapshotWithLocalMessages(
      const [],
      [localSentMessage],
    );

    expect(updated.single.content, 'new');
    expect(deleted, isEmpty);
  });
}
