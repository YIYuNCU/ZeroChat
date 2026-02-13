import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/role.dart';
import 'settings_service.dart';

/// API 服务
/// 用于调用第三方 AI API（支持 OpenAI 兼容接口）
class ApiService {
  // 聊天 API 配置（优先使用 SettingsService 的配置）
  static String _baseUrl = 'https://api.openai.com/v1';
  static String? _apiKey;
  static String _model = 'gpt-3.5-turbo';

  /// 最大上下文轮数（每轮包含用户消息和AI回复）
  static int maxContextRounds = 10;

  /// 获取当前使用的 API URL
  static String get _effectiveUrl {
    final settingsUrl = SettingsService.instance.chatApiUrl;
    return settingsUrl.isNotEmpty ? settingsUrl : _baseUrl;
  }

  /// 获取当前使用的 API Key
  static String? get _effectiveKey {
    final settingsKey = SettingsService.instance.chatApiKey;
    return settingsKey.isNotEmpty ? settingsKey : _apiKey;
  }

  /// 获取当前使用的模型
  static String get _effectiveModel {
    final settingsModel = SettingsService.instance.chatModel;
    return settingsModel.isNotEmpty ? settingsModel : _model;
  }

  /// 配置聊天 API（备用配置，优先使用 SettingsService）
  static void configure({
    required String baseUrl,
    required String apiKey,
    String model = 'gpt-3.5-turbo',
    int maxRounds = 10,
  }) {
    _baseUrl = baseUrl;
    _apiKey = apiKey;
    _model = model;
    maxContextRounds = maxRounds;
    debugPrint('ApiService configured: $_baseUrl, model: $_model');
  }

  /// 设置 API Key
  static void setApiKey(String key) {
    _apiKey = key;
  }

  /// 设置 API 地址
  static void setBaseUrl(String url) {
    _baseUrl = url;
  }

  /// 设置模型
  static void setModel(String model) {
    _model = model;
  }

