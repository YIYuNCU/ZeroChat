import 'package:flutter/foundation.dart';

import 'secure_websocket_client.dart';
import 'settings_service.dart';

enum IntentType {
  normalChat,
  setMemory,
  setReminder,
  setQuietTime,
  clearMemory,
}

class IntentResult {
  final IntentType type;
  final String? extractedContent;
  final Duration? duration;
  final int? startHour;
  final int? endHour;
  final double confidence;

  IntentResult({
    required this.type,
    this.extractedContent,
    this.duration,
    this.startHour,
    this.endHour,
    this.confidence = 1.0,
  });

  @override
  String toString() {
    return 'IntentResult(type: $type, content: $extractedContent, confidence: $confidence)';
  }
}

/// Detects user intent exclusively through the authenticated backend.
class IntentService {
  static String _intentApiUrl = '';
  static String _intentApiKey = '';
  static String _intentModel = 'gpt-3.5-turbo';

  static bool useAiIntent = false;

  static void configure({
    required String apiUrl,
    required String apiKey,
    String model = 'gpt-3.5-turbo',
    bool useAi = false,
  }) {
    _intentApiUrl = apiUrl;
    _intentApiKey = apiKey;
    _intentModel = model;
    useAiIntent = useAi;
    debugPrint('IntentService configured: useAI=$useAiIntent');
  }

  static Future<IntentResult> detectIntent(String message) async {
    if (useAiIntent) {
      try {
        final backendResult = await _detectByBackend(message);
        if (backendResult != null) {
          debugPrint('Intent detected by backend AI: ${backendResult.type}');
          return backendResult;
        }
      } catch (error) {
        debugPrint('Backend intent detection failed: $error');
      }

      debugPrint(
        'IntentService: direct fallback skipped (manual confirmation required)',
      );
    }

    return IntentResult(type: IntentType.normalChat);
  }

  static Future<IntentResult?> _detectByBackend(String message) async {
    if (SettingsService.instance.backendUrl.isEmpty) {
      return null;
    }

    final data = await SecureWebSocketClient.instance.request('ai_intent', {
      'message': message,
      'api_url': _intentApiUrl,
      'api_key': _intentApiKey,
      'model': _intentModel,
    });

    if (data['success'] != true) {
      return null;
    }

    return _parseIntentMap(data);
  }

  static IntentResult _parseIntentMap(Map<String, dynamic> json) {
    final intentStr = json['intent'] as String? ?? 'normal_chat';
    final type = switch (intentStr) {
      'set_memory' => IntentType.setMemory,
      'set_reminder' => IntentType.setReminder,
      'set_quiet_time' => IntentType.setQuietTime,
      'clear_memory' => IntentType.clearMemory,
      _ => IntentType.normalChat,
    };

    final durationSeconds = json['duration_seconds'] as int?;
    return IntentResult(
      type: type,
      extractedContent: json['extracted_content'] as String?,
      duration: durationSeconds == null
          ? null
          : Duration(seconds: durationSeconds),
      startHour: json['start_hour'] as int?,
      endHour: json['end_hour'] as int?,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.8,
    );
  }
}
