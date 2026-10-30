import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zerochat/models/ai_model_profile.dart';
import 'package:zerochat/models/summary_config.dart';
import 'package:zerochat/pages/api_settings_page.dart';
import 'package:zerochat/services/secure_storage_service.dart';
import 'package:zerochat/services/settings_service.dart';
import 'package:zerochat/services/storage_service.dart';
import 'package:zerochat/widgets/prompt_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService.instance;
  final secrets = <String, String>{};
  var failWrites = false;
  const localKey = 'summary_config_context_summary';
  const secretKey = 'summary_api_key_context_summary';
  const recallLocalKey = 'summary_config_chat_recall_summary';
  const recallSecretKey = 'summary_api_key_chat_recall_summary';
  const onebotRecallLocalKey = 'summary_config_onebot_recall_summary';
  const onebotRecallSecretKey = 'summary_api_key_onebot_recall_summary';
  const profile = ModelApiProfile(
    id: 'summary-profile',
    name: 'Shared profile',
    apiUrl: 'https://api.example.test/v1',
    model: 'old-model',
    apiKey: 'profile-secret',
    capabilities: {ModelProfileCapability.chat, ModelProfileCapability.vision},
  );

  setUp(() async {
    secrets.clear();
    failWrites = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final key = args['key'] as String?;
        switch (call.method) {
          case 'readAll':
            return Map<String, String>.from(secrets);
          case 'read':
            return secrets[key];
          case 'write':
            if (failWrites) {
              throw PlatformException(code: 'storage_unavailable');
            }
            secrets[key!] = args['value'] as String;
            return null;
          case 'delete':
            secrets.remove(key);
            return null;
          case 'containsKey':
            return secrets.containsKey(key);
          default:
            throw StateError('Unexpected storage call: ${call.method}');
        }
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    await StorageService.init();
    await SecureStorageService.init();
    await SettingsService.init();
  });

  test(
    'summary secrets survive reload without plaintext preferences',
    () async {
      final config = SummaryApiConfig(apiKey: 'summary-secret');
      expect(config.copy().apiKey, 'summary-secret');
      expect(config.toLocalJson().containsKey('api_key'), isFalse);
      await settings.updateContextSummaryConfig(config);
      expect(StorageService.getJson(localKey)!.containsKey('api_key'), isFalse);
      expect(secrets[secretKey], 'summary-secret');
      await SecureStorageService.init();
      await SettingsService.init();
      expect(settings.contextSummaryConfig.apiKey, 'summary-secret');
    },
  );

  test('chat recall feature uses its own storage keys and settings', () {
    expect(SummaryFeature.chatRecall.storageValue, 'chat_recall_summary');
    expect(SummaryFeature.chatRecall.title, '聊天回顾总结');
    expect(
      SummaryFeature.chatRecall.description,
      'AI 按指定时间/事件查阅历史聊天时，用此模型总结相关内容',
    );
    expect(
      settings.summaryConfigFor(SummaryFeature.context),
      same(settings.contextSummaryConfig),
    );
    expect(
      settings.summaryConfigFor(SummaryFeature.coreMemory),
      same(settings.coreMemorySummaryConfig),
    );
    expect(
      settings.summaryConfigFor(SummaryFeature.chatRecall),
      same(settings.chatRecallSummaryConfig),
    );
  });

  test('onebot recall feature has its own storage keys and settings', () {
    expect(SummaryFeature.onebotRecall.storageValue, 'onebot_recall_summary');
    expect(SummaryFeature.onebotRecall.title, 'QQ 消息回顾总结');
    expect(
      settings.summaryConfigFor(SummaryFeature.onebotRecall),
      same(settings.onebotRecallSummaryConfig),
    );
    expect(
      settings.summaryConfigFor(SummaryFeature.onebotRecall),
      isNot(same(settings.chatRecallSummaryConfig)),
    );
  });

  test('onebot recall secret and profile binding are isolated', () async {
    await settings.updateChatRecallSummaryConfig(
      SummaryApiConfig(apiKey: 'recall-secret', model: 'recall-model'),
    );
    await settings.updateOnebotRecallSummaryConfig(
      SummaryApiConfig(apiKey: 'onebot-secret', model: 'onebot-model'),
    );
    expect(
      StorageService.getJson(onebotRecallLocalKey)!.containsKey('api_key'),
      isFalse,
    );
    expect(secrets[onebotRecallSecretKey], 'onebot-secret');
    expect(secrets[recallSecretKey], 'recall-secret');
    await SecureStorageService.init();
    await SettingsService.init();
    expect(settings.onebotRecallSummaryConfig.apiKey, 'onebot-secret');
    expect(settings.onebotRecallSummaryConfig.model, 'onebot-model');
    expect(settings.chatRecallSummaryConfig.model, 'recall-model');
  });

  test(
    'chat recall secret lives in secure storage and is isolated from other features',
    () async {
      await settings.updateContextSummaryConfig(
        SummaryApiConfig(apiKey: 'context-secret', model: 'context-model'),
      );
      await settings.updateChatRecallSummaryConfig(
        SummaryApiConfig(apiKey: 'recall-secret', model: 'recall-model'),
      );
      expect(
        StorageService.getJson(recallLocalKey)!.containsKey('api_key'),
        isFalse,
      );
      expect(secrets[recallSecretKey], 'recall-secret');
      expect(secrets[secretKey], 'context-secret');
      await SecureStorageService.init();
      await SettingsService.init();
      expect(settings.chatRecallSummaryConfig.apiKey, 'recall-secret');
      expect(settings.chatRecallSummaryConfig.model, 'recall-model');
      expect(settings.contextSummaryConfig.apiKey, 'context-secret');
      expect(settings.coreMemorySummaryConfig.apiKey, isEmpty);
    },
  );

  test('chat recall binds a profile and follows later profile edits', () async {
    await settings.saveApiProfile(profile);
    await settings.updateChatRecallSummaryConfig(
      SummaryApiConfig(profileId: profile.id),
    );
    expect(settings.chatRecallSummaryConfig.profileId, profile.id);
    expect(settings.chatRecallSummaryConfig.model, 'old-model');
    expect(settings.chatRecallSummaryConfig.apiKey, 'profile-secret');
    expect(settings.contextSummaryConfig.profileId, isNull);

    await settings.saveApiProfile(
      ModelApiProfile(
        id: profile.id,
        name: profile.name,
        apiUrl: profile.apiUrl,
        model: 'edited-model',
        apiKey: 'edited-secret',
        capabilities: profile.capabilities,
      ),
    );
    final payload = settings.summaryConfigPayload(
      settings.chatRecallSummaryConfig,
    );
    expect(payload['model'], 'edited-model');
    expect(payload['api_key'], 'edited-secret');
    expect(payload.containsKey('profile_id'), isFalse);

    await SecureStorageService.init();
    await SettingsService.init();
    expect(settings.chatRecallSummaryConfig.profileId, profile.id);
    expect(StorageService.getJson(recallLocalKey)!['profile_id'], profile.id);
  });

  test('legacy nested secret migrates before plaintext is removed', () async {
    await StorageService.setJson(localKey, {
      'api_key': 'legacy-secret',
      'model': 'legacy-model',
    });
    await SettingsService.init();
    expect(secrets[secretKey], 'legacy-secret');
    expect(StorageService.getJson(localKey)!.containsKey('api_key'), isFalse);
    expect(settings.contextSummaryConfig.apiKey, 'legacy-secret');
    expect(settings.contextSummaryConfig.model, 'legacy-model');
  });

  test('failed migration preserves data and startup can retry', () async {
    await StorageService.setJson(localKey, {'api_key': 'legacy-secret'});
    failWrites = true;
    await SettingsService.init();
    expect(StorageService.getJson(localKey)!['api_key'], 'legacy-secret');
    expect(settings.contextSummaryConfig.apiKey, 'legacy-secret');
    expect(secrets.containsKey(secretKey), isFalse);
    failWrites = false;
    await SettingsService.init();
    expect(secrets[secretKey], 'legacy-secret');
    expect(StorageService.getJson(localKey)!.containsKey('api_key'), isFalse);
  });

  test('cleared profile parameters replace stale summary overrides', () async {
    await settings.saveApiProfile(profile);
    final resolved = settings.applyBoundProfile(
      SummaryApiConfig(
        profileId: profile.id,
        timeoutSeconds: 999,
        reasoningEffort: 'high',
        thinkingEnabled: false,
        thinkingBudget: 8192,
      ),
    );
    expect(resolved.timeoutSeconds, settings.chatTimeoutSeconds);
    expect(resolved.reasoningEffort, isEmpty);
    expect(resolved.thinkingEnabled, isNull);
    expect(resolved.thinkingBudget, isNull);
  });

  Future<void> openSummary(
    WidgetTester tester, {
    SummaryFeature feature = SummaryFeature.context,
  }) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: SummaryModelSettingsPage(feature: feature)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('matching URL and model do not bind an independent secret', (
    tester,
  ) async {
    await settings.saveApiProfile(profile);
    await settings.updateContextSummaryConfig(
      SummaryApiConfig(
        apiUrl: profile.apiUrl,
        model: profile.model,
        apiKey: 'independent-secret',
      ),
    );
    await openSummary(tester);
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    expect(settings.contextSummaryConfig.profileId, isNull);
    expect(settings.contextSummaryConfig.apiKey, 'independent-secret');
    expect(tester.takeException(), isNull);
  });

  testWidgets('bound summary opens and saves latest profile parameters', (
    tester,
  ) async {
    await settings.saveApiProfile(profile);
    await settings.updateContextSummaryConfig(
      SummaryApiConfig(profileId: profile.id),
    );
    await settings.saveApiProfile(
      ModelApiProfile(
        id: profile.id,
        name: profile.name,
        apiUrl: profile.apiUrl,
        model: 'new-model',
        apiKey: 'new-secret',
        capabilities: profile.capabilities,
        thinkingEnabled: false,
      ),
    );
    await openSummary(tester);
    expect(find.text('new-model'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    expect(settings.contextSummaryConfig.profileId, profile.id);
    expect(settings.contextSummaryConfig.model, 'new-model');
    expect(settings.contextSummaryConfig.apiKey, 'new-secret');
    expect(settings.contextSummaryConfig.thinkingEnabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat recall page saves its own config and bound profile', (
    tester,
  ) async {
    await settings.saveApiProfile(profile);
    await settings.updateChatRecallSummaryConfig(
      SummaryApiConfig(profileId: profile.id),
    );
    await openSummary(tester, feature: SummaryFeature.chatRecall);
    expect(find.text(SummaryFeature.chatRecall.title), findsWidgets);
    expect(find.text('old-model'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    expect(settings.chatRecallSummaryConfig.profileId, profile.id);
    expect(settings.chatRecallSummaryConfig.apiKey, 'profile-secret');
    expect(secrets[recallSecretKey], 'profile-secret');
    expect(StorageService.getJson(localKey), isNull);
    expect(settings.contextSummaryConfig.profileId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed secure save leaves existing config and permits retry', (
    tester,
  ) async {
    await settings.updateContextSummaryConfig(
      SummaryApiConfig(apiKey: 'saved-secret'),
    );
    await openSummary(tester);
    failWrites = true;
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('设置保存失败，请重试'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed,
      isNotNull,
    );
    expect(settings.contextSummaryConfig.apiKey, 'saved-secret');
    expect(secrets[secretKey], 'saved-secret');
    expect(tester.takeException(), isNull);
    failWrites = false;
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('prompts page only edits the global scope', (tester) async {
    await settings.saveApiProfile(profile);
    await tester.pumpWidget(const MaterialApp(home: PromptsPage()));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<String?>), findsNothing);
    expect(find.text('作用范围'), findsNothing);
    expect(find.textContaining(profile.name), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final action in ['保存', '取消', '恢复默认']) {
    testWidgets('prompt editor closes safely via $action', (tester) async {
      Map<String, String>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showPromptEditor(
                      context,
                      prompt: const ConfigurablePrompt(
                        id: 'test',
                        title: 'Test prompt',
                        group: 'chat',
                        origin: 'chat',
                        appliesTo: ['chat'],
                        builtin: 'builtin',
                      ),
                      current: const {},
                      scopeLabel: 'Global',
                    );
                  },
                  child: const Text('Open'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'edited');
      await tester.tap(find.text(action));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        result,
        action == '保存'
            ? {'__builtin__': 'edited', '__base_version__': '1'}
            : action == '取消'
            ? null
            : {},
      );
    });
  }
}