  /// 发送聊天消息到 AI 接口（使用角色参数）
  /// [message] 用户当前发送的消息
  /// [role] 当前使用的角色（包含 systemPrompt 和参数）
  /// [history] 对话历史
  /// [coreMemory] 核心记忆内容
  /// [isGroup] 是否为群聊
  static Future<ApiResponse> sendChatMessageWithRole({
    required String message,
    required Role role,
    List<Map<String, String>>? history,
    List<String>? coreMemory,
    bool isGroup = false,
  }) async {
    // 检查 API Key
    final apiKey = _effectiveKey;
    if (apiKey == null || apiKey.isEmpty) {
      return ApiResponse.error('请先在"我"->"AI接口设置"中配置 API Key');
    }

    try {
      // 构建消息列表
      final List<Map<String, String>> messages = [];

      // 使用 SettingsService 构建完整的系统提示词（包含全局 base prompt）
      String fullSystemPrompt = SettingsService.instance.buildSystemPrompt(
        rolePrompt: role.systemPrompt,
        isGroup: isGroup,
      );

      // 添加核心记忆
      if (coreMemory != null && coreMemory.isNotEmpty) {
        fullSystemPrompt += '\n\n[核心记忆 - 用户的重要信息]\n${coreMemory.join('\n')}';
      }
      messages.add({'role': 'system', 'content': fullSystemPrompt});

      // 添加对话历史
      if (history != null) {
        messages.addAll(history);
      }

      // 添加当前用户消息
      messages.add({'role': 'user', 'content': message});

      // ========== 详细调试日志 ==========
      debugPrint('═══════════════════════════════════════════════════════════');
      debugPrint(
        '🔷 API Request: role=${role.name}, messages=${messages.length}',
      );
      debugPrint(
        '📝 System Prompt: ${fullSystemPrompt.length > 200 ? '${fullSystemPrompt.substring(0, 200)}...' : fullSystemPrompt}',
      );
      debugPrint('💬 User Message: $message');
      if (history != null && history.isNotEmpty) {
        debugPrint('📜 History: ${history.length} messages');
        for (var i = 0; i < history.length && i < 3; i++) {
          debugPrint(
            '   └─ ${history[i]['role']}: ${history[i]['content']?.toString().substring(0, history[i]['content']!.length > 50 ? 50 : history[i]['content']!.length)}...',
          );
        }
      }
      debugPrint(
        '⚙️ Params: temp=${role.temperature}, freq=${role.frequencyPenalty}, pres=${role.presencePenalty}',
      );
      debugPrint('───────────────────────────────────────────────────────────');

      final response = await http.post(
        Uri.parse('$_effectiveUrl/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'model': _effectiveModel,
          'messages': messages,
          'temperature': role.temperature,
          'top_p': role.topP,
          'frequency_penalty': role.frequencyPenalty,
          'presence_penalty': role.presencePenalty,
          'max_tokens': 2000,
        }),
      );

      debugPrint('📡 API Response: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final content = data['choices']?[0]?['message']?['content'] as String?;
        if (content != null) {
          debugPrint(
            '🤖 AI Response: ${content.length > 300 ? '${content.substring(0, 300)}...' : content}',
          );
          debugPrint(
            '═══════════════════════════════════════════════════════════',
          );
          return ApiResponse.success(content.trim());
        }
        return ApiResponse.error('AI 返回内容为空');
      } else {
        final errorBody = response.body;
        debugPrint('❌ API Error: $errorBody');
        debugPrint(
          '═══════════════════════════════════════════════════════════',
        );
        return ApiResponse.error('API 请求失败 (${response.statusCode})');
      }
    } catch (e) {
      debugPrint('❌ API Exception: $e');
      debugPrint('═══════════════════════════════════════════════════════════');
      return ApiResponse.error('网络错误: $e');
    }
  }

  /// 发送聊天消息（不使用角色，使用默认参数）
  static Future<ApiResponse> sendChatMessage({
    required String message,
    String? systemPrompt,
    List<Map<String, String>>? history,
    List<String>? coreMemory,
  }) async {
    // 创建临时角色使用默认参数
    final tempRole = Role(
      id: 'temp',
      name: 'Temp',
      systemPrompt: systemPrompt ?? '你是一个友好的AI助手。',
    );
    return sendChatMessageWithRole(
      message: message,
      role: tempRole,
      history: history,
      coreMemory: coreMemory,
    );
  }

  /// 快速发送消息（不带历史）
  static Future<ApiResponse> quickChat(String message) async {
    return sendChatMessage(message: message);
  }

  /// 获取当前配置的模型
  static String get currentModel => _model;

  /// 检查 API 是否已配置
  static bool get isConfigured => _apiKey != null && _apiKey!.isNotEmpty;

  // ========== 后端集成 ==========

  /// 获取后端 URL
  static String get _backendUrl => SettingsService.instance.backendUrl;

  /// 通过后端调用 AI（统一入口）
  /// [roleId] 角色 ID
  /// [eventType] 事件类型: chat, task, proactive, moment, comment
  /// [content] 消息内容
  /// [context] 额外上下文
  static Future<ApiResponse> callBackendAI({
    required String roleId,
    required String eventType,
    String content = '',
    Map<String, dynamic>? context,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$_backendUrl/api/ai/event'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'role_id': roleId,
          'event_type': eventType,
          'content': content,
          'context': context ?? {},
        }),
      );

      debugPrint('ApiService: Backend AI call - $eventType for $roleId');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true && data['content'] != null) {
          return ApiResponse.success(data['content']);
        } else if (data['action'] == 'ignore') {
          return ApiResponse.error('AI chose to ignore');
        } else {
          return ApiResponse.error(data['error'] ?? 'Unknown error');
        }
      } else {
        return ApiResponse.error('Backend error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('ApiService: Backend call failed: $e');
      return ApiResponse.error('后端服务不可用: $e');
    }
  }

  /// 通过后端发送聊天消息
  /// 这是 sendChatMessageWithRole 的后端版本
  static Future<ApiResponse> sendChatViaBackend({
    required String roleId,
    required String message,
  }) async {
    return callBackendAI(roleId: roleId, eventType: 'chat', content: message);
  }

  /// 检查后端是否可用
  static Future<bool> isBackendAvailable() async {
    try {
      final response = await http
          .get(Uri.parse('$_backendUrl/api/health'))
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// 图片识别聊天（通过后端调用 vision API）
  static Future<String> chatWithImage({
    required String imagePath,
    required String userPrompt,
    required String rolePersona,
  }) async {
    try {
      // 读取图片并转为 base64
      final file = await _readImageFile(imagePath);
      final base64Image = base64Encode(file);

      // 判断图片类型
      final ext = imagePath.split('.').last.toLowerCase();
      final mimeType = ext == 'png' ? 'image/png' : 'image/jpeg';

      // 调用后端 vision API
      final response = await http
          .post(
            Uri.parse('$_backendUrl/api/chat/vision'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'image_base64': base64Image,
              'mime_type': mimeType,
              'user_prompt': userPrompt,
              'system_prompt': rolePersona,
            }),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['reply'] ?? '图片识别失败';
      } else {
        debugPrint('Vision API error: ${response.statusCode} ${response.body}');
        return '图片识别失败：服务器错误 ${response.statusCode}';
      }
    } catch (e) {
      debugPrint('chatWithImage error: $e');
      return '图片识别失败：$e';
    }
  }

  /// 读取图片文件为字节数组
  static Future<List<int>> _readImageFile(String path) async {
    final file = File(path);
    return await file.readAsBytes();
  }
}

/// API 响应封装
class ApiResponse {
  final bool success;
  final String? content;
  final String? error;

  ApiResponse._({required this.success, this.content, this.error});

  factory ApiResponse.success(String content) {
    return ApiResponse._(success: true, content: content);
  }

  factory ApiResponse.error(String error) {
    return ApiResponse._(success: false, error: error);
  }
}
