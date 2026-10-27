import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/role_voice_config.dart';
import 'package:zerochat/widgets/role_voice_section.dart';

void main() {
  group('role voice metadata helpers', () {
    test('read returns defaults for missing or malformed data', () {
      expect(readRoleVoiceConfig(const {}), const RoleVoiceConfig());
      expect(readRoleVoiceConfig(const {'voice': 'oops'}), const RoleVoiceConfig());
      expect(readRoleVoiceConfig(const {}).enabled, isTrue);
    });

    test('read parses all fields and treats only false as disabled', () {
      final config = readRoleVoiceConfig({
        'voice': {
          'enabled': false,
          'voice': ' 温柔女声 ',
          'style': '轻声',
          'ref_audio_path': '/a.wav',
          'prompt_text': '你好',
          'prompt_lang': 'zh',
          'text_lang': 'en',
        },
      });
      expect(config.enabled, isFalse);
      expect(config.voice, '温柔女声');
      expect(config.style, '轻声');
      expect(config.refAudioPath, '/a.wav');
      expect(config.promptText, '你好');
      expect(config.promptLang, 'zh');
      expect(config.textLang, 'en');

      expect(
        readRoleVoiceConfig({
          'voice': {'voice': 'x'},
        }).enabled,
        isTrue,
      );
    });

    test('write keeps other metadata keys and does not mutate the input', () {
      final metadata = <String, dynamic>{'ai_model': 'legacy', 'x': 1};
      final next = writeRoleVoiceConfig(
        metadata,
        const RoleVoiceConfig(voice: 'v1', style: ' 开心 '),
      );
      expect(next['ai_model'], 'legacy');
      expect(next['x'], 1);
      expect(next['voice'], {'voice': 'v1', 'style': '开心'});
      expect(metadata.containsKey('voice'), isFalse);
    });

    test('write stores enabled only when disabled', () {
      final disabled = writeRoleVoiceConfig(
        const {},
        const RoleVoiceConfig(enabled: false),
      );
      expect(disabled['voice'], {'enabled': false});

      final reenabled = writeRoleVoiceConfig(disabled, const RoleVoiceConfig());
      expect(reenabled.containsKey('voice'), isFalse);
    });

    test('empty strings remove their keys and unknown voice keys survive', () {
      final metadata = <String, dynamic>{
        'keep': true,
        'voice': {'voice': 'old', 'style': 'old', 'future_key': 7},
      };
      final next = writeRoleVoiceConfig(
        metadata,
        const RoleVoiceConfig(voice: 'new'),
      );
      expect(next['voice'], {'voice': 'new', 'future_key': 7});
      expect(next['keep'], isTrue);
    });

    test('default config removes the whole voice key', () {
      final metadata = <String, dynamic>{
        'keep': true,
        'voice': {'voice': 'old'},
      };
      final next = writeRoleVoiceConfig(metadata, const RoleVoiceConfig());
      expect(next, {'keep': true});
    });
  });

  group('RoleVoiceSection', () {
    Future<List<Map<String, dynamic>>> pump(
      WidgetTester tester, {
      Map<String, dynamic> metadata = const {},
    }) async {
      final emitted = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RoleVoiceSection(
                roleName: '小明',
                metadata: metadata,
                onChanged: emitted.add,
              ),
            ),
          ),
        ),
      );
      return emitted;
    }

    testWidgets('typing a voice emits metadata and keeps other keys', (
      tester,
    ) async {
      final emitted = await pump(tester, metadata: const {'ai_model': 'm'});

      await tester.enterText(find.byKey(const ValueKey('role-voice-voice')), '女声A');
      await tester.pump();

      expect(emitted, isNotEmpty);
      expect(emitted.last['ai_model'], 'm');
      expect(emitted.last['voice'], {'voice': '女声A'});
    });

    testWidgets('turning the switch off emits enabled false and hides fields', (
      tester,
    ) async {
      final emitted = await pump(tester);
      expect(find.byKey(const ValueKey('role-voice-voice')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('role-voice-enabled')));
      await tester.pump();

      expect(emitted.last['voice'], {'enabled': false});
      expect(find.byKey(const ValueKey('role-voice-voice')), findsNothing);
    });

    testWidgets('shows existing configuration', (tester) async {
      await pump(
        tester,
        metadata: const {
          'voice': {'voice': '已有音色', 'style': '已有风格'},
        },
      );
      expect(find.text('已有音色'), findsOneWidget);
      expect(find.text('已有风格'), findsOneWidget);
    });
  });
}
