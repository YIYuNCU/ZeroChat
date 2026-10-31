import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/pages/tts_profile_editor_page.dart';
import 'package:zerochat/pages/tts_settings_page.dart';
import 'package:zerochat/services/tts_settings_service.dart';

Map<String, dynamic> _profileJson(
  String id,
  String name, {
  String provider = 'mimo',
  bool configured = true,
  String? responseType,
  String? headers,
  String? body,
}) => {
  'id': id,
  'name': name,
  'provider': provider,
  'timeout_seconds': 30,
  'max_chars': 200,
  'configured': configured,
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
  'custom': {
    'api_url': 'https://tts.example/v1/speech',
    'api_key_masked': '',
    'method': 'POST',
    'headers': headers ?? '{"Authorization": "Bearer {{api_key}}"}',
    'body': body ?? '{"input": "{{text}}"}',
    'model': '',
    'voice': 'alloy',
    'style': '',
    'response_type': responseType ?? 'binary',
    'response_path': '',
  },
};

/// 服务端 `settings_tts_get` 的响应。顶层带有镜像默认档案的旧字段（故意与档案不同），
/// 客户端必须忽略它们。
Map<String, dynamic> _serverTts({
  List<Map<String, dynamic>>? profiles,
  String defaultId = 'default',
  bool enabled = true,
}) => {
  'tts': {
    'enabled': enabled,
    'default_profile_id': defaultId,
    'profiles':
        profiles ??
        [
          _profileJson('default', '默认'),
          _profileJson('p2', '角色专用', provider: 'qwen', configured: false),
        ],
    'provider': 'gpt_sovits',
    'timeout_seconds': 999,
    'max_chars': 999,
    'configured': false,
    'mimo': {'model': 'legacy-mirror'},
  },
};

TtsProfile _profileFrom(Map<String, dynamic> json) =>
    TtsSettings.fromResponse({
      'tts': {
        'profiles': [json],
      },
    }).profiles.first;

