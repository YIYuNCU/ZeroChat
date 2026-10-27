import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/pages/tts_settings_page.dart';
import 'package:zerochat/services/tts_settings_service.dart';

Map<String, dynamic> _serverTts() => {
  'tts': {
    'enabled': true,
    'provider': 'mimo',
    'timeout_seconds': 30,
    'max_chars': 200,
    'configured': true,
    'mimo': {
      'api_url': 'https://mimo.example/v1',
      'api_key_masked': 'sk-****1234',
      'model': 'mimo-tts',
      'voice': 'default',
      'style': '',
    },
    'qwen': {
      'api_url': '',
      'api_key_masked': '',
      'model': '',
      'voice': '',
      'language_type': 'Chinese',
      'style': '',
    },
    'gpt_sovits': {
      'api_url': 'http://127.0.0.1:9880',
      'ref_audio_path': '',
      'prompt_text': '',
      'prompt_lang': 'zh',
      'text_lang': 'zh',
      'text_split_method': 'cut5',
      'speed_factor': 1.0,
    },
  },
};

void main() {
  group('TtsSettings.fromResponse', () {
    test('parses providers and keeps secrets masked', () {
      final settings = TtsSettings.fromResponse(_serverTts());
      expect(settings.enabled, isTrue);
      expect(settings.configured, isTrue);
      expect(settings.provider, 'mimo');
      expect(settings.timeoutSeconds, 30);
      expect(settings.maxChars, 200);
      expect(settings.valueOf('mimo', 'model'), 'mimo-tts');
      expect(settings.valueOf('mimo', 'api_key_masked'), 'sk-****1234');
      expect(settings.valueOf('gpt_sovits', 'speed_factor'), '1.0');
    });

    test('falls back to defaults for missing data and unknown providers', () {
      final settings = TtsSettings.fromResponse({
        'tts': {'provider': 'nope'},
      });
      expect(settings.enabled, isFalse);
      expect(settings.provider, 'mimo');
      expect(settings.timeoutSeconds, 30);
      expect(settings.valueOf('qwen', 'voice'), '');
    });
  });

  group('TtsSettingsService.buildUpdates', () {
    Map<String, dynamic> build(Map<String, Map<String, String>> providers) =>
        TtsSettingsService.buildUpdates(
          enabled: true,
          provider: 'qwen',
          timeoutSeconds: 20,
          maxChars: 100,
          providers: providers,
        );

    test('omits empty api keys and sends typed ones', () {
      final updates = build({
        'mimo': {'api_key': '', 'model': 'm'},
        'qwen': {'api_key': '  new-key  ', 'voice': 'v'},
      });
      expect(updates['enabled'], isTrue);
      expect(updates['provider'], 'qwen');
      expect(updates['timeout_seconds'], 20);
      expect(updates['max_chars'], 100);
      expect((updates['mimo'] as Map).containsKey('api_key'), isFalse);
      expect((updates['mimo'] as Map)['model'], 'm');
      expect((updates['qwen'] as Map)['api_key'], 'new-key');
    });

    test('sends speed_factor as a number and skips unparsable values', () {
      final ok = build({
        'gpt_sovits': {'speed_factor': '1.25'},
      });
      expect((ok['gpt_sovits'] as Map)['speed_factor'], 1.25);

      final bad = build({
        'gpt_sovits': {'speed_factor': 'fast'},
      });
      expect((bad['gpt_sovits'] as Map).containsKey('speed_factor'), isFalse);
    });
  });

  group('TtsTestResult', () {
    test('summarises success and failure', () {
      final ok = TtsTestResult.fromResponse({
        'success': true,
        'latency_ms': 850,
        'size': 20480,
        'duration_ms': 2400,
      });
      expect(ok.summary, '测试成功：耗时 850ms，大小 20.0KB，时长 2.4s');

      final failed = TtsTestResult.fromResponse({
        'success': false,
        'error': 'timeout',
      });
      expect(failed.summary, '测试失败：timeout');
    });
  });

  group('TtsSettingsPage', () {
    late List<(String, Map<String, dynamic>)> calls;
    late TtsSettingsService service;

    setUp(() {
      calls = [];
      service = TtsSettingsService(
        request: (action, payload, {timeout}) async {
          calls.add((action, payload));
          switch (action) {
            case 'settings_tts_get':
              return _serverTts();
            case 'settings_tts_update':
              return {'success': true};
            case 'settings_tts_test':
              return {
                'success': true,
                'latency_ms': 850,
                'size': 20480,
                'duration_ms': 2400,
                'error': '',
              };
          }
          return {};
        },
      );
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: TtsSettingsPage(service: service)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('loads settings into the form with a masked key hint', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('mimo-tts'), findsOneWidget);
      expect(find.text('已设置：sk-****1234（留空保持不变）'), findsOneWidget);
    });

    testWidgets('save omits the api key unless a new one is typed', (
      tester,
    ) async {
      await pump(tester);

      await tester.enterText(
        find.byKey(const ValueKey('tts-field-mimo/model')),
        'mimo-tts-2',
      );
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      final update = calls.firstWhere((c) => c.$1 == 'settings_tts_update').$2;
      final mimo = (update['updates'] as Map)['mimo'] as Map;
      expect(mimo['model'], 'mimo-tts-2');
      expect(mimo.containsKey('api_key'), isFalse);

      calls.clear();
      await tester.enterText(
        find.byKey(const ValueKey('tts-field-mimo/api_key')),
        'sk-new',
      );
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      final second = calls.firstWhere((c) => c.$1 == 'settings_tts_update').$2;
      expect(((second['updates'] as Map)['mimo'] as Map)['api_key'], 'sk-new');
    });

    testWidgets('test button saves first and shows the result', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-test')));
      await tester.pumpAndSettle();

      final actions = calls.map((c) => c.$1).toList();
      expect(
        actions.indexOf('settings_tts_update'),
        lessThan(actions.indexOf('settings_tts_test')),
      );
      expect(find.text('测试成功：耗时 850ms，大小 20.0KB，时长 2.4s'), findsOneWidget);
    });

    testWidgets('invalid timeout is rejected before any request', (
      tester,
    ) async {
      await pump(tester);

      await tester.enterText(find.byKey(const ValueKey('tts-timeout')), '0');
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pump();

      expect(calls.where((c) => c.$1 == 'settings_tts_update'), isEmpty);
      expect(find.text('超时时间请输入正整数（秒）'), findsOneWidget);
    });
  });
}
