import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/core/message_parts.dart';

void main() {
  group('MessageParts', () {
    test('preserves interleaved and repeated parts in source order', () {
      final parsed = MessageParts.parse(
        '<对话>第一句</对话>'
        '<动作>抬手</动作>'
        '<对话>第二句</对话>'
        '<声音>裙摆沙沙作响</声音>'
        '<心理>有些犹豫</心理>'
        '<动作>放下手</动作>',
      );

      expect(parsed.parts.map((part) => part.type), [
        MessagePartType.dialogue,
        MessagePartType.action,
        MessagePartType.dialogue,
        MessagePartType.sound,
        MessagePartType.psychology,
        MessagePartType.action,
      ]);
      expect(parsed.parts.map((part) => part.text), [
        '第一句',
        '抬手',
        '第二句',
        '裙摆沙沙作响',
        '有些犹豫',
        '放下手',
      ]);
    });

    test('keeps untagged text at its original position', () {
      final parsed = MessageParts.parse('开头<动作>点头</动作>中间<对话>结尾</对话>');

      expect(parsed.parts.map((part) => part.type), [
        MessagePartType.dialogue,
        MessagePartType.action,
        MessagePartType.dialogue,
        MessagePartType.dialogue,
      ]);
      expect(parsed.parts.map((part) => part.text), ['开头', '点头', '中间', '结尾']);
    });

    test('supports user facts and downgrades AI facts to dialogue', () {
      final user = MessageParts.parse('<事实>会议已经结束</事实>');
      final ai = MessageParts.parse('<事实>会议已经结束</事实>', allowFact: false);

      expect(user.parts.single.type, MessagePartType.fact);
      expect(ai.parts.single.type, MessagePartType.dialogue);
      expect(ai.parts.single.text, '会议已经结束');
    });

    test('keeps separate stats blocks in order', () {
      final parsed = MessageParts.parse(
        '<数值>trust:10</数值><动作>微笑</动作><数值>trust:11</数值>',
      );

      expect(parsed.parts.map((part) => part.type), [
        MessagePartType.stats,
        MessagePartType.action,
        MessagePartType.stats,
      ]);
      expect(parsed.parts.first.stats, {'trust': '10'});
      expect(parsed.parts.last.stats, {'trust': '11'});
    });

    test('parses sound blocks and keeps dialogue-only previews clean', () {
      final parsed = MessageParts.parse(
        '<对话>等一下</对话><声音>衣料轻轻摩擦</声音>',
      );

      expect(parsed.parts.map((part) => part.type), [
        MessagePartType.dialogue,
        MessagePartType.sound,
      ]);
      expect(parsed.sound, '衣料轻轻摩擦');
      expect(
        MessageParts.previewText(
          '<对话>等一下</对话><声音>衣料轻轻摩擦</声音>',
          isUserMessage: false,
        ),
        '等一下',
      );
    });

    test('treats incomplete tags as ordinary dialogue', () {
      final parsed = MessageParts.parse('<动作>尚未闭合');

      expect(parsed.parts.single.type, MessagePartType.dialogue);
      expect(parsed.parts.single.text, '<动作>尚未闭合');
    });

    test('recognizes only a standalone no-reply directive', () {
      final directive = MessageParts.parse('  <无回复/>  ');
      final mixed = MessageParts.parse('<无回复/>还有正文');

      expect(directive.isNoReply, isTrue);
      expect(directive.plainText, '无回复');
      expect(mixed.isNoReply, isFalse);
      expect(mixed.dialogue, '<无回复/>还有正文');
    });
  });

  group('MessageParts tag normalization', () {
    test('maps English alias tags to Chinese canonical tags', () {
      final parsed = MessageParts.parse(
        '<message>你好呀</message><action>挥手</action><thought>有点开心</thought>',
      );

      expect(parsed.parts.map((part) => part.type), [
        MessagePartType.dialogue,
        MessagePartType.action,
        MessagePartType.psychology,
      ]);
      expect(parsed.parts.map((part) => part.text), ['你好呀', '挥手', '有点开心']);
    });

    test('alias matching is case-insensitive and tolerant of spaces', () {
      final parsed = MessageParts.parse('< Action >点头</ Action >');

      expect(parsed.parts.single.type, MessagePartType.action);
      expect(parsed.parts.single.text, '点头');
    });

    test('maps sound aliases to the canonical tag', () {
      final parsed = MessageParts.parse('< Audio >轻轻的呼吸声</ Audio >');

      expect(parsed.parts.single.type, MessagePartType.sound);
      expect(parsed.parts.single.text, '轻轻的呼吸声');
    });

    test('handles mixed Chinese-open English-close tags', () {
      final parsed = MessageParts.parse('<对话>混用</message>');

      expect(parsed.parts.single.type, MessagePartType.dialogue);
      expect(parsed.parts.single.text, '混用');
    });

    test('normalizes no-reply alias variants to the directive', () {
      expect(MessageParts.parse('<no_reply/>').isNoReply, isTrue);
      expect(MessageParts.parse('<noreply></noreply>').isNoReply, isTrue);
      expect(MessageParts.parse('  <no-reply/>  ').isNoReply, isTrue);
    });

    test('leaves plain content without tags untouched', () {
      expect(MessageParts.normalizeTags('普通文本没有标签'), '普通文本没有标签');
    });
  });
}