void main() {
  group('TtsSettings.fromResponse', () {
    test('parses enabled, default id and profiles with masked secrets', () {
      final settings = TtsSettings.fromResponse(_serverTts());
      expect(settings.enabled, isTrue);
      expect(settings.defaultProfileId, 'default');
      expect(settings.profiles.map((p) => p.id), ['default', 'p2']);

      final first = settings.profiles.first;
      expect(first.name, '默认');
      expect(first.provider, 'mimo');
      expect(first.providerLabel, 'MiMo');
      expect(first.timeoutSeconds, 30);
      expect(first.maxChars, 200);
      expect(first.configured, isTrue);
      expect(first.valueOf('mimo', 'model'), 'mimo-tts');
      expect(first.valueOf('mimo', 'api_key_masked'), 'sk-****1234');
      expect(first.valueOf('gpt_sovits', 'speed_factor'), '1.0');

      final second = settings.profileById('p2')!;
      expect(second.provider, 'qwen');
      expect(second.configured, isFalse);
      expect(settings.profileById('nope'), isNull);
    });

    test('ignores the legacy top-level mirror fields', () {
      final settings = TtsSettings.fromResponse(_serverTts());
      // 顶层的 timeout_seconds / provider 是旧镜像，不能影响档案。
      expect(settings.profiles.first.timeoutSeconds, 30);
      expect(settings.profiles.first.provider, 'mimo');
      expect(settings.profiles.first.valueOf('mimo', 'model'), 'mimo-tts');
    });

    test('parses the custom provider templates', () {
      final profile = _profileFrom(
        _profileJson('c', '自定义', provider: 'custom'),
      );
      expect(profile.provider, 'custom');
      expect(profile.valueOf('custom', 'method'), 'POST');
      expect(profile.valueOf('custom', 'body'), '{"input": "{{text}}"}');
      expect(profile.valueOf('custom', 'response_type'), 'binary');
    });

    test('falls back to defaults for missing data and unknown providers', () {
      final empty = TtsSettings.fromResponse({
        'tts': {'default_profile_id': ''},
      });
      expect(empty.enabled, isFalse);
      expect(empty.defaultProfileId, '');
      expect(empty.profiles, isEmpty);
      expect(empty.defaultProfile, isNull);

      final profile = _profileFrom({'id': 'x', 'provider': 'nope'});
      expect(profile.provider, 'mimo');
      expect(profile.name, '');
      expect(profile.timeoutSeconds, 60);
      expect(profile.maxChars, 300);
      expect(profile.valueOf('qwen', 'voice'), '');
    });

    test('skips profiles without an id', () {
      final settings = TtsSettings.fromResponse({
        'tts': {
          'profiles': [
            {'name': '无 id'},
            'oops',
            {'id': 'ok', 'name': '正常'},
          ],
        },
      });
      expect(settings.profiles.map((p) => p.id), ['ok']);
    });

    test('defaultProfile falls back to the first profile', () {
      final settings = TtsSettings.fromResponse(
        _serverTts(defaultId: 'missing'),
      );
      expect(settings.defaultProfile!.id, 'default');
      expect(
        TtsSettings.fromResponse(_serverTts(defaultId: 'p2')).defaultProfile!.id,
        'p2',
      );
    });
  });

  group('TtsSettingsService.buildProfileUpdate', () {
    Map<String, dynamic> build(
      Map<String, Map<String, String>> providers, {
      String name = '  日常  ',
    }) => TtsSettingsService.buildProfileUpdate(
      id: 'p1',
      name: name,
      provider: 'qwen',
      timeoutSeconds: 20,
      maxChars: 100,
      providers: providers,
    );

    test('carries id, trimmed name and basic fields', () {
      final profile = build({});
      expect(profile['id'], 'p1');
      expect(profile['name'], '日常');
      expect(profile['provider'], 'qwen');
      expect(profile['timeout_seconds'], 20);
      expect(profile['max_chars'], 100);
    });

    test('omits empty api keys and sends typed ones', () {
      final profile = build({
        'mimo': {'api_key': '', 'model': 'm'},
        'qwen': {'api_key': '  new-key  ', 'voice': 'v'},
      });
      expect((profile['mimo'] as Map).containsKey('api_key'), isFalse);
      expect((profile['mimo'] as Map)['model'], 'm');
      expect((profile['qwen'] as Map)['api_key'], 'new-key');
    });

    test('never resubmits a masked key it was not given', () {
      // 表单里密钥输入框留空，脱敏值只用作提示，不会出现在 payload 里。
      final profile = build({
        'mimo': {'api_key': '', 'api_key_masked': 'sk-****1234'},
      });
      expect(profile.toString(), isNot(contains('sk-****1234')));
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

    test('sends custom templates as trimmed strings and omits blank key', () {
      final profile = build({
        'custom': {
          'api_url': ' https://tts.example/x ',
          'api_key': '',
          'method': 'GET',
          'body': '  {"q": "{{text}}"}\n',
          'response_type': 'url',
          'response_path': 'data.url',
        },
      });
      final custom = profile['custom'] as Map;
      expect(custom['api_url'], 'https://tts.example/x');
      expect(custom['method'], 'GET');
      expect(custom['body'], '{"q": "{{text}}"}');
      expect(custom['response_type'], 'url');
      expect(custom['response_path'], 'data.url');
      expect(custom.containsKey('api_key'), isFalse);
    });
  });

  group('TtsSettingsService.buildUpdates', () {
    test('contains only what was given', () {
      expect(TtsSettingsService.buildUpdates(), isEmpty);
      expect(TtsSettingsService.buildUpdates(enabled: false), {
        'enabled': false,
      });
      expect(TtsSettingsService.buildUpdates(defaultProfileId: 'p2'), {
        'default_profile_id': 'p2',
      });
      expect(
        TtsSettingsService.buildUpdates(deleteProfileIds: ['a', 'b']),
        {
          'delete_profile_ids': ['a', 'b'],
        },
      );
    });

    test('combines enabled, default, profiles and deletions', () {
      final profile = TtsSettingsService.buildProfileUpdate(
        id: 'p1',
        name: 'n',
        provider: 'mimo',
        timeoutSeconds: 10,
        maxChars: 50,
        providers: const {},
      );
      final updates = TtsSettingsService.buildUpdates(
        enabled: true,
        defaultProfileId: 'p1',
        profiles: [profile],
        deleteProfileIds: ['old'],
      );
      expect(updates['enabled'], isTrue);
      expect(updates['default_profile_id'], 'p1');
      expect((updates['profiles'] as List).single, same(profile));
      expect(updates['delete_profile_ids'], ['old']);
    });

    test('new profile ids are valid and unique', () async {
      final a = TtsSettingsService.newProfileId();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final b = TtsSettingsService.newProfileId();
      expect(a, isNot(b));
      for (final id in [a, b]) {
        expect(RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(id), isTrue, reason: id);
      }
    });
  });

  group('TtsSettingsService requests', () {
    late List<(String, Map<String, dynamic>, Duration?)> calls;
    late Map<String, dynamic> updateResponse;
    late TtsSettingsService service;

    setUp(() {
      calls = [];
      updateResponse = {'success': true, 'tts': _serverTts()['tts']};
      service = TtsSettingsService(
        request: (action, payload, {timeout}) async {
          calls.add((action, payload, timeout));
          switch (action) {
            case 'settings_tts_get':
              return _serverTts();
            case 'settings_tts_update':
              return updateResponse;
            case 'settings_tts_test':
              return {'success': true, 'latency_ms': 100};
          }
          return {};
        },
      );
    });

    test('test() carries the profile id and omits it for the default', () async {
      await service.test(profileId: 'p2');
      await service.test();
      await service.test(profileId: '  ');
      final tests = calls.where((c) => c.$1 == 'settings_tts_test').toList();
      expect(tests[0].$2, {'profile_id': 'p2'});
      expect(tests[1].$2, isEmpty);
      expect(tests[2].$2, isEmpty);
      expect(tests[0].$3, const Duration(seconds: 90));
    });

    test('update() sends updates and returns the fresh settings', () async {
      final settings = await service.update(
        enabled: true,
        deleteProfileIds: ['p2'],
      );
      final payload = calls.single.$2;
      expect(payload['updates'], {
        'enabled': true,
        'delete_profile_ids': ['p2'],
      });
      expect(settings!.profiles.map((p) => p.id), ['default', 'p2']);
    });

    test('update() returns null when the response has no tts', () async {
      updateResponse = {'success': true};
      expect(await service.update(enabled: false), isNull);
    });

    test('update() throws the server error message', () async {
      updateResponse = {'success': false, 'error': '默认档案不存在'};
      expect(
        service.update(defaultProfileId: 'nope'),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', '默认档案不存在'),
        ),
      );
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
    late Map<String, dynamic> Function() serverState;
    late Map<String, dynamic> Function(Map<String, dynamic>) onUpdate;
    late TtsSettingsService service;

    setUp(() {
      calls = [];
      serverState = _serverTts;
      onUpdate = (_) => {'success': true};
      service = TtsSettingsService(
        request: (action, payload, {timeout}) async {
          calls.add((action, payload));
          switch (action) {
            case 'settings_tts_get':
              return serverState();
            case 'settings_tts_update':
              return onUpdate(payload);
            case 'settings_tts_test':
              return {'success': true};
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

    testWidgets('lists profiles with provider, status and default tag', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('启用语音合成'), findsOneWidget);
      expect(find.byKey(const ValueKey('tts-profile-default')), findsOneWidget);
      expect(find.byKey(const ValueKey('tts-profile-p2')), findsOneWidget);
      expect(find.text('角色专用'), findsOneWidget);
      expect(find.text('MiMo'), findsOneWidget);
      expect(find.text('Qwen'), findsOneWidget);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('tts-profile-status-default')),
            )
            .data,
        '已配置',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('tts-profile-status-p2')))
            .data,
        '未配置',
      );
      // 只有默认档案带「默认」标签。
      expect(
        find.byKey(const ValueKey('tts-profile-default-tag')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tts-add-profile')), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byKey(const ValueKey('tts-enabled'))).value,
        isTrue,
      );
    });

    testWidgets('default tag follows default_profile_id', (tester) async {
      serverState = () => _serverTts(defaultId: 'p2');
      await pump(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tts-profile-p2')),
          matching: find.byKey(const ValueKey('tts-profile-default-tag')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tts-profile-default')),
          matching: find.byKey(const ValueKey('tts-profile-default-tag')),
        ),
        findsNothing,
      );
    });

    testWidgets('toggling the master switch saves only enabled', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-enabled')));
      await tester.pumpAndSettle();

      final update = calls.firstWhere((c) => c.$1 == 'settings_tts_update').$2;
      expect(update['updates'], {'enabled': false});
    });

    testWidgets('master switch rolls back when saving fails', (tester) async {
      onUpdate = (_) => {'success': false, 'error': '保存炸了'};
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-enabled')));
      await tester.pumpAndSettle();

      expect(find.textContaining('保存炸了'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byKey(const ValueKey('tts-enabled'))).value,
        isTrue,
      );
    });

    testWidgets('shows an empty hint when there are no profiles', (
      tester,
    ) async {
      serverState = () => _serverTts(profiles: [], defaultId: '');
      await pump(tester);

      expect(find.byKey(const ValueKey('tts-profiles-empty')), findsOneWidget);
      expect(find.text('还没有语音档案，请先添加'), findsOneWidget);
    });

    testWidgets('add profile creates one with a generated id', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-add-profile')));
      await tester.pumpAndSettle();
      expect(find.text('添加档案'), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('tts-profile-name')),
        '新声音',
      );
      await tester.enterText(
        find.byKey(const ValueKey('tts-field-mimo/model')),
        'm-new',
      );
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      final update = calls.firstWhere((c) => c.$1 == 'settings_tts_update').$2;
      final updates = update['updates'] as Map;
      final profile = (updates['profiles'] as List).single as Map;
      expect(
        RegExp(r'^p[a-z0-9]{1,39}$').hasMatch(profile['id'] as String),
        isTrue,
      );
      expect(profile['id'], isNot('default'));
      expect(profile['name'], '新声音');
      expect((profile['mimo'] as Map)['model'], 'm-new');
      // 已有默认档案时不改默认。
      expect(updates.containsKey('default_profile_id'), isFalse);
    });

    testWidgets('the first profile becomes the default', (tester) async {
      serverState = () => _serverTts(profiles: [], defaultId: '');
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-add-profile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      final update = calls.firstWhere((c) => c.$1 == 'settings_tts_update').$2;
      final updates = update['updates'] as Map;
      final profile = (updates['profiles'] as List).single as Map;
      expect(updates['default_profile_id'], profile['id']);
    });

    testWidgets('cannot add beyond the profile limit', (tester) async {
      serverState = () => _serverTts(
        profiles: [
          for (var i = 0; i < TtsSettingsService.maxProfiles; i++)
            _profileJson('p$i', '档案$i'),
        ],
        defaultId: 'p0',
      );
      await pump(tester);

      await tester.ensureVisible(find.byKey(const ValueKey('tts-add-profile')));
      await tester.tap(find.byKey(const ValueKey('tts-add-profile')));
      await tester.pumpAndSettle();

      expect(find.text('最多可添加 20 个档案'), findsOneWidget);
      expect(find.byKey(const ValueKey('tts-profile-name')), findsNothing);
    });

    testWidgets('editing a profile saves and refreshes the list', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-profile-p2')));
      await tester.pumpAndSettle();
      expect(find.text('编辑档案'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('tts-profile-name')))
            .controller!
            .text,
        '角色专用',
      );

      serverState = () => _serverTts(
        profiles: [
          _profileJson('default', '默认'),
          _profileJson('p2', '改名后', provider: 'qwen'),
        ],
      );
      await tester.enterText(
        find.byKey(const ValueKey('tts-profile-name')),
        '改名后',
      );
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      final update = calls.lastWhere((c) => c.$1 == 'settings_tts_update').$2;
      final profile = ((update['updates'] as Map)['profiles'] as List).single
          as Map;
      expect(profile['id'], 'p2');
      expect(profile['name'], '改名后');

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('改名后'), findsOneWidget);
      expect(find.text('角色专用'), findsNothing);
    });

    testWidgets('load failure shows the error and retry reloads', (
      tester,
    ) async {
      var fail = true;
      service = TtsSettingsService(
        request: (action, payload, {timeout}) async {
          calls.add((action, payload));
          if (fail) throw StateError('服务端未连接');
          return _serverTts();
        },
      );
      await pump(tester);

      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.textContaining('服务端未连接'), findsOneWidget);
      expect(find.byKey(const ValueKey('tts-add-profile')), findsNothing);

      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tts-profile-default')), findsOneWidget);
    });
  });

  group('TtsProfileEditorPage', () {
    late List<(String, Map<String, dynamic>)> calls;
    late Map<String, dynamic> Function(Map<String, dynamic>) onUpdate;
    late TtsSettingsService service;

    setUp(() {
      calls = [];
      onUpdate = (_) => {'success': true, 'tts': _serverTts()['tts']};
      service = TtsSettingsService(
        request: (action, payload, {timeout}) async {
          calls.add((action, payload));
          switch (action) {
            case 'settings_tts_get':
              return _serverTts();
            case 'settings_tts_update':
              return onUpdate(payload);
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

    TtsProfile profileOf(Map<String, dynamic> json) => _profileFrom(json);

    Future<void> pump(
      WidgetTester tester, {
      TtsProfile? profile,
      bool isNew = false,
      bool isDefault = true,
    }) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: TtsProfileEditorPage(
            service: service,
            profile: profile ?? profileOf(_profileJson('default', '默认')),
            isNew: isNew,
            isDefault: isDefault,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> lastUpdates() =>
        calls.lastWhere((c) => c.$1 == 'settings_tts_update').$2['updates']
            as Map<String, dynamic>;

    Map<String, dynamic> lastProfile() =>
        (lastUpdates()['profiles'] as List).single as Map<String, dynamic>;

    testWidgets('loads the profile into the form with a masked key hint', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('mimo-tts'), findsOneWidget);
      expect(find.text('已设置：sk-****1234（留空保持不变）'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('tts-profile-name')))
            .controller!
            .text,
        '默认',
      );
      expect(find.text('已配置'), findsOneWidget);
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

      expect(lastProfile()['id'], 'default');
      expect(lastProfile()['name'], '默认');
      final mimo = lastProfile()['mimo'] as Map;
      expect(mimo['model'], 'mimo-tts-2');
      expect(mimo.containsKey('api_key'), isFalse);
      // 保存当前档案不会顺带改全局开关或默认档案。
      expect(lastUpdates().containsKey('enabled'), isFalse);
      expect(lastUpdates().containsKey('default_profile_id'), isFalse);

      calls.clear();
      await tester.enterText(
        find.byKey(const ValueKey('tts-field-mimo/api_key')),
        'sk-new',
      );
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      expect((lastProfile()['mimo'] as Map)['api_key'], 'sk-new');
    });

    testWidgets('masked key is not resubmitted after a refresh', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      expect((lastProfile()['mimo'] as Map).containsKey('api_key'), isFalse);
      expect(find.text('已设置：sk-****1234（留空保持不变）'), findsOneWidget);
    });

    testWidgets('test button saves first and tests that profile', (
      tester,
    ) async {
      await pump(
        tester,
        profile: profileOf(_profileJson('p2', '角色专用')),
        isDefault: false,
      );

      await tester.tap(find.byKey(const ValueKey('tts-test')));
      await tester.pumpAndSettle();

      final actions = calls.map((c) => c.$1).toList();
      expect(
        actions.indexOf('settings_tts_update'),
        lessThan(actions.indexOf('settings_tts_test')),
      );
      expect(
        calls.firstWhere((c) => c.$1 == 'settings_tts_test').$2,
        {'profile_id': 'p2'},
      );
      expect(find.text('测试成功：耗时 850ms，大小 20.0KB，时长 2.4s'), findsOneWidget);
    });

    testWidgets('test is skipped when saving fails', (tester) async {
      onUpdate = (_) => {'success': false, 'error': '名称重复'};
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-test')));
      await tester.pumpAndSettle();

      expect(calls.where((c) => c.$1 == 'settings_tts_test'), isEmpty);
      expect(find.textContaining('名称重复'), findsOneWidget);
    });

    testWidgets('custom provider shows templates and toggles response path', (
      tester,
    ) async {
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-provider-custom')));
      await tester.pumpAndSettle();

      // 模板相关字段收在默认收起的「高级请求格式」组里。
      expect(find.text('高级请求格式'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tts-field-custom/headers')),
        findsNothing,
      );
      await tester.tap(find.text('高级请求格式'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tts-provider-help')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('tts-field-custom/headers')),
        findsOneWidget,
      );
      expect(find.text('{"input": "{{text}}"}'), findsOneWidget);
      // binary 响应没有字段路径。
      expect(
        find.byKey(const ValueKey('tts-field-custom/response_path')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('tts-field-custom/response_type')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('base64（JSON 内的 base64）').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tts-field-custom/response_path')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('tts-field-custom/response_path')),
        'data.audio',
      );
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      expect(lastProfile()['provider'], 'custom');
      final custom = lastProfile()['custom'] as Map;
      expect(custom['response_type'], 'base64');
      expect(custom['response_path'], 'data.audio');
      expect(custom['body'], '{"input": "{{text}}"}');
    });

    testWidgets('built-in providers have no advanced request group', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('高级请求格式'), findsNothing);
      expect(
        find.byKey(const ValueKey('tts-field-mimo/style')),
        findsOneWidget,
      );
    });

    testWidgets('custom provider collapses template fields by default', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('tts-provider-custom')));
      await tester.pumpAndSettle();

      // 接口地址、密钥、模型、音色、风格仍平铺。
      for (final field in ['api_url', 'api_key', 'model', 'voice', 'style']) {
        expect(
          find.byKey(ValueKey('tts-field-custom/$field')),
          findsOneWidget,
          reason: field,
        );
      }
      // 模板与响应字段收进分组，收起时不可见，摘要显示请求方法和响应类型。
      expect(find.text('高级请求格式'), findsOneWidget);
      expect(find.text('POST · binary'), findsOneWidget);
      for (final field in ['method', 'headers', 'body', 'response_type']) {
        expect(
          find.byKey(ValueKey('tts-field-custom/$field')),
          findsNothing,
          reason: field,
        );
      }
      expect(find.byKey(const ValueKey('tts-provider-help')), findsNothing);

      await tester.tap(find.text('高级请求格式'));
      await tester.pumpAndSettle();
      for (final field in ['method', 'headers', 'body', 'response_type']) {
        expect(
          find.byKey(ValueKey('tts-field-custom/$field')),
          findsOneWidget,
          reason: field,
        );
      }
      expect(find.byKey(const ValueKey('tts-provider-help')), findsOneWidget);
    });

    testWidgets('empty templates show default hints once expanded', (
      tester,
    ) async {
      await pump(
        tester,
        profile: profileOf(
          _profileJson('c', '自定义', provider: 'custom', headers: '', body: ''),
        ),
      );

      await tester.tap(find.text('高级请求格式'));
      await tester.pumpAndSettle();

      expect(
        find.text('{"Authorization": "Bearer {{api_key}}"}'),
        findsOneWidget,
      );
      expect(
        find.text('{"input": "{{text}}", "voice": "{{voice}}"}'),
        findsOneWidget,
      );
    });

    testWidgets('template edits are kept when the group is collapsed', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('tts-provider-custom')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('高级请求格式'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('tts-field-custom/body')),
        '{"q": "{{text}}"}',
      );
      await tester.tap(find.text('高级请求格式'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tts-field-custom/body')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();
      expect((lastProfile()['custom'] as Map)['body'], '{"q": "{{text}}"}');
    });

    testWidgets('save error from the server is shown', (tester) async {
      onUpdate = (_) => {'success': false, 'error': '自定义请求体不是合法的 JSON'};
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('自定义请求体不是合法的 JSON'), findsOneWidget);
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

    testWidgets('blank name is rejected before any request', (tester) async {
      await pump(tester);

      await tester.enterText(
        find.byKey(const ValueKey('tts-profile-name')),
        '   ',
      );
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pump();

      expect(calls.where((c) => c.$1 == 'settings_tts_update'), isEmpty);
      expect(find.text('请输入档案名称'), findsOneWidget);
    });

    testWidgets('set as default saves the form with default_profile_id', (
      tester,
    ) async {
      await pump(
        tester,
        profile: profileOf(_profileJson('p2', '角色专用')),
        isDefault: false,
      );
      expect(find.byKey(const ValueKey('tts-is-default')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('tts-set-default')));
      await tester.pumpAndSettle();

      expect(lastUpdates()['default_profile_id'], 'p2');
      expect(lastProfile()['id'], 'p2');
      expect(find.text('已设为默认档案'), findsOneWidget);
    });

    testWidgets('the default profile has no set-default action', (
      tester,
    ) async {
      await pump(tester);

      expect(find.byKey(const ValueKey('tts-set-default')), findsNothing);
      expect(find.byKey(const ValueKey('tts-is-default')), findsOneWidget);
    });

    testWidgets('delete asks for confirmation and sends delete_profile_ids', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => TtsProfileEditorPage(
                    service: service,
                    profile: profileOf(_profileJson('p2', '角色专用')),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // 取消：不发请求，页面保留。
      await tester.tap(find.byKey(const ValueKey('tts-delete')));
      await tester.pumpAndSettle();
      expect(find.text('删除档案'), findsWidgets);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.$1 == 'settings_tts_update'), isEmpty);
      expect(find.byKey(const ValueKey('tts-delete')), findsOneWidget);

      // 确认：发送删除并返回上一页。
      await tester.tap(find.byKey(const ValueKey('tts-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tts-delete-confirm')));
      await tester.pumpAndSettle();

      expect(lastUpdates(), {
        'delete_profile_ids': ['p2'],
      });
      expect(find.byKey(const ValueKey('tts-delete')), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('delete failure keeps the page and shows the error', (
      tester,
    ) async {
      onUpdate = (_) => {'success': false, 'error': '删除失败了'};
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('tts-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tts-delete-confirm')));
      await tester.pumpAndSettle();

      expect(find.textContaining('删除失败了'), findsOneWidget);
      expect(find.byKey(const ValueKey('tts-delete')), findsOneWidget);
    });

    testWidgets('a new profile sends everything under its own id', (
      tester,
    ) async {
      await pump(
        tester,
        profile: TtsProfile.blank(id: 'pnew1', name: '档案3'),
        isNew: true,
        isDefault: false,
      );

      expect(find.text('添加档案'), findsOneWidget);
      expect(find.text('放弃新档案'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tts-provider-custom')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tts-save')));
      await tester.pumpAndSettle();

      expect(lastProfile()['id'], 'pnew1');
      expect(lastProfile()['name'], '档案3');
      expect(lastProfile()['provider'], 'custom');
      // 下拉字段为空时落到第一个选项，不会提交空值。
      final custom = lastProfile()['custom'] as Map;
      expect(custom['method'], 'POST');
      expect(custom['response_type'], 'binary');
    });
  });
}
