import 'package:flutter/foundation.dart';
import 'storage_service.dart';
import 'intent_service.dart';
import 'secure_backend_client.dart';

/// 全局设置服务
/// 管理 API 配置、全局提示词等
class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  static SettingsService get instance => _instance;

  // ========== 用户信息 ==========
  String _userNickname = 'ZeroChat';
  String _userAvatarUrl = '';
  String _userAvatarHash = '';

  // ========== 显示设置 ==========
  String _coverImageUrl = '';
  String _chatBackgroundUrl = '';

  // ========== 后端服务器 ==========
  String _backendUrl = 'http://localhost:8000';
  String _backendAuthToken = SecureBackendClient.defaultAuthToken;
  String _backendEncryptionSecret =
      SecureBackendClient.defaultEncryptionSecret;

  // ========== API 配置 ==========

  // 主聊天 API
  String _chatApiUrl = '';
  String _chatApiKey = '';
  String _chatModel = 'gpt-3.5-turbo';

  // 意图识别 API
  bool _intentEnabled = false;
  String _intentApiUrl = '';
  String _intentApiKey = '';
  String _intentModel = 'gpt-3.5-turbo';

  // 图像识别 API
  bool _visionEnabled = false;
  String _visionApiUrl = '';
  String _visionApiKey = '';
  String _visionModel = 'gpt-4-vision-preview';

  // ========== 全局提示词 ==========
  String _basePrompt = '';
  String _groupPrompt = '';
  String _memoryPrompt = '';

  // ========== 消息等待时间 ==========
  int _messageWaitSeconds = 0; // 0 表示禁用

  // ========== 后台运行 ==========
  bool _backgroundRuntimeEnabled = true;
  int _backgroundPollIntervalSeconds = 45;

  // ========== Getters ==========

  String get userNickname => _userNickname;
  String get userAvatarUrl => _userAvatarUrl;
  String get userAvatarHash => _userAvatarHash;

  String get chatApiUrl => _chatApiUrl;
  String get chatApiKey => _chatApiKey;
  String get chatModel => _chatModel;

  bool get intentEnabled => _intentEnabled;
  String get intentApiUrl => _intentApiUrl;
  String get intentApiKey => _intentApiKey;
  String get intentModel => _intentModel;

  bool get visionEnabled => _visionEnabled;
  String get visionApiUrl => _visionApiUrl;
  String get visionApiKey => _visionApiKey;
  String get visionModel => _visionModel;

  String get basePrompt => _basePrompt;
  String get groupPrompt => _groupPrompt;
  String get memoryPrompt => _memoryPrompt;

  String get coverImageUrl => _coverImageUrl;
  String get chatBackgroundUrl => _chatBackgroundUrl;

  String get backendUrl => _backendUrl;
  String get backendAuthToken => _backendAuthToken;
  String get backendEncryptionSecret => _backendEncryptionSecret;

  int get messageWaitSeconds => _messageWaitSeconds;
  bool get backgroundRuntimeEnabled => _backgroundRuntimeEnabled;
  int get backgroundPollIntervalSeconds => _backgroundPollIntervalSeconds;

  /// 初始化
  static Future<void> init() async {
    await _instance._loadSettings();
    debugPrint('SettingsService initialized');
  }

  /// 加载设置
  Future<void> _loadSettings() async {
    // 用户信息
    _userNickname = StorageService.getString('user_nickname') ?? 'ZeroChat';
    _userAvatarUrl = StorageService.getString('user_avatar_url') ?? '';
    _userAvatarHash = StorageService.getString('user_avatar_hash') ?? '';

    // 主聊天 API
    _chatApiUrl = StorageService.getString('chat_api_url') ?? '';
    _chatApiKey = StorageService.getString('chat_api_key') ?? '';
    _chatModel = StorageService.getString('chat_model') ?? 'gpt-3.5-turbo';

    // 意图识别 API
    _intentEnabled = StorageService.getBool('intent_enabled') ?? false;
    _intentApiUrl = StorageService.getString('intent_api_url') ?? '';
    _intentApiKey = StorageService.getString('intent_api_key') ?? '';
    _intentModel = StorageService.getString('intent_model') ?? 'gpt-3.5-turbo';

    // 图像识别 API
    _visionEnabled = StorageService.getBool('vision_enabled') ?? false;
    _visionApiUrl = StorageService.getString('vision_api_url') ?? '';
    _visionApiKey = StorageService.getString('vision_api_key') ?? '';
    _visionModel =
        StorageService.getString('vision_model') ?? 'gpt-4-vision-preview';

    // 全局提示词
    _basePrompt = StorageService.getString('base_prompt') ?? _defaultBasePrompt;
    _groupPrompt =
        StorageService.getString('group_prompt') ?? _defaultGroupPrompt;
    _memoryPrompt =
        StorageService.getString('memory_prompt') ?? _defaultMemoryPrompt;

    // 显示设置
    _coverImageUrl = StorageService.getString('cover_image_url') ?? '';
    _chatBackgroundUrl = StorageService.getString('chat_background_url') ?? '';

    // 后端服务器
    _backendUrl =
        StorageService.getString('backend_url') ?? 'http://localhost:8000';
    _backendAuthToken =
      StorageService.getString('backend_auth_token') ??
      SecureBackendClient.defaultAuthToken;
    _backendEncryptionSecret =
      StorageService.getString('backend_encryption_secret') ??
      SecureBackendClient.defaultEncryptionSecret;

    SecureBackendClient.configureSecurity(
      authToken: _backendAuthToken,
      encryptionSecret: _backendEncryptionSecret,
    );

    // 消息等待时间
    _messageWaitSeconds = StorageService.getInt('message_wait_seconds') ?? 0;

    // 后台运行
    _backgroundRuntimeEnabled =
        StorageService.getBool('background_runtime_enabled') ?? true;
    _backgroundPollIntervalSeconds =
      StorageService.getInt('background_poll_interval_seconds') ?? 45;
  }

  // ========== 更新方法 ==========

  /// 更新用户信息
  Future<void> updateUserProfile({
    String? nickname,
    String? avatarUrl,
    String? avatarHash,
  }) async {
    if (nickname != null) {
      _userNickname = nickname;
      await StorageService.setString('user_nickname', nickname);
    }
    if (avatarUrl != null) {
      _userAvatarUrl = avatarUrl;
      await StorageService.setString('user_avatar_url', avatarUrl);
    }
    if (avatarHash != null) {
      _userAvatarHash = avatarHash;
      await StorageService.setString('user_avatar_hash', avatarHash);
    }
    notifyListeners();
  }

  /// 更新显示设置
  Future<void> updateDisplaySettings({
    String? coverImageUrl,
    String? chatBackgroundUrl,
  }) async {
    if (coverImageUrl != null) {
      _coverImageUrl = coverImageUrl;
      await StorageService.setString('cover_image_url', coverImageUrl);
    }
    if (chatBackgroundUrl != null) {
      _chatBackgroundUrl = chatBackgroundUrl;
      await StorageService.setString('chat_background_url', chatBackgroundUrl);
    }
    notifyListeners();
  }

  /// 更新消息等待时间
  Future<void> updateMessageWaitSeconds(int seconds) async {
    _messageWaitSeconds = seconds;
    await StorageService.setInt('message_wait_seconds', seconds);
    notifyListeners();
  }

  /// 更新后台运行开关
  Future<void> updateBackgroundRuntimeEnabled(bool enabled) async {
    _backgroundRuntimeEnabled = enabled;
    await StorageService.setBool('background_runtime_enabled', enabled);
    notifyListeners();
  }

  /// 更新后台轮询间隔（秒）
  Future<void> updateBackgroundPollIntervalSeconds(int seconds) async {
    final normalized = seconds.clamp(15, 120);
    _backgroundPollIntervalSeconds = normalized;
    await StorageService.setInt('background_poll_interval_seconds', normalized);
    notifyListeners();
  }

  /// 更新主聊天 API
  Future<void> updateChatApi({
    required String url,
    required String key,
    required String model,
  }) async {
    _chatApiUrl = url;
    _chatApiKey = key;
    _chatModel = model;
    await StorageService.setString('chat_api_url', url);
    await StorageService.setString('chat_api_key', key);
    await StorageService.setString('chat_model', model);
    notifyListeners();
  }

  /// 更新意图识别 API
  Future<void> updateIntentApi({
    required bool enabled,
    required String url,
    required String key,
    required String model,
  }) async {
    _intentEnabled = enabled;
    _intentApiUrl = url;
    _intentApiKey = key;
    _intentModel = model;
    await StorageService.setBool('intent_enabled', enabled);
    await StorageService.setString('intent_api_url', url);
    await StorageService.setString('intent_api_key', key);
    await StorageService.setString('intent_model', model);

    // 实时更新 IntentService 配置
    IntentService.configure(
      apiUrl: url,
      apiKey: key,
      model: model,
      useAi: enabled,
    );

    notifyListeners();
  }

  /// 更新图像识别 API
  Future<void> updateVisionApi({
    required bool enabled,
    required String url,
    required String key,
    required String model,
  }) async {
    _visionEnabled = enabled;
    _visionApiUrl = url;
    _visionApiKey = key;
    _visionModel = model;
    await StorageService.setBool('vision_enabled', enabled);
    await StorageService.setString('vision_api_url', url);
    await StorageService.setString('vision_api_key', key);
    await StorageService.setString('vision_model', model);
    notifyListeners();
  }

  /// 设置免打扰时间段
  Future<void> setQuietHours(int startHour, int endHour) async {
    await StorageService.setInt('quiet_start_hour', startHour);
    await StorageService.setInt('quiet_end_hour', endHour);
    debugPrint(
      'SettingsService: Quiet hours set to $startHour:00 - $endHour:00',
    );
    notifyListeners();
  }

  /// 获取免打扰开始时间
  int get quietStartHour => StorageService.getInt('quiet_start_hour') ?? 23;

  /// 获取免打扰结束时间
  int get quietEndHour => StorageService.getInt('quiet_end_hour') ?? 7;

  /// 检查当前是否在免打扰时间段内
  bool get isInQuietHours {
    final now = DateTime.now().hour;
    final start = quietStartHour;
    final end = quietEndHour;

    if (start <= end) {
      return now >= start && now < end;
    } else {
      // 跨午夜情况（如 23:00 - 07:00）
      return now >= start || now < end;
    }
  }

  /// 更新全局提示词
  Future<void> updatePrompts({
    String? basePrompt,
    String? groupPrompt,
    String? memoryPrompt,
  }) async {
    if (basePrompt != null) {
      _basePrompt = basePrompt;
      await StorageService.setString('base_prompt', basePrompt);
    }
    if (groupPrompt != null) {
      _groupPrompt = groupPrompt;
      await StorageService.setString('group_prompt', groupPrompt);
    }
    if (memoryPrompt != null) {
      _memoryPrompt = memoryPrompt;
      await StorageService.setString('memory_prompt', memoryPrompt);
    }
    notifyListeners();
  }

  /// 构建完整的系统提示词
  String buildSystemPrompt({required String rolePrompt, bool isGroup = false}) {
    final buffer = StringBuffer();

    // 基础角色扮演提示词
    if (_basePrompt.isNotEmpty) {
      buffer.writeln(_basePrompt);
      buffer.writeln();
    }

    // 角色特定提示词
    if (rolePrompt.isNotEmpty) {
      buffer.writeln(rolePrompt);
      buffer.writeln();
    }

    // 群聊提示词
    if (isGroup && _groupPrompt.isNotEmpty) {
      buffer.writeln(_groupPrompt);
    }

    // 注入当前日期时间
    final now = DateTime.now();
    const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    final weekday = weekdays[now.weekday - 1];
    buffer.writeln();
    buffer.writeln('[当前时间信息]');
    buffer.writeln(
      '当前日期：${now.year}年${now.month.toString().padLeft(2, '0')}月${now.day.toString().padLeft(2, '0')}日 $weekday',
    );
    buffer.writeln(
      '当前时间：${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    );

    return buffer.toString().trim();
  }

  /// 获取记忆总结提示词
  String getMemoryPrompt() {
    return _memoryPrompt.isNotEmpty ? _memoryPrompt : _defaultMemoryPrompt;
  }

  // ========== 默认提示词 ==========

  static const String _defaultBasePrompt = '''
##分割发送使用指南
带入你扮演的角色，在微信上与用户聊天，在你输出的消息中使用'\$'作为消息发送的分行按钮，这个规则不与其他符号冲突（特别强调)
## 表情标签符号使用指南
根据对话场景，当认为目前的心情适合使用表情后缀增强表达时：
- [happy] 表示快乐/开心
- [sad] 表示悲伤/难过 
- [angry] 表示生气/愤怒
- [love]表示爱/喜欢
- [confused]表示困惑/疑问
- [suprised]表示震惊/惊讶
- [tired]表示累/疲惫
*！！重要！！*：必须严格按照上述的表情后缀分类发送，绝对不可以发送别的表情后缀，表情后缀必须严格按照"[]"来，不可以单独发送"[]"，也不可以在"[]"里面放入文字和其他符号，只能根据我给的规则发送！！！！
*注意*  一段回复不应该包含两种表情后缀符号!
限制表情后缀的频率，每四轮对话才可以加入一次表情后缀！！！

## 不要体现出ai的特征
## 不应该使用规定以外的其他称呼
## 单次回复的长度应当是日常程度的回复，不应当过长。
## 除非我问你动作，否则绝对不允许使用括号表现动作与心理。
## 模型的输出绝对不应该带时间。
## 不应该回复过长的对话，就像正常的微信聊天一样
## 重要：当用户问你星期时，不要直接回答，检索当前时间，然后推断出星期之后再回答给用户。
''';

  static const String _defaultGroupPrompt = '''
这是一个群聊环境，可能有多个参与者。
请注意区分不同的发言者，并适当回应。
''';

  static const String _defaultMemoryPrompt = '''
你现在将作为一个核心记忆分析模块，请分析列表中的对话和现有核心记忆，提炼极简核心记忆摘要。

要求：
1. 严格控制字数在50-100字内
2. 仅保留对未来对话至关重要的信息
3. 按优先级提取：用户个人信息 > 用户偏好/喜好 > 重要约定 > 特殊事件 > 常去地点
4. 使用第一人称视角撰写，仿佛是你自己在记录对话记忆
5. 使用极简句式，省略不必要的修饰词，禁止使用颜文字和括号描述动作
6. 不保留日期、时间等临时性信息，除非是周期性的重要约定
7. 如果没有关键新信息，则保持现有核心记忆不变
8. 信息应当是从你的角度了解到的用户信息
9. 格式为简洁的要点，可用分号分隔不同信息
10. 如果约定的时间已经过去，或者用户改变了约定，则更改相关的约定记忆

仅返回最终核心记忆内容，不要包含任何解释。
''';

  // ========== 后端同步 ==========

  /// 更新后端服务器地址
  Future<void> updateBackendUrl(String url) async {
    _backendUrl = url;
    await StorageService.setString('backend_url', url);
    notifyListeners();
    debugPrint('SettingsService: Backend URL updated to $url');
  }

  /// 更新后端鉴权与传输加密配置
  /// 仅更新本地客户端请求参数，不会同步覆盖服务器端配置
  Future<void> updateBackendSecurity({
    required String authToken,
    required String encryptionSecret,
  }) async {
    _backendAuthToken = authToken;
    _backendEncryptionSecret = encryptionSecret;

    await StorageService.setString('backend_auth_token', authToken);
    await StorageService.setString(
      'backend_encryption_secret',
      encryptionSecret,
    );

    SecureBackendClient.configureSecurity(
      authToken: authToken,
      encryptionSecret: encryptionSecret,
    );

    notifyListeners();
    debugPrint('SettingsService: Local backend security config updated');
  }

  /// 同步 API 设置到后端
  Future<bool> syncApiSettingsToBackend() async {
    try {
      final response = await SecureBackendClient.put(
        '$_backendUrl/api/settings',
        {
          'ai_api_url': _chatApiUrl,
          'ai_api_key': _chatApiKey,
          'ai_model': _chatModel,
          'intent_enabled': _intentEnabled,
          'intent_api_url': _intentApiUrl,
          'intent_api_key': _intentApiKey,
          'intent_model': _intentModel,
        },
      );
      if (response.statusCode == 200) {
        debugPrint('SettingsService: API settings synced to backend');
        return true;
      }
    } catch (e) {
      debugPrint('SettingsService: Backend sync failed: $e');
    }
    return false;
  }

  /// 从后端拉取并应用全量设置（用于新安装客户端冷启动同步）
  Future<bool> syncAllSettingsFromBackend() async {
    try {
      final response = await SecureBackendClient.get(
        '$_backendUrl/api/settings?include_secrets=true',
      );

      if (!response.isSuccess || response.data is! Map<String, dynamic>) {
        return false;
      }

      final payload = response.data as Map<String, dynamic>;
      final settings = payload['settings'];
      if (settings is! Map) {
        return false;
      }

      final server = Map<String, dynamic>.from(settings);

      final chatUrl = (server['ai_api_url']?.toString() ?? '').trim();
      final chatKey = (server['ai_api_key']?.toString() ?? '').trim();
      final chatModel =
          (server['ai_model']?.toString() ?? _chatModel).trim().isEmpty
          ? _chatModel
          : (server['ai_model']?.toString() ?? _chatModel).trim();

      final intentEnabled = server['intent_enabled'] == true;
      final intentUrl = (server['intent_api_url']?.toString() ?? '').trim();
      final intentKey = (server['intent_api_key']?.toString() ?? '').trim();
      final intentModel =
          (server['intent_model']?.toString() ?? _intentModel).trim().isEmpty
          ? _intentModel
          : (server['intent_model']?.toString() ?? _intentModel).trim();

      await updateChatApi(url: chatUrl, key: chatKey, model: chatModel);
      await updateIntentApi(
        enabled: intentEnabled,
        url: intentUrl,
        key: intentKey,
        model: intentModel,
      );

      debugPrint('SettingsService: Full settings synced from backend');
      return true;
    } catch (e) {
      debugPrint('SettingsService: Sync all settings from backend failed: $e');
      return false;
    }
  }
}
