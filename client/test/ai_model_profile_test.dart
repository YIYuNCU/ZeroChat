import 'package:flutter_test/flutter_test.dart';
import 'package:zerochat/models/ai_model_profile.dart';

void main() {
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
}
