import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/models/role.dart';

void main() {
  test('reasoning content survives json, storage and copyWith', () {
    final message = Message(
      id: 'm1',
      senderId: 'role-1',
      receiverId: 'me',
      content: '回复',
      timestamp: DateTime(2026, 10, 17),
      reasoningContent: '先分析，再回答。',
    );

    expect(message.hasReasoning, isTrue);
    expect(message.toJson()['reasoning_content'], '先分析，再回答。');

    final fromJson = Message.fromJson(message.toJson());
    expect(fromJson.reasoningContent, '先分析，再回答。');

    final fromStorage = Message.fromStorageString(message.toStorageString());
    expect(fromStorage.reasoningContent, '先分析，再回答。');

    final copied = message.copyWith(content: '新回复');
    expect(copied.reasoningContent, '先分析，再回答。');
  });

  test('empty reasoning is omitted from json', () {
    final message = Message(
      id: 'm2',
      senderId: 'role-1',
      receiverId: 'me',
      content: '回复',
      timestamp: DateTime(2026, 10, 17),
      reasoningContent: '',
    );

    expect(message.hasReasoning, isFalse);
    expect(message.toJson().containsKey('reasoning_content'), isFalse);
  });

  test('role showReasoning defaults to false and round-trips', () {
    final role = Role(id: 'r1', name: 'AI', systemPrompt: 'test');
    expect(role.showReasoning, isFalse);

    final enabled = role.copyWith(showReasoning: true);
    expect(enabled.showReasoning, isTrue);
    expect(enabled.toJson()['show_reasoning'], isTrue);

    final restored = Role.fromJson(enabled.toJson());
    expect(restored.showReasoning, isTrue);

    final legacy = Role.fromJson(role.toJson()..remove('show_reasoning'));
    expect(legacy.showReasoning, isFalse);
  });
}
