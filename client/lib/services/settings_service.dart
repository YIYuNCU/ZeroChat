import 'package:flutter/foundation.dart';
import 'storage_service.dart';
import 'secure_storage_service.dart';
import 'intent_service.dart';
import 'secure_backend_client.dart';
import 'secure_websocket_client.dart';
import '../models/ai_model_profile.dart';
import '../models/provider_quiet_rule.dart';
import '../models/summary_config.dart';

/// 全局设置服务。
class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  int _normalizeTimeout(int? value) => (value ?? 60).clamp(1, 3600);

  static SettingsService get instance => _instance;

  String _normalizeFilePath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    // 处理完整 URL 中包含 /api/avatars/ 的情况（旧版本遗留）
    if (trimmed.contains('/api/avatars/')) {
      return trimmed.replaceAll('/api/avatars/', '/files/avatars/');
    }
    return trimmed;
  }

  // ========== 用户信息 ==========
  String _userNickname = 'ZeroChat';
  String _userAvatarUrl = '';
  String _userAvatarHash = '';

  // ========== 显示设置 ==========
  String _coverImageUrl = '';
  String _chatBackgroundUrl = '';

  // ========== 后端服务器 ==========
  String _backendUrl = 'http://localhost:8000';
  String _backendAuthToken = '';
  String _backendEncryptionSecret = '';

  // ========== API 配置 ==========

  // 主聊天 API
  String _chatApiUrl = '';
  String _chatApiKey = '';
  String _chatModel = 'gpt-3.5-turbo';
  String _chatApiFormat = 'auto';
  int _chatTimeoutSeconds = 60;
  String _chatReasoningEffort = '';
  bool _thinkingEnabled = true;
  int? _thinkingBudget;
  Map<String, dynamic> _modelThinkingSettings = {};
  bool _chatStream = false;
  List<ModelApiProfile> _modelProfiles = [];
  Map<String, String> _roleModelProfileSelections = {};

  // 供应商+模型级安静规则（以服务端 settings.json `quiet_rules` 为准）
  List<ProviderQuietRule> _providerQuietRules = [];

  // 记忆总结（事件总结 / 核心记忆总结）不再绑定角色，各自独立配置
  SummaryApiConfig _contextSummaryConfig = SummaryApiConfig();
  SummaryApiConfig _coreMemorySummaryConfig = SummaryApiConfig();

  // 可配置系统提示词：全局默认覆盖，按档案微调由 model profile 携带
  Map<String, Map<String, String>> _promptOverrides = {};
  Map<String, Map<String, Map<String, String>>> _remoteModelPromptOverrides =
      {};
  Map<String, ConfigurablePrompt> _promptRegistry = {};

  // 意图识别 API
  bool _intentEnabled = false;
  String _intentApiUrl = '';
  String _intentApiKey = '';
  String _intentModel = 'gpt-3.5-turbo';
  String _intentApiFormat = 'auto';

  // 图像识别 API
  bool _visionEnabled = false;
  String _visionApiUrl = '';
  String _visionApiKey = '';
  String _visionModel = 'gpt-4-vision-preview';
  String _visionMode = 'standalone';
  String _visionApiFormat = 'auto';

  // 向量记忆 API (embedding)
  bool _embeddingEnabled = false;
  String _embeddingApiUrl = '';
  String _embeddingApiKey = '';
  String _embeddingModel = 'text-embedding-3-small';

  // ========== 消息等待时间 ==========
  int _messageWaitSeconds = 0; // 0 表示禁用

  // ========== 后台运行 ==========
  bool _backgroundRuntimeEnabled = true;
  int _backgroundPollIntervalSeconds = 120;
  int _backgroundWatchdogIntervalSeconds = 30;

  // ========== WebSocket 心跳间隔 ==========
  // 前台较短以保证实时性，后台较长以省电（服务端无应用级空闲超时）。
  int _foregroundHeartbeatSeconds = 25;
  int _backgroundHeartbeatSeconds = 60;

  // ========== Getters ==========

  String get userNickname => _userNickname;
  String get userAvatarUrl => _userAvatarUrl;
  String get userAvatarHash => _userAvatarHash;

  String get chatApiUrl => _chatApiUrl;
  String get chatApiKey => _chatApiKey;
  String get chatModel => _chatModel;
  String get chatApiFormat => _chatApiFormat;
  int get chatTimeoutSeconds => _chatTimeoutSeconds;
  String get chatReasoningEffort => _chatReasoningEffort;
  bool get thinkingEnabled => _thinkingEnabled;
  int? get thinkingBudget => _thinkingBudget;
  Map<String, dynamic> thinkingSettingsFor(String kind) =>
      Map<String, dynamic>.from(_modelThinkingSettings[kind] as Map? ?? {});

  Future<void> updateModelThinkingSettings(
    String kind, {
    required bool enabled,
    required String effort,
    int? budget,
  }) async {
    _modelThinkingSettings[kind] = {
      'thinking_enabled': enabled,
      'reasoning_effort': effort,
      'thinking_budget': budget,
    };
    await StorageService.setJson(
      'model_thinking_settings',
      _modelThinkingSettings,
    );
    notifyListeners();
  }

  Future<void> _restoreThinkingSettings(Map<String, dynamic> server) async {
    _thinkingEnabled = server['thinking_enabled'] as bool? ?? _thinkingEnabled;
    _thinkingBudget =
        normalizeThinkingBudget(server['ai_thinking_budget']) ??
        normalizeThinkingBudget(server['ai_reasoning_effort']);
    _modelThinkingSettings = Map<String, dynamic>.from(
      server['model_thinking_settings'] as Map? ?? {},
    );
    await StorageService.setBool('thinking_enabled', _thinkingEnabled);
    await StorageService.setInt('ai_thinking_budget', _thinkingBudget ?? 0);
    await StorageService.setJson(
      'model_thinking_settings',
      _modelThinkingSettings,
    );
  }

  /// 从服务端设置恢复两个记忆总结配置与全局提示词覆盖。
  Future<void> _restoreSummaryAndPromptSettings(
    Map<String, dynamic> server, {
    required bool includeSecrets,
  }) async {
    await _restoreSummaryConfig(
      SummaryFeature.context,
      server['context_summary_config'],
      includeSecrets: includeSecrets,
    );
    await _restoreSummaryConfig(
      SummaryFeature.coreMemory,
      server['core_memory_summary_config'],
      includeSecrets: includeSecrets,
    );

    final rawOverrides = server['prompt_overrides'];
    if (rawOverrides is Map) {
      await updatePromptOverrides(normalizePromptOverrides(rawOverrides));
    }
    final rawModelOverrides = server['model_prompt_overrides'];
    if (rawModelOverrides is Map) {
      _remoteModelPromptOverrides = _normalizeModelPromptOverrides(
        rawModelOverrides,
      );
      await StorageService.setJson(
        'remote_model_prompt_overrides',
        _remoteModelPromptOverrides,
      );
    }
  }

  Future<void> _restoreSummaryConfig(
    SummaryFeature feature,
    Object? raw, {
    required bool includeSecrets,
  }) async {
    if (raw is! Map) return;
    SummaryApiConfig stored = SummaryApiConfig.fromJson(
      Map<String, dynamic>.from(raw),
    );
    final existing = summaryConfigFor(feature);
    // 档案绑定只存在于本机：服务端存的是上一次同步派生出的地址/模型，
    // 只要绑定的档案还在就继续沿用（并重新派生一次，跟上档案的最新改动）。
    stored.profileId = _boundProfile(existing.profileId) == null
        ? null
        : existing.profileId;
    if (!includeSecrets && stored.apiKeyMasked.isNotEmpty) {
      // 公开同步只返回掩码，保留本地已保存的密钥。
      stored.apiKey = existing.apiKey;
    }
    if (stored.apiKey.isNotEmpty) {
      stored.apiKeyMasked = '';
    }
    stored = applyBoundProfile(stored);
    await updateSummaryConfig(feature, stored);
  }

  bool get chatStream => _chatStream;
  List<AiModelProfile> get modelProfiles => List.unmodifiable(
    _modelProfiles.where(
      (profile) => profile.supports(ModelProfileCapability.chat),
    ),
  );
  List<ModelApiProfile> modelProfilesFor(ModelProfileCapability capability) =>
      List.unmodifiable(
        _modelProfiles.where((profile) => profile.supports(capability)),
      );
  List<ProviderQuietRule> get providerQuietRules =>
      List.unmodifiable(_providerQuietRules);

  SummaryApiConfig get contextSummaryConfig => _contextSummaryConfig;

  SummaryApiConfig get coreMemorySummaryConfig => _coreMemorySummaryConfig;

  SummaryApiConfig summaryConfigFor(SummaryFeature feature) =>
      feature == SummaryFeature.context
      ? _contextSummaryConfig
      : _coreMemorySummaryConfig;

  Map<String, Map<String, String>> get promptOverrides =>
      Map.unmodifiable(_promptOverrides);

  Map<String, ConfigurablePrompt> get promptRegistry =>
      Map.unmodifiable(_promptRegistry);

  /// 按服务端 key（`api_url|model`，均为小写）汇总各模型档案的提示词微调。
  Map<String, Map<String, Map<String, String>>> modelPromptOverridesForSync() {
    final result = _copyModelPromptOverrides(_remoteModelPromptOverrides);
    for (final profile in _modelProfiles) {
      final key = modelPromptTargetKey(profile.apiUrl, profile.model);
      if (key.isEmpty) continue;
      // A local profile is authoritative for its own provider/model target,
      // including an empty override map used to clear an old customization.
      result.remove(key);
      if (profile.promptOverrides.isNotEmpty) {
        result[key] = _copyPromptOverrides(profile.promptOverrides);
      }
    }
    return result;
  }

  Future<void> updateContextSummaryConfig(SummaryApiConfig config) =>
      updateSummaryConfig(SummaryFeature.context, config);

  Future<void> updateCoreMemorySummaryConfig(SummaryApiConfig config) =>
      updateSummaryConfig(SummaryFeature.coreMemory, config);

  Future<void> updateSummaryConfig(
    SummaryFeature feature,
    SummaryApiConfig config,
  ) async {
    config = applyBoundProfile(config.copy());
    await SecureStorageService.setString(
      _summarySecretKey(feature),
      config.apiKey,
      requireSuccess: true,
    );
    await StorageService.setJson(
      'summary_config_${feature.storageValue}',
      config.toLocalJson(),
    );
    if (feature == SummaryFeature.context) {
      _contextSummaryConfig = config;
    } else {
      _coreMemorySummaryConfig = config;
    }
    notifyListeners();
  }

  /// 绑定的模型档案；档案被删除时返回 null，此时沿用配置里手填的 API 参数。
  ModelApiProfile? _boundProfile(String? profileId) {
    final id = profileId?.trim() ?? '';
    if (id.isEmpty) return null;
    for (final profile in _modelProfiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// 把绑定档案的 API 参数写入配置；未绑定或档案已被删除时原样返回。
  SummaryApiConfig applyBoundProfile(SummaryApiConfig config) {
    final bound = _boundProfile(config.profileId);
    if (bound == null) return config;
    config
      ..apiUrl = bound.apiUrl
      ..apiKey = bound.apiKey
      ..model = bound.model
      ..apiFormat = bound.apiFormat
      ..apiKeyMasked = ''
      ..timeoutSeconds = bound.timeoutSeconds ?? _chatTimeoutSeconds
      ..reasoningEffort = bound.reasoningEffort ?? ''
      ..thinkingEnabled = bound.thinkingEnabled
      ..thinkingBudget = bound.thinkingBudget;
    return config;
  }

  /// 总结配置的服务端负载：绑定档案时由档案派生 API 参数，保存即生效，
  /// 之后修改档案也会在下一次同步时自动跟上。
  Map<String, dynamic> summaryConfigPayload(SummaryApiConfig config) {
    final resolved = applyBoundProfile(config.copy());
    final payload = resolved.toJson();
    // Public sync intentionally omits secrets. Keep a masked remote key intact
    // until the user supplies a replacement or explicitly resets this config.
    if (resolved.apiKey.isEmpty && resolved.apiKeyMasked.isNotEmpty) {
      payload.remove('api_key');
    }
    return payload;
  }

  Future<void> updatePromptOverrides(
    Map<String, Map<String, String>> overrides,
  ) async {
    _promptOverrides = normalizePromptOverrides(overrides);
    await StorageService.setJson('prompt_overrides', _promptOverrides);
    notifyListeners();
  }

  /// 拉取服务端提示词注册表（内置默认文本 + 注册表元数据），结果缓存在内存中。
  Future<Map<String, ConfigurablePrompt>> loadPromptRegistry({
    bool force = false,
  }) async {
    if (!force && _promptRegistry.isNotEmpty) return _promptRegistry;
    try {
      final payload = await SecureWebSocketClient.instance.request(
        'settings_prompts_get',
        const <String, dynamic>{},
      );
      final rawModelOverrides = payload['model_overrides'];
      if (rawModelOverrides is Map) {
        _remoteModelPromptOverrides = _normalizeModelPromptOverrides(
          rawModelOverrides,
        );
        await StorageService.setJson(
          'remote_model_prompt_overrides',
          _remoteModelPromptOverrides,
        );
      }
      final raw = payload['prompts'];
      if (raw is! Map) return _promptRegistry;
      _promptRegistry = {
        for (final entry in raw.entries)
          '${entry.key}': ConfigurablePrompt.fromJson({
            ...Map<String, dynamic>.from(entry.value as Map),
            'id': '${entry.key}',
          }),
      };
      notifyListeners();
    } catch (e) {
      debugPrint('SettingsService: load prompt registry failed: $e');
    }
    return _promptRegistry;
  }

  /// Returns the local model profile selected for a role, if one was saved.
  /// Profile associations are device-local because profile API keys are local too.
  String? selectedModelProfileIdForRole(String roleId) =>
      _roleModelProfileSelections[roleId];

  Iterable<String> roleIdsUsingModelProfile(String profileId) =>
      _roleModelProfileSelections.entries
          .where((entry) => entry.value == profileId)
          .map((entry) => entry.key);

  bool get intentEnabled => _intentEnabled;
  String get intentApiUrl => _intentApiUrl;
  String get intentApiKey => _intentApiKey;
  String get intentModel => _intentModel;
  String get intentApiFormat => _intentApiFormat;

  bool get visionEnabled => _visionEnabled;
  String get visionApiUrl => _visionApiUrl;
  String get visionApiKey => _visionApiKey;
  String get visionModel => _visionModel;
  String get visionMode => _visionMode;
  String get visionApiFormat => _visionApiFormat;

  bool get embeddingEnabled => _embeddingEnabled;
  String get embeddingApiUrl => _embeddingApiUrl;
  String get embeddingApiKey => _embeddingApiKey;
  String get embeddingModel => _embeddingModel;

  String get coverImageUrl => _coverImageUrl;
  String get chatBackgroundUrl => _chatBackgroundUrl;

  String get backendUrl => _backendUrl;

  /// 拼接完整的用户头像 URL
  String get userAvatarFullUrl {
    if (_userAvatarUrl.isEmpty) return '';
    if (_userAvatarUrl.startsWith('http')) return _userAvatarUrl;
    // 确保 backendUrl 不以 / 结尾，userAvatarUrl 以 / 开头
    final base = _backendUrl.endsWith('/')
        ? _backendUrl.substring(0, _backendUrl.length - 1)
        : _backendUrl;
    return '$base$_userAvatarUrl';
  }

  String get backendAuthToken => _backendAuthToken;
  String get backendEncryptionSecret => _backendEncryptionSecret;

  int get messageWaitSeconds => _messageWaitSeconds;
  bool get backgroundRuntimeEnabled => _backgroundRuntimeEnabled;
  int get backgroundPollIntervalSeconds => _backgroundPollIntervalSeconds;
  int get backgroundWatchdogIntervalSeconds =>
      _backgroundWatchdogIntervalSeconds;
  int get foregroundHeartbeatSeconds => _foregroundHeartbeatSeconds;
  int get backgroundHeartbeatSeconds => _backgroundHeartbeatSeconds;

  /// 初始化
  static Future<void> init() async {
    await _instance._loadSettings();
    debugPrint('SettingsService initialized');
  }

  /// 加载设置
  Future<void> _loadSettings() async {
    // 用户信息
    _userNickname = StorageService.getString('user_nickname') ?? 'ZeroChat';
    _userAvatarUrl = _normalizeFilePath(
      StorageService.getString('user_avatar_url') ?? '',
    );
    _userAvatarHash = StorageService.getString('user_avatar_hash') ?? '';

    // 主聊天 API（api_key 走安全存储）
    _chatApiUrl = StorageService.getString('chat_api_url') ?? '';
    _chatApiKey = SecureStorageService.getString('chat_api_key');
    _chatModel = StorageService.getString('chat_model') ?? 'gpt-3.5-turbo';
    _chatApiFormat = normalizeApiFormat(
      StorageService.getString('chat_api_format'),
    );
    _chatTimeoutSeconds = _normalizeTimeout(
      StorageService.getInt('chat_timeout_seconds'),
    );
    _chatReasoningEffort =
        StorageService.getString('chat_reasoning_effort') ?? '';
    _thinkingEnabled = StorageService.getBool('thinking_enabled') ?? true;
    _thinkingBudget =
        normalizeThinkingBudget(StorageService.getInt('ai_thinking_budget')) ??
        normalizeThinkingBudget(_chatReasoningEffort);
    if (int.tryParse(_chatReasoningEffort) != null) _chatReasoningEffort = '';
    _modelThinkingSettings =
        StorageService.getJson('model_thinking_settings') ?? {};
    _chatStream = StorageService.getBool('chat_stream') ?? false;
    await _loadModelProfiles();
    _loadRoleModelProfileSelections();
    _loadProviderQuietRules();
    await _loadSummaryConfigs();
    _promptOverrides = normalizePromptOverrides(
      StorageService.getJson('prompt_overrides'),
    );
    _remoteModelPromptOverrides = _normalizeModelPromptOverrides(
      StorageService.getJson('remote_model_prompt_overrides'),
    );

    // 意图识别 API
    _intentEnabled = StorageService.getBool('intent_enabled') ?? false;
    _intentApiUrl = StorageService.getString('intent_api_url') ?? '';
    _intentApiKey = SecureStorageService.getString('intent_api_key');
    _intentModel = StorageService.getString('intent_model') ?? 'gpt-3.5-turbo';
    _intentApiFormat = normalizeApiFormat(
      StorageService.getString('intent_api_format'),
    );

    // 图像识别 API
    _visionEnabled = StorageService.getBool('vision_enabled') ?? false;
    _visionApiUrl = StorageService.getString('vision_api_url') ?? '';
    _visionApiKey = SecureStorageService.getString('vision_api_key');
    _visionModel =
        StorageService.getString('vision_model') ?? 'gpt-4-vision-preview';
    _visionMode = StorageService.getString('vision_mode') ?? 'standalone';
    _visionApiFormat = normalizeApiFormat(
      StorageService.getString('vision_api_format'),
    );

    // 向量记忆 API
    _embeddingEnabled = StorageService.getBool('embedding_enabled') ?? false;
    _embeddingApiUrl = StorageService.getString('embedding_api_url') ?? '';
    _embeddingApiKey = SecureStorageService.getString('embedding_api_key');
    _embeddingModel =
        StorageService.getString('embedding_model') ?? 'text-embedding-3-small';

    // 显示设置
    _coverImageUrl = StorageService.getString('cover_image_url') ?? '';
    _chatBackgroundUrl = StorageService.getString('chat_background_url') ?? '';

    // 后端服务器（token/secret 走安全存储；未配置时保持空，不再回退到内置默认值）
    _backendUrl =
        StorageService.getString('backend_url') ?? 'http://localhost:8000';
    _backendAuthToken = SecureStorageService.getString('backend_auth_token');
    _backendEncryptionSecret = SecureStorageService.getString(
      'backend_encryption_secret',
    );

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
        StorageService.getInt('background_poll_interval_seconds') ?? 120;
    _backgroundWatchdogIntervalSeconds =
        StorageService.getInt('background_watchdog_interval_seconds') ?? 30;

    // WebSocket 心跳间隔
    _foregroundHeartbeatSeconds =
        (StorageService.getInt('foreground_heartbeat_seconds') ?? 25).clamp(
          15,
          60,
        );
    _backgroundHeartbeatSeconds =
        (StorageService.getInt('background_heartbeat_seconds') ?? 60).clamp(
          30,
          180,
        );
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
      final normalized = _normalizeFilePath(avatarUrl);
      _userAvatarUrl = normalized;
      await StorageService.setString('user_avatar_url', normalized);
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

  /// 更新后台保活自检间隔（秒）
  Future<void> updateBackgroundWatchdogIntervalSeconds(int seconds) async {
    final normalized = seconds.clamp(10, 120);
    _backgroundWatchdogIntervalSeconds = normalized;
    await StorageService.setInt(
      'background_watchdog_interval_seconds',
      normalized,
    );
    notifyListeners();
  }

  /// 更新前台 WebSocket 心跳间隔（秒）
  Future<void> updateForegroundHeartbeatSeconds(int seconds) async {
    final normalized = seconds.clamp(15, 60);
    _foregroundHeartbeatSeconds = normalized;
    await StorageService.setInt('foreground_heartbeat_seconds', normalized);
    notifyListeners();
  }

  /// 更新后台 WebSocket 心跳间隔（秒）
  Future<void> updateBackgroundHeartbeatSeconds(int seconds) async {
    final normalized = seconds.clamp(30, 180);
    _backgroundHeartbeatSeconds = normalized;
    await StorageService.setInt('background_heartbeat_seconds', normalized);
    notifyListeners();
  }

  /// 更新主聊天 API
  Future<void> updateChatApi({
    required String url,
    required String key,
    required String model,
    String? apiFormat,
    int? timeoutSeconds,
    String? reasoningEffort,
    bool? thinkingEnabled,
    int? thinkingBudget,
    bool clearThinkingBudget = false,
    bool? stream,
  }) async {
    _chatApiUrl = url;
    _chatApiKey = key;
    _chatModel = model;
    if (apiFormat != null) _chatApiFormat = normalizeApiFormat(apiFormat);
    if (timeoutSeconds != null) {
      _chatTimeoutSeconds = _normalizeTimeout(timeoutSeconds);
    }
    if (reasoningEffort != null) _chatReasoningEffort = reasoningEffort.trim();
    if (thinkingEnabled != null) _thinkingEnabled = thinkingEnabled;
    if (thinkingBudget != null || clearThinkingBudget) {
      _thinkingBudget = normalizeThinkingBudget(thinkingBudget);
    }
    final legacyBudget = normalizeThinkingBudget(_chatReasoningEffort);
    if (legacyBudget != null) {
      _thinkingBudget ??= legacyBudget;
      _chatReasoningEffort = '';
    }
    if (stream != null) _chatStream = stream;
    await StorageService.setString('chat_api_url', url);
    await SecureStorageService.setString('chat_api_key', key);
    await StorageService.setString('chat_model', model);
    await StorageService.setString('chat_api_format', _chatApiFormat);
    await StorageService.setInt('chat_timeout_seconds', _chatTimeoutSeconds);
    await StorageService.setString(
      'chat_reasoning_effort',
      _chatReasoningEffort,
    );
    await StorageService.setBool('thinking_enabled', _thinkingEnabled);
    await StorageService.setBool('chat_stream', _chatStream);
    await StorageService.setInt('ai_thinking_budget', _thinkingBudget ?? 0);
    notifyListeners();
  }

  void _loadProviderQuietRules() {
    final raw = StorageService.getJsonList('provider_quiet_rules') ?? [];
    _providerQuietRules = raw
        .map((json) => ProviderQuietRule.fromJson(json))
        .where((rule) => rule.apiUrl.isNotEmpty && rule.model.isNotEmpty)
        .toList();
  }

  /// 更新供应商+模型级安静规则并本地持久化。
  /// 服务端同步由 syncApiSettingsToBackend 统一推送 `quiet_rules`。
  Future<void> updateProviderQuietRules(List<ProviderQuietRule> rules) async {
    _providerQuietRules = List<ProviderQuietRule>.from(rules);
    await StorageService.setJsonList(
      'provider_quiet_rules',
      _providerQuietRules.map((rule) => rule.toJson()).toList(),
    );
    notifyListeners();
  }

  Future<void> _loadModelProfiles() async {
    const storageKey = 'model_api_profiles_v2';
    final raw = StorageService.getJsonList(storageKey);
    if (raw != null) {
      _modelProfiles = raw
          .map((json) {
            final id = '${json['id'] ?? ''}';
            return ModelApiProfile.fromJson(
              json,
              apiKey: SecureStorageService.getString(
                'model_api_profile_key_$id',
              ),
            );
          })
          .where(
            (profile) =>
                profile.id.isNotEmpty && profile.capabilities.isNotEmpty,
          )
          .toList();
      return;
    }

    final migrated = <ModelApiProfile>[];
    final legacyChat = StorageService.getJsonList('ai_model_profiles') ?? [];
    for (final json in legacyChat) {
      final id = '${json['id'] ?? ''}';
      if (id.isEmpty) continue;
      final profile = ModelApiProfile(
        id: id,
        name: '${json['name'] ?? json['model'] ?? ''}',
        apiUrl: '${json['api_url'] ?? ''}',
        model: '${json['model'] ?? ''}',
        apiKey: SecureStorageService.getString('ai_model_profile_key_$id'),
        apiFormat: normalizeApiFormat(json['api_format']),
        capabilities: const {ModelProfileCapability.chat},
      );
      migrated.add(profile);
    }
    final legacyVision =
        StorageService.getJsonList('vision_model_profiles') ?? [];
    for (final json in legacyVision) {
      final legacy = VisionModelProfile.fromJson(
        json,
        apiKey: SecureStorageService.getString(
          'vision_model_profile_key_${json['id'] ?? ''}',
        ),
      );
      if (legacy.id.isEmpty) continue;
      final id = migrated.any((item) => item.id == legacy.id)
          ? 'vision_${legacy.id}'
          : legacy.id;
      migrated.add(
        ModelApiProfile(
          id: id,
          name: legacy.name,
          apiUrl: legacy.apiUrl,
          model: legacy.model,
          apiKey: legacy.apiKey,
          apiFormat: legacy.apiFormat,
          capabilities: const {ModelProfileCapability.vision},
          visionMode: legacy.mode,
        ),
      );
      await SecureStorageService.setString(
        'model_api_profile_key_$id',
        legacy.apiKey,
      );
    }
    for (final profile in migrated) {
      await SecureStorageService.setString(
        'model_api_profile_key_${profile.id}',
        profile.apiKey,
      );
    }
    _modelProfiles = migrated;
    await _persistModelProfiles();
  }

  void _loadRoleModelProfileSelections() {
    final stored =
        StorageService.getJson('role_model_profile_selections') ??
        const <String, dynamic>{};
    _roleModelProfileSelections = {
      for (final entry in stored.entries)
        if (entry.key.isNotEmpty && entry.value.toString().isNotEmpty)
          entry.key: entry.value.toString(),
    };
  }

  Future<void> setSelectedModelProfileForRole(
    String roleId,
    String? profileId,
  ) async {
    if (profileId == null || profileId.isEmpty) {
      _roleModelProfileSelections.remove(roleId);
    } else {
      _roleModelProfileSelections[roleId] = profileId;
    }
    await StorageService.setJson(
      'role_model_profile_selections',
      _roleModelProfileSelections,
    );
    notifyListeners();
  }

  Future<void> saveModelProfile({
    required String id,
    required String name,
    required String url,
    required String model,
    required String key,
    String apiFormat = 'auto',
  }) async {
    await saveApiProfile(
      ModelApiProfile(
        id: id,
        name: name,
        apiUrl: url,
        model: model,
        apiKey: key,
        apiFormat: apiFormat,
        capabilities: const {ModelProfileCapability.chat},
      ),
    );
  }

  Future<void> saveApiProfile(ModelApiProfile profile) async {
    _modelProfiles = [
      ..._modelProfiles.where((item) => item.id != profile.id),
      profile,
    ];
    await _persistModelProfiles();
    await SecureStorageService.setString(
      'model_api_profile_key_${profile.id}',
      profile.apiKey,
    );
    notifyListeners();
  }

  Future<void> deleteModelProfile(String id) async {
    _modelProfiles = _modelProfiles.where((item) => item.id != id).toList();
    await _persistModelProfiles();
    await SecureStorageService.remove('model_api_profile_key_$id');
    _roleModelProfileSelections.removeWhere((_, profileId) => profileId == id);
    await StorageService.setJson(
      'role_model_profile_selections',
      _roleModelProfileSelections,
    );
    notifyListeners();
  }

  Future<void> _persistModelProfiles() async {
    await StorageService.setJsonList(
      'model_api_profiles_v2',
      _modelProfiles.map((item) => item.toJson()).toList(),
    );
  }

  static String _summarySecretKey(SummaryFeature feature) =>
      'summary_api_key_${feature.storageValue}';

  Future<void> _loadSummaryConfigs() async {
    _contextSummaryConfig = await _readSummaryConfig(SummaryFeature.context);
    _coreMemorySummaryConfig = await _readSummaryConfig(
      SummaryFeature.coreMemory,
    );
  }

  Future<SummaryApiConfig> _readSummaryConfig(SummaryFeature feature) async {
    // 显式声明为 Object? 才能让 `is Map` 完成类型提升（getJson 返回可空 Map）。
    final Object? raw = StorageService.getJson(
      'summary_config_${feature.storageValue}',
    );
    if (raw is Map) {
      final config = SummaryApiConfig.fromJson(Map<String, dynamic>.from(raw));
      final secretKey = _summarySecretKey(feature);
      if (raw.containsKey('api_key')) {
        // Migrate the previous plaintext format only after secure storage succeeds.
        try {
          if (!SecureStorageService.has(secretKey)) {
            await SecureStorageService.setString(
              secretKey,
              config.apiKey,
              requireSuccess: true,
            );
          }
          await StorageService.setJson(
            'summary_config_${feature.storageValue}',
            config.toLocalJson(),
          );
        } catch (_) {
          // Keep the previous value and retry migration on the next startup.
          debugPrint('SettingsService: summary secret migration failed');
          return config;
        }
      }
      config.apiKey = SecureStorageService.getString(secretKey);
      return config;
    }
    return SummaryApiConfig();
  }

  /// 更新意图识别 API
  Future<void> updateIntentApi({
    required bool enabled,
    required String url,
    required String key,
    required String model,
    String? apiFormat,
  }) async {
    _intentEnabled = enabled;
    _intentApiUrl = url;
    _intentApiKey = key;
    _intentModel = model;
    if (apiFormat != null) _intentApiFormat = normalizeApiFormat(apiFormat);
    await StorageService.setBool('intent_enabled', enabled);
    await StorageService.setString('intent_api_url', url);
    await SecureStorageService.setString('intent_api_key', key);
    await StorageService.setString('intent_model', model);
    await StorageService.setString('intent_api_format', _intentApiFormat);

    // 实时更新 IntentService 配置
    IntentService.configure(
      apiUrl: url,
      apiKey: key,
      model: model,
      apiFormat: _intentApiFormat,
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
    String? mode,
    String? apiFormat,
  }) async {
    _visionEnabled = enabled;
    _visionApiUrl = url;
    _visionApiKey = key;
    _visionModel = model;
    if (mode != null && mode.isNotEmpty) {
      _visionMode = mode;
    }
    if (apiFormat != null) _visionApiFormat = normalizeApiFormat(apiFormat);
    await StorageService.setBool('vision_enabled', enabled);
    await StorageService.setString('vision_api_url', url);
    await SecureStorageService.setString('vision_api_key', key);
    await StorageService.setString('vision_model', model);
    await StorageService.setString('vision_mode', _visionMode);
    await StorageService.setString('vision_api_format', _visionApiFormat);
    notifyListeners();
  }

  /// 更新向量记忆 API
  Future<void> updateEmbeddingApi({
    required bool enabled,
    required String url,
    required String key,
    required String model,
  }) async {
    _embeddingEnabled = enabled;
    _embeddingApiUrl = url;
    _embeddingApiKey = key;
    _embeddingModel = model;
    await StorageService.setBool('embedding_enabled', enabled);
    await StorageService.setString('embedding_api_url', url);
    await SecureStorageService.setString('embedding_api_key', key);
    await StorageService.setString('embedding_model', model);
    notifyListeners();
  }

  // ========== 后端同步 ==========

  /// 更新后端服务器地址
  Future<void> updateBackendUrl(String url) async {
    // 去除尾部斜杠，避免拼接路径时出现双斜杠
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    _backendUrl = normalized;
    await StorageService.setString('backend_url', normalized);
    notifyListeners();
    debugPrint('SettingsService: Backend URL updated to $normalized');
  }

  /// 更新后端鉴权与传输加密配置
  /// 仅更新本地客户端请求参数，不会同步覆盖服务器端配置
  Future<void> updateBackendSecurity({
    required String authToken,
    required String encryptionSecret,
  }) async {
    _backendAuthToken = authToken;
    _backendEncryptionSecret = encryptionSecret;

    await SecureStorageService.setString('backend_auth_token', authToken);
    await SecureStorageService.setString(
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
      final response = await SecureWebSocketClient.instance.request(
        'settings_update',
        {
          'updates': {
            'ai_api_url': _chatApiUrl,
            'ai_api_key': _chatApiKey,
            'ai_model': _chatModel,
            'ai_api_format': _chatApiFormat,
            'ai_timeout_seconds': _chatTimeoutSeconds,
            'ai_reasoning_effort': _chatReasoningEffort,
            'thinking_enabled': _thinkingEnabled,
            'ai_thinking_budget': _thinkingBudget ?? 0,
            'model_thinking_settings': _modelThinkingSettings,
            'ai_stream': _chatStream,
            'context_summary_config': summaryConfigPayload(
              _contextSummaryConfig,
            ),
            'core_memory_summary_config': summaryConfigPayload(
              _coreMemorySummaryConfig,
            ),
            'prompt_overrides': _promptOverrides,
            'model_prompt_overrides': modelPromptOverridesForSync(),
            'intent_enabled': _intentEnabled,
            'intent_api_url': _intentApiUrl,
            'intent_api_key': _intentApiKey,
            'intent_model': _intentModel,
            'intent_api_format': _intentApiFormat,
            'vision_enabled': _visionEnabled,
            'vision_api_url': _visionApiUrl,
            'vision_api_key': _visionApiKey,
            'vision_model': _visionModel,
            'vision_mode': _visionMode,
            'vision_api_format': _visionApiFormat,
            'embedding_enabled': _embeddingEnabled,
            'embedding_api_url': _embeddingApiUrl,
            'embedding_api_key': _embeddingApiKey,
            'embedding_model': _embeddingModel,
            'quiet_rules': _providerQuietRules
                .map((rule) => rule.toJson())
                .toList(),
          },
        },
      );
      if (response['success'] == true) {
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
      final response = await SecureWebSocketClient.instance.request(
        'settings_get',
        {'include_secrets': true},
      );

      final payload = response;
      final settings = payload['settings'];
      if (settings is! Map) {
        return false;
      }

      final server = Map<String, dynamic>.from(settings);
      await _restoreThinkingSettings(server);
      await _restoreSummaryAndPromptSettings(server, includeSecrets: true);

      final chatUrl = (server['ai_api_url']?.toString() ?? '').trim();
      final chatKey = (server['ai_api_key']?.toString() ?? '').trim();
      final chatModel =
          (server['ai_model']?.toString() ?? _chatModel).trim().isEmpty
          ? _chatModel
          : (server['ai_model']?.toString() ?? _chatModel).trim();
      final chatApiFormat = normalizeApiFormat(server['ai_api_format']);
      final chatTimeoutSeconds = _normalizeTimeout(
        (server['ai_timeout_seconds'] as num?)?.toInt() ?? _chatTimeoutSeconds,
      );
      final chatReasoningEffort =
          (server['ai_reasoning_effort']?.toString() ?? _chatReasoningEffort)
              .trim();
      final thinkingEnabled = server['thinking_enabled'] is bool
          ? server['thinking_enabled'] as bool
          : _thinkingEnabled;
      final chatStream = server['ai_stream'] is bool
          ? server['ai_stream'] as bool
          : _chatStream;

      final intentEnabled = server['intent_enabled'] == true;
      final intentUrl = (server['intent_api_url']?.toString() ?? '').trim();
      final intentKey = (server['intent_api_key']?.toString() ?? '').trim();
      final intentModel =
          (server['intent_model']?.toString() ?? _intentModel).trim().isEmpty
          ? _intentModel
          : (server['intent_model']?.toString() ?? _intentModel).trim();
      final intentApiFormat = normalizeApiFormat(server['intent_api_format']);

      final visionEnabled = server['vision_enabled'] == true;
      final visionUrl = (server['vision_api_url']?.toString() ?? '').trim();
      final visionKey = (server['vision_api_key']?.toString() ?? '').trim();
      final visionModel =
          (server['vision_model']?.toString() ?? _visionModel).trim().isEmpty
          ? _visionModel
          : (server['vision_model']?.toString() ?? _visionModel).trim();
      final visionModeRaw = (server['vision_mode']?.toString() ?? _visionMode)
          .trim()
          .toLowerCase();
      final visionMode =
          const {'standalone', 'pre_model', 'tool'}.contains(visionModeRaw)
          ? visionModeRaw
          : 'standalone';
      final visionApiFormat = normalizeApiFormat(server['vision_api_format']);

      final embeddingEnabled = server['embedding_enabled'] == true;
      final embeddingUrl = (server['embedding_api_url']?.toString() ?? '')
          .trim();
      final embeddingKey = (server['embedding_api_key']?.toString() ?? '')
          .trim();
      final embeddingModel =
          (server['embedding_model']?.toString() ?? _embeddingModel)
              .trim()
              .isEmpty
          ? _embeddingModel
          : (server['embedding_model']?.toString() ?? _embeddingModel).trim();

      final rawQuietRules = server['quiet_rules'];
      if (rawQuietRules is List) {
        final quietRules = rawQuietRules
            .whereType<Map>()
            .map(
              (item) =>
                  ProviderQuietRule.fromJson(Map<String, dynamic>.from(item)),
            )
            .where((rule) => rule.apiUrl.isNotEmpty && rule.model.isNotEmpty)
            .toList();
        await updateProviderQuietRules(quietRules);
      }

      await updateChatApi(
        url: chatUrl,
        key: chatKey,
        model: chatModel,
        apiFormat: chatApiFormat,
        timeoutSeconds: chatTimeoutSeconds,
        reasoningEffort: chatReasoningEffort,
        thinkingEnabled: thinkingEnabled,
        stream: chatStream,
      );
      await updateIntentApi(
        enabled: intentEnabled,
        url: intentUrl,
        key: intentKey,
        model: intentModel,
        apiFormat: intentApiFormat,
      );
      await updateVisionApi(
        enabled: visionEnabled,
        url: visionUrl,
        key: visionKey,
        model: visionModel,
        mode: visionMode,
        apiFormat: visionApiFormat,
      );
      await updateEmbeddingApi(
        enabled: embeddingEnabled,
        url: embeddingUrl,
        key: embeddingKey,
        model: embeddingModel,
      );

      debugPrint('SettingsService: Full settings synced from backend');
      return true;
    } catch (e) {
      debugPrint('SettingsService: Sync all settings from backend failed: $e');
      return false;
    }
  }

  /// 从后端拉取并应用公开设置（不请求密钥）
  Future<bool> syncPublicSettingsFromBackend() async {
    try {
      final payload = await SecureWebSocketClient.instance.request(
        'settings_get',
        const <String, dynamic>{},
      );
      final settings = payload['settings'];
      if (settings is! Map) {
        return false;
      }

      final server = Map<String, dynamic>.from(settings);
      await _restoreThinkingSettings(server);
      await _restoreSummaryAndPromptSettings(server, includeSecrets: false);

      final chatUrl = (server['ai_api_url']?.toString() ?? '').trim();
      final chatModel =
          (server['ai_model']?.toString() ?? _chatModel).trim().isEmpty
          ? _chatModel
          : (server['ai_model']?.toString() ?? _chatModel).trim();
      final chatApiFormat = normalizeApiFormat(server['ai_api_format']);
      final chatTimeoutSeconds = _normalizeTimeout(
        (server['ai_timeout_seconds'] as num?)?.toInt() ?? _chatTimeoutSeconds,
      );
      final chatReasoningEffort =
          (server['ai_reasoning_effort']?.toString() ?? _chatReasoningEffort)
              .trim();
      final chatStream = server['ai_stream'] is bool
          ? server['ai_stream'] as bool
          : _chatStream;

      final intentEnabled = server['intent_enabled'] == true;
      final intentUrl = (server['intent_api_url']?.toString() ?? '').trim();
      final intentModel =
          (server['intent_model']?.toString() ?? _intentModel).trim().isEmpty
          ? _intentModel
          : (server['intent_model']?.toString() ?? _intentModel).trim();
      final intentApiFormat = normalizeApiFormat(server['intent_api_format']);

      final visionEnabled = server['vision_enabled'] == true;
      final visionUrl = (server['vision_api_url']?.toString() ?? '').trim();
      final visionModel =
          (server['vision_model']?.toString() ?? _visionModel).trim().isEmpty
          ? _visionModel
          : (server['vision_model']?.toString() ?? _visionModel).trim();
      final visionModeRaw = (server['vision_mode']?.toString() ?? _visionMode)
          .trim()
          .toLowerCase();
      final visionMode =
          const {'standalone', 'pre_model', 'tool'}.contains(visionModeRaw)
          ? visionModeRaw
          : 'standalone';
      final visionApiFormat = normalizeApiFormat(server['vision_api_format']);

      final embeddingEnabled = server['embedding_enabled'] == true;
      final embeddingUrl = (server['embedding_api_url']?.toString() ?? '')
          .trim();
      final embeddingModel =
          (server['embedding_model']?.toString() ?? _embeddingModel)
              .trim()
              .isEmpty
          ? _embeddingModel
          : (server['embedding_model']?.toString() ?? _embeddingModel).trim();

      final rawQuietRules = server['quiet_rules'];
      if (rawQuietRules is List) {
        final quietRules = rawQuietRules
            .whereType<Map>()
            .map(
              (item) =>
                  ProviderQuietRule.fromJson(Map<String, dynamic>.from(item)),
            )
            .where((rule) => rule.apiUrl.isNotEmpty && rule.model.isNotEmpty)
            .toList();
        await updateProviderQuietRules(quietRules);
      }

      await updateChatApi(
        url: chatUrl,
        key: _chatApiKey,
        model: chatModel,
        apiFormat: chatApiFormat,
        timeoutSeconds: chatTimeoutSeconds,
        reasoningEffort: chatReasoningEffort,
        stream: chatStream,
      );
      await updateIntentApi(
        enabled: intentEnabled,
        url: intentUrl,
        key: _intentApiKey,
        model: intentModel,
        apiFormat: intentApiFormat,
      );
      await updateVisionApi(
        enabled: visionEnabled,
        url: visionUrl,
        key: _visionApiKey,
        model: visionModel,
        mode: visionMode,
        apiFormat: visionApiFormat,
      );
      await updateEmbeddingApi(
        enabled: embeddingEnabled,
        url: embeddingUrl,
        key: _embeddingApiKey,
        model: embeddingModel,
      );

      debugPrint('SettingsService: Public settings synced from backend');
      return true;
    } catch (e) {
      debugPrint(
        'SettingsService: Sync public settings from backend failed: $e',
      );
      return false;
    }
  }
}

Map<String, Map<String, String>> _copyPromptOverrides(
  Map<String, Map<String, String>> source,
) => {
  for (final entry in source.entries)
    entry.key: Map<String, String>.of(entry.value),
};

Map<String, Map<String, Map<String, String>>> _copyModelPromptOverrides(
  Map<String, Map<String, Map<String, String>>> source,
) => {
  for (final entry in source.entries)
    entry.key: _copyPromptOverrides(entry.value),
};

Map<String, Map<String, Map<String, String>>> _normalizeModelPromptOverrides(
  Object? raw,
) {
  if (raw is! Map) return {};
  final result = <String, Map<String, Map<String, String>>>{};
  for (final entry in raw.entries) {
    final target = entry.key.toString().trim().toLowerCase();
    if (target.isEmpty || entry.value is! Map) continue;
    final overrides = normalizePromptOverrides(entry.value);
    if (overrides.isNotEmpty) result[target] = overrides;
  }
  return result;
}
