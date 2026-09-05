import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/ai_model_profile.dart';
import 'package:zerochat/models/role.dart';

void main() {
  test('thinking overrides round trip and legacy quotas migrate', () {
    final profile = ModelApiProfile.fromJson({
      'id': 'thinking',
      'thinking_enabled': false,
      'thinking_budget': 4096,
      'reasoning_effort': 'high',
    });
    final restored = ModelApiProfile.fromJson(profile.toJson());
    expect(restored.thinkingEnabled, isFalse);
    expect(restored.thinkingBudget, 4096);
    expect(restored.reasoningEffort, 'high');
    final legacy = ModelApiProfile.fromJson({'reasoning_effort': '8192'});
    expect(legacy.reasoningEffort, isNull);
    expect(legacy.thinkingBudget, 8192);
    expect(ModelApiProfile.fromJson({}).thinkingEnabled, isNull);
  });

  test('switching profiles clears role thinking overrides', () {
    final role = Role(
      id: 'role',
      name: 'Role',
      systemPrompt: '',
      aiThinkingEnabled: false,
      aiThinkingBudget: 4096,
      aiReasoningEffort: 'high',
    );
    final inherited = Role.fromJson(
      role.copyWith(clearThinkingOverrides: true).toJson(),
    );
    expect(inherited.aiThinkingEnabled, isNull);
    expect(inherited.aiThinkingBudget, isNull);
    expect(inherited.aiReasoningEffort, isNull);
    final restored = Role.fromJson(role.toJson());
    expect(restored.aiThinkingEnabled, isFalse);
    expect(restored.aiThinkingBudget, 4096);
  });

  test('budget is offered only for supported protocols', () {
    expect(
      supportsThinkingBudget('https://api.siliconflow.cn/v1', 'auto', ''),
      isTrue,
    );
    expect(
      supportsThinkingBudget(
        'https://dashscope.aliyuncs.com/compatible-mode/v1',
        'auto',
        '',
      ),
      isTrue,
    );
    expect(
      supportsThinkingBudget('https://gateway.example', 'gemini_native', ''),
      isTrue,
    );
    expect(
      supportsThinkingBudget('https://api.deepseek.com/v1', 'auto', ''),
      isFalse,
    );
  });

  test('chat profile defaults legacy protocol to auto', () {
    final profile = AiModelProfile.fromJson({
      'id': 'chat-1',
      'name': 'Chat',
      'api_url': 'https://example.com/v1',
      'model': 'example-chat',
    });

    expect(profile.apiFormat, 'auto');
    expect(profile.toJson()['api_format'], 'auto');
  });

  test('vision profile persists protocol and runtime mode', () {
    final profile = VisionModelProfile.fromJson({
      'id': 'vision-1',
      'name': 'Vision',
      'api_url': 'https://generativelanguage.googleapis.com/v1beta',
      'model': 'gemini-2.5-flash',
      'api_format': 'gemini_native',
      'enabled': false,
      'mode': 'pre_model',
    }, apiKey: 'secret');

    expect(profile.apiKey, 'secret');
    expect(profile.apiFormat, 'gemini_native');
    expect(profile.enabled, isFalse);
    expect(profile.mode, 'pre_model');
    expect(profile.toJson(), containsPair('api_format', 'gemini_native'));
    expect(profile.toJson(), isNot(contains('api_key')));
  });

  test('unified profile filters capabilities and keeps keys out of JSON', () {
    const profile = ModelApiProfile(
      id: 'shared-1',
      name: 'Shared provider',
      apiUrl: 'https://example.com/v1',
      model: 'example-model',
      apiKey: 'secret',
      apiFormat: 'openai_compatible',
      capabilities: {
        ModelProfileCapability.chat,
        ModelProfileCapability.intent,
      },
    );

    expect(profile.supports(ModelProfileCapability.chat), isTrue);
    expect(profile.supports(ModelProfileCapability.vision), isFalse);
    expect(profile.toJson()['capabilities'], contains('intent'));
    expect(profile.toJson(), isNot(contains('api_key')));
  });

  test('role-specific chat settings survive JSON round trip', () {
    final role = Role(
      id: 'role-1',
      name: 'Role',
      systemPrompt: 'Prompt',
      aiTimeoutSeconds: 240,
      aiReasoningEffort: 'high',
      aiStream: true,
    );

    final restored = Role.fromJson(role.toJson());
    expect(restored.aiTimeoutSeconds, 240);
    expect(restored.aiReasoningEffort, 'high');
    expect(restored.aiStream, isTrue);
  });
}
