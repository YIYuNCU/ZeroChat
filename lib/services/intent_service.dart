import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 意图类型枚举
enum IntentType {
  normalChat, // 普通聊天
  setMemory, // 设定记忆："记住我喜欢猫"
  setReminder, // 设定提醒："10分钟后提醒我喝水"
  setQuietTime, // 设定安静时间："晚上11点到早上7点不要打扰我"
  clearMemory, // 清除记忆："忘记我说过的话"
}

/// 意图识别结果
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

/// 意图识别服务
/// 支持关键词规则和 AI 分类两种方式
class IntentService {
  // 独立的意图识别 API 配置
  static String _intentApiUrl = '';
  static String _intentApiKey = '';
  static String _intentModel = 'gpt-3.5-turbo';

  /// 是否启用 AI 意图识别
  static bool useAiIntent = false;

  /// 配置意图识别 API（独立于聊天 API）
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

  /// 识别用户意图（仅使用 AI 分类，不使用关键词规则）
  static Future<IntentResult> detectIntent(String message) async {
    // 仅当启用 AI 意图识别时才调用
    if (useAiIntent && _intentApiKey.isNotEmpty) {
      try {
        final aiResult = await _detectByAI(message);
        debugPrint('Intent detected by AI: ${aiResult.type}');
        return aiResult;
      } catch (e) {
        debugPrint('AI intent detection failed: $e');
      }
    }

    return IntentResult(type: IntentType.normalChat);
  }

  /// 解析时长
  static Duration? _parseDuration(String message) {
    final pattern = RegExp(r'(\d+)\s*(秒|分钟|小时|分|时)');
    final match = pattern.firstMatch(message);
    if (match != null) {
      final value = int.tryParse(match.group(1) ?? '') ?? 0;
      final unit = match.group(2) ?? '';
      switch (unit) {
        case '秒':
          return Duration(seconds: value);
        case '分':
        case '分钟':
          return Duration(minutes: value);
        case '时':
        case '小时':
          return Duration(hours: value);
      }
    }
    return null;
  }

  /// 解析安静时间
  static Map<String, int>? _parseQuietHours(String message) {
    final pattern = RegExp(r'(\d+)\s*点.*?(\d+)\s*点');
    final match = pattern.firstMatch(message);
    if (match != null) {
      final start = int.tryParse(match.group(1) ?? '');
      final end = int.tryParse(match.group(2) ?? '');
      if (start != null && end != null) {
        return {'start': start, 'end': end};
      }
    }
    return null;
  }

  /// AI 意图分类
  static Future<IntentResult> _detectByAI(String message) async {
    const systemPrompt = '''
你是一个意图分类器。根据用户输入，返回一个 JSON 对象，格式如下：
{
  "intent": "normal_chat" | "set_memory" | "set_reminder" | "set_quiet_time" | "clear_memory",
  "extracted_content": "提取的关键内容",
  "duration_seconds": 数字（仅提醒类有效）,
  "start_hour": 数字（仅安静时间有效）,
  "end_hour": 数字（仅安静时间有效）,
  "confidence": 0.0-1.0
}

意图说明：
- normal_chat: 普通聊天对话
- set_memory: 用户希望你记住某些信息，如"记住我喜欢猫"
- set_reminder: 用户希望设置提醒，如"10分钟后提醒我喝水"
- set_quiet_time: 用户希望设置免打扰时间，如"晚上11点到早上7点不要打扰我"
- clear_memory: 用户希望清除之前的记忆

只返回 JSON，不要其他内容。
''';

    try {
      final response = await http.post(
        Uri.parse('$_intentApiUrl/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_intentApiKey',
        },
        body: jsonEncode({
          'model': _intentModel,
          'messages': [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': message},
          ],
          'temperature': 0.1,
          'max_tokens': 200,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null) {
          return _parseAIResponse(content);
        }
      }
    } catch (e) {
      debugPrint('AI intent error: $e');
    }

    return IntentResult(type: IntentType.normalChat);
  }

  /// 解析 AI 响应
  static IntentResult _parseAIResponse(String content) {
    try {
      // 提取 JSON
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(content);
      if (jsonMatch == null) return IntentResult(type: IntentType.normalChat);

      final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      final intentStr = json['intent'] as String? ?? 'normal_chat';

      IntentType type;
      switch (intentStr) {
        case 'set_memory':
          type = IntentType.setMemory;
          break;
        case 'set_reminder':
          type = IntentType.setReminder;
          break;
        case 'set_quiet_time':
          type = IntentType.setQuietTime;
          break;
        case 'clear_memory':
          type = IntentType.clearMemory;
          break;
        default:
          type = IntentType.normalChat;
      }

      Duration? duration;
      final durationSeconds = json['duration_seconds'] as int?;
      if (durationSeconds != null) {
        duration = Duration(seconds: durationSeconds);
      }

      return IntentResult(
        type: type,
        extractedContent: json['extracted_content'] as String?,
        duration: duration,
        startHour: json['start_hour'] as int?,
        endHour: json['end_hour'] as int?,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0.8,
      );
    } catch (e) {
      debugPrint('Error parsing AI intent response: $e');
      return IntentResult(type: IntentType.normalChat);
    }
  }
}
