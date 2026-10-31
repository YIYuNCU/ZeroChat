import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/role_voice_config.dart';
import 'package:zerochat/services/tts_settings_service.dart';
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

    test('profile id round trips through metadata', () {
      final next = writeRoleVoiceConfig(
        const {'keep': 1},
        const RoleVoiceConfig(profileId: ' p2 ', voice: 'v'),
      );
      expect(next['voice'], {'profile_id': 'p2', 'voice': 'v'});
      expect(next['keep'], 1);

      final config = readRoleVoiceConfig(next);
      expect(config.profileId, 'p2');
      expect(config.voice, 'v');
      expect(config.isDefault, isFalse);
    });

    test('a profile id alone is a non-default config', () {
      expect(const RoleVoiceConfig().isDefault, isTrue);
      expect(const RoleVoiceConfig(profileId: 'p2').isDefault, isFalse);
      expect(
        const RoleVoiceConfig().copyWith(profileId: 'p2'),
        const RoleVoiceConfig(profileId: 'p2'),
      );
      expect(
        const RoleVoiceConfig(profileId: 'p2').hashCode,
        const RoleVoiceConfig(profileId: 'p2').hashCode,
      );
      expect(
        const RoleVoiceConfig(profileId: 'p2'),
        isNot(const RoleVoiceConfig(profileId: 'p3')),
      );
    });

    test('empty profile id removes the key and keeps the rest', () {
      final metadata = <String, dynamic>{
        'ai_model': 'm',
        'voice': {
          'profile_id': 'p2',
          'voice': 'old',
          'enabled': false,
          'future_key': 7,
        },
      };
      final next = writeRoleVoiceConfig(
        metadata,
        const RoleVoiceConfig(enabled: false, voice: 'old'),
      );
      expect(next['voice'], {
        'enabled': false,
        'voice': 'old',
        'future_key': 7,
      });
      expect(next['ai_model'], 'm');
      // 入参不被修改。
      expect((metadata['voice'] as Map)['profile_id'], 'p2');

      final cleared = writeRoleVoiceConfig(
        {
          'voice': {'profile_id': 'p2'},
        },
        const RoleVoiceConfig(),
      );
      expect(cleared.containsKey('voice'), isFalse);
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
    /// 默认让档案加载失败（与未连接服务端时一致）；传入 [profiles] 则模拟服务端档案列表。
    Future<List<Map<String, dynamic>>> pump(
      WidgetTester tester, {
      Map<String, dynamic> metadata = const {},
      List<Map<String, String>>? profiles,
    }) async {
      final emitted = <Map<String, dynamic>>[];
      final service = TtsSettingsService(
        request: (action, payload, {timeout}) async {
          if (profiles == null) throw StateError('服务端未连接');
          return {
            'tts': {
              'default_profile_id': profiles.isEmpty ? '' : profiles.first['id'],
              'profiles': profiles,
            },
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RoleVoiceSection(
                roleName: '小明',
                metadata: metadata,
                onChanged: emitted.add,
                ttsService: service,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return emitted;
    }

    Future<void> openProfileMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('role-voice-profile')));
      await tester.pumpAndSettle();
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

    testWidgets('profile dropdown lists follow-default and every profile', (
      tester,
    ) async {
      final emitted = await pump(
        tester,
        metadata: const {'ai_model': 'm'},
        profiles: [
          {'id': 'default', 'name': '默认'},
          {'id': 'p2', 'name': '角色专用'},
        ],
      );
      expect(find.text('跟随默认档案'), findsOneWidget);

      await openProfileMenu(tester);
      expect(find.text('默认'), findsOneWidget);
      expect(find.text('角色专用'), findsOneWidget);

      await tester.tap(find.text('角色专用').last);
      await tester.pumpAndSettle();
      expect(emitted.last['voice'], {'profile_id': 'p2'});
      expect(emitted.last['ai_model'], 'm');

      await openProfileMenu(tester);
      await tester.tap(find.text('跟随默认档案').last);
      await tester.pumpAndSettle();
      expect(emitted.last.containsKey('voice'), isFalse);
      expect(emitted.last['ai_model'], 'm');
    });

    testWidgets('shows the stored profile by name', (tester) async {
      await pump(
        tester,
        metadata: const {
          'voice': {'profile_id': 'p2'},
        },
        profiles: [
          {'id': 'default', 'name': '默认'},
          {'id': 'p2', 'name': '角色专用'},
        ],
      );
      expect(find.text('角色专用'), findsOneWidget);
      expect(find.text('（已删除的档案）'), findsNothing);
    });

    testWidgets('keeps a stored profile id that no longer exists', (
      tester,
    ) async {
      final emitted = await pump(
        tester,
        metadata: const {
          'voice': {'profile_id': 'gone', 'voice': 'x'},
        },
        profiles: [
          {'id': 'default', 'name': '默认'},
        ],
      );
      expect(find.text('（已删除的档案）'), findsOneWidget);
      // 仅展示，不会触发写回，原值不会被悄悄丢掉。
      expect(emitted, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('role-voice-voice')), 'y');
      await tester.pump();
      expect(emitted.last['voice'], {'profile_id': 'gone', 'voice': 'y'});
    });

    testWidgets('falls back to follow-default when profiles fail to load', (
      tester,
    ) async {
      await pump(
        tester,
        metadata: const {
          'voice': {'profile_id': 'p2'},
        },
      );
      expect(find.byKey(const ValueKey('role-voice-profile')), findsOneWidget);
      expect(find.text('当前档案：p2'), findsOneWidget);

      await openProfileMenu(tester);
      expect(find.text('跟随默认档案'), findsOneWidget);
    });

    testWidgets('profile dropdown is hidden when voice is disabled', (
      tester,
    ) async {
      await pump(
        tester,
        metadata: const {
          'voice': {'enabled': false},
        },
      );
      expect(find.byKey(const ValueKey('role-voice-profile')), findsNothing);
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
