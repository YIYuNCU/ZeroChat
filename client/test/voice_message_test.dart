import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/core/message_store.dart';
import 'package:zerochat/models/message.dart';
import 'package:zerochat/models/voice_message.dart';

Message _voiceMessage(String content, {String senderId = 'role-1'}) => Message(
  id: 'voice-1',
  senderId: senderId,
  receiverId: 'me',
  content: content,
  type: MessageType.voice,
  timestamp: DateTime(2026, 7, 14),
);

void main() {
  const ref = 'ws-emoji://voice/role-1/a.mp3';

  group('VoiceMessage.listFromMetadata', () {
    test('parses valid items and ignores malformed ones', () {
      final list = VoiceMessage.listFromMetadata({
        'voice_messages': [
          {'text': '你好', 'ref': ref, 'duration_ms': 2300, 'mime': 'audio/mpeg'},
          {'text': '没有引用'},
          'oops',
          {'text': '时长未知', 'ref': ref, 'duration_ms': null},
        ],
      });
      expect(list, hasLength(2));
      expect(list.first.text, '你好');
      expect(list.first.ref, ref);
      expect(list.first.durationMs, 2300);
      expect(list.first.mime, 'audio/mpeg');
      expect(list.last.durationMs, isNull);
    });

    test('returns empty for missing or wrongly typed metadata', () {
      expect(VoiceMessage.listFromMetadata(null), isEmpty);
      expect(VoiceMessage.listFromMetadata(const {}), isEmpty);
      expect(
        VoiceMessage.listFromMetadata(const {'voice_messages': 'x'}),
        isEmpty,
      );
    });
  });

  group('VoiceMessage content', () {
    test('toContent / parseContent round-trip without mime', () {
      const voice = VoiceMessage(
        text: '晚安',
        ref: ref,
        durationMs: 1500,
        mime: 'audio/mpeg',
      );
      final decoded = jsonDecode(voice.toContent()) as Map<String, dynamic>;
      expect(decoded, {
        'kind': 'voice',
        'text': '晚安',
        'ref': ref,
        'duration_ms': 1500,
      });

      final parsed = VoiceMessage.parseContent(voice.toContent());
      expect(parsed, isNotNull);
      expect(parsed!.text, '晚安');
      expect(parsed.ref, ref);
      expect(parsed.durationMs, 1500);
    });

    test('parseContent rejects non-voice or broken content', () {
      expect(VoiceMessage.parseContent('普通文本'), isNull);
      expect(VoiceMessage.parseContent('{"kind":"other","ref":"x"}'), isNull);
      expect(VoiceMessage.parseContent('{"kind":"voice"}'), isNull);
      expect(VoiceMessage.parseContent('{broken'), isNull);
    });

    test('fromMessage only reads voice-typed messages', () {
      final content = const VoiceMessage(text: 'hi', ref: ref).toContent();
      expect(VoiceMessage.fromMessage(_voiceMessage(content)), isNotNull);
      final text = Message(
        id: 't',
        senderId: 'role-1',
        receiverId: 'me',
        content: content,
        timestamp: DateTime(2026, 7, 14),
      );
      expect(VoiceMessage.fromMessage(text), isNull);
    });

    test('durationLabel rounds up to whole seconds', () {
      expect(
        const VoiceMessage(text: '', ref: ref, durationMs: 2300).durationLabel,
        '3"',
      );
      expect(
        const VoiceMessage(text: '', ref: ref, durationMs: 1000).durationLabel,
        '1"',
      );
      expect(const VoiceMessage(text: '', ref: ref).durationLabel, '');
    });
  });

  group('VoiceMessage.plainText', () {
    test('returns spoken text for voice messages', () {
      final content = const VoiceMessage(text: '早上好', ref: ref).toContent();
      expect(VoiceMessage.plainText(_voiceMessage(content)), '早上好');
    });

    test('falls back to the preview label when unparsable or empty', () {
      expect(VoiceMessage.plainText(_voiceMessage('{broken')), '[语音]');
      final empty = const VoiceMessage(text: '  ', ref: ref).toContent();
      expect(VoiceMessage.plainText(_voiceMessage(empty)), '[语音]');
    });

    test('returns content unchanged for other message types', () {
      final text = Message(
        id: 't',
        senderId: 'me',
        receiverId: 'role-1',
        content: '你好',
        timestamp: DateTime(2026, 7, 14),
      );
      expect(VoiceMessage.plainText(text), '你好');
    });
  });

  test('toApiHistory feeds the spoken text, not the voice JSON', () {
    final content = const VoiceMessage(text: '我到家了', ref: ref).toContent();
    final history = MessageStore.toApiHistory([_voiceMessage(content)]);
    expect(history, [
      {'role': 'assistant', 'content': '我到家了'},
    ]);
  });
}
