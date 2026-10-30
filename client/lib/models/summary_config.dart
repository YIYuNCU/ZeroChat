/// 总结功能（事件总结 / 核心记忆总结 / 聊天回顾总结 / QQ 消息回顾总结）的独立配置与可配置系统提示词模型。
///
/// 这些功能不再挂靠在任何角色上，服务端以 `context_summary_config` /
/// `core_memory_summary_config` / `chat_recall_summary_config` /
/// `onebot_recall_summary_config` 单独存储；提示词来自
/// 服务端提示词注册表，可全局覆盖，聊天类提示词还可按角色覆盖；覆盖直接编辑 md 全文。
library;

/// 目的一致的总结功能标识，与服务端 `summary_config_service` 保持一致。
enum SummaryFeature {
  context('context_summary', '事件总结', '把历史对话压缩成上下文摘要与事件记忆'),
  coreMemory('core_memory_summary', '核心记忆总结', '把长期事实归纳进核心记忆'),
  chatRecall('chat_recall_summary', '聊天回顾总结', 'AI 按指定时间/事件查阅历史聊天时，用此模型总结相关内容'),
  onebotRecall('onebot_recall_summary', 'QQ 消息回顾总结', 'AI 回看当前 QQ 群/私聊最近若干条或某时间段的消息时，用此模型总结相关内容');

  const SummaryFeature(this.storageValue, this.title, this.description);

  final String storageValue;
  final String title;
  final String description;
}

/// 一个总结功能的 API 与提示词配置。空字段表示回退到全局聊天 API。
class SummaryApiConfig {
  bool enabled;
  String apiUrl;
  String apiKey;
  String model;
  String apiFormat;
  double temperature;
  int timeoutSeconds;
  String reasoningEffort;
  bool? thinkingEnabled;
  int? thinkingBudget;
  String systemPrompt;
  String apiKeyMasked;

  /// 绑定的模型档案 id（仅本地保存）。
  ///
  /// 模型档案只存在于本机，服务端不知道档案，所以同步时会把档案的 API 参数
  /// 派生进上面的字段；绑定生效期间手动改地址/模型会解除绑定（见 `_applyProfile`）。
  String? profileId;

  SummaryApiConfig({
    this.enabled = true,
    this.apiUrl = '',
    this.apiKey = '',
    this.model = '',
    this.apiFormat = 'auto',
    this.temperature = 0.1,
    this.timeoutSeconds = 60,
    this.reasoningEffort = '',
    this.thinkingEnabled,
    this.thinkingBudget,
    this.systemPrompt = '',
    this.apiKeyMasked = '',
    this.profileId,
  });

  factory SummaryApiConfig.fromJson(Map<String, dynamic> json) {
    return SummaryApiConfig(
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      apiUrl: (json['api_url']?.toString() ?? '').trim(),
      apiKey: (json['api_key']?.toString() ?? '').trim(),
      model: (json['model']?.toString() ?? '').trim(),
      apiFormat: normalizeSummaryApiFormat(json['api_format']),
      temperature: _normalizeTemperature(json['temperature']),
      timeoutSeconds: _normalizeTimeout(json['timeout_seconds']),
      reasoningEffort: (json['reasoning_effort']?.toString() ?? '').trim(),
      thinkingEnabled: json['thinking_enabled'] is bool
          ? json['thinking_enabled'] as bool
          : null,
      thinkingBudget: _normalizeBudget(json['thinking_budget']),
      systemPrompt: json['system_prompt']?.toString() ?? '',
      apiKeyMasked: (json['api_key_masked']?.toString() ?? '').trim(),
      profileId: _normalizeProfileId(json['profile_id']),
    );
  }

  /// 服务端负载：不含 `profile_id`（档案是本机概念，服务端不接受该键）。
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'api_url': apiUrl,
    'api_key': apiKey,
    'model': model,
    'api_format': apiFormat,
    'temperature': temperature,
    'timeout_seconds': timeoutSeconds,
    'reasoning_effort': reasoningEffort,
    'thinking_enabled': thinkingEnabled,
    'thinking_budget': thinkingBudget,
    'system_prompt': systemPrompt,
  };

  /// 本地持久化负载：保留档案绑定，密钥由安全存储单独保存。
  Map<String, dynamic> toLocalJson() => {
    for (final entry in toJson().entries)
      if (entry.key != 'api_key') entry.key: entry.value,
    'profile_id': profileId,
    if (apiKeyMasked.isNotEmpty) 'api_key_masked': apiKeyMasked,
  };

  SummaryApiConfig copy() =>
      SummaryApiConfig.fromJson({...toLocalJson(), 'api_key': apiKey});
}

String? _normalizeProfileId(Object? value) {
  final id = value?.toString().trim() ?? '';
  return id.isEmpty ? null : id;
}

/// 一个可编辑的系统提示词：内置默认文本 + 注册表元数据。
///
/// 工具调用相关的提示词不可编辑，服务端不会下发，因此这里没有片段/占位符概念。
class ConfigurablePrompt {
  final String id;
  final String title;
  final String group;
  final String origin;
  final List<String> appliesTo;
  final String builtin;

  /// 内置提示词版本号；覆盖的 `__base_version__` 小于它即“基于旧版”。
  final int version;

  const ConfigurablePrompt({
    required this.id,
    required this.title,
    required this.group,
    required this.origin,
    required this.appliesTo,
    required this.builtin,
    this.version = 1,
  });

  factory ConfigurablePrompt.fromJson(Map<String, dynamic> json) {
    final appliesTo = json['applies_to'];
    return ConfigurablePrompt(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? json['id'] ?? ''}',
      group: '${json['group'] ?? ''}',
      origin: '${json['origin'] ?? ''}',
      appliesTo: appliesTo is List
          ? appliesTo.map((item) => '$item').toList()
          : const <String>[],
      builtin: '${json['builtin'] ?? ''}',
      version: _normalizePromptVersion(json['version']),
    );
  }

  bool get isSummary => appliesTo.contains('summary');

  /// 角色级覆盖只对聊天类提示词生效。
  bool get isChat => appliesTo.contains('chat');

  /// 覆盖是否基于旧版内置提示词（缺失或无法解析 `__base_version__` 视为 1）。
  bool isOverrideStale(Map<String, String> override) {
    if (override.isEmpty) return false;
    return promptOverrideBaseVersion(override) < version;
  }
}

/// 覆盖层内层的两个保留键：`__builtin__` 为 md 全文，`__base_version__` 为基于的内置版本。
///
/// 旧数据里可能残留 `__append__`，客户端不再识别它（视为没有 `__builtin__` 覆盖），
/// 服务端会把旧数据自动折叠为 `__builtin__`。
const String promptOverrideBuiltinKey = '__builtin__';
const String promptOverrideBaseVersionKey = '__base_version__';

/// 把编辑后的全文转换为覆盖；空文本或与内置相同（trim 后）返回空映射，表示无覆盖。
Map<String, String> buildPromptOverride(ConfigurablePrompt prompt, String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed == prompt.builtin.trim()) {
    return <String, String>{};
  }
  return <String, String>{
    promptOverrideBuiltinKey: text,
    promptOverrideBaseVersionKey: prompt.version.toString(),
  };
}

/// 读取覆盖的 `__base_version__`，缺失或非法视为 1。
int promptOverrideBaseVersion(Map<String, String> override) {
  final parsed = int.tryParse((override[promptOverrideBaseVersionKey] ?? '').trim());
  return parsed != null && parsed > 0 ? parsed : 1;
}

int _normalizePromptVersion(Object? value) {
  final parsed = value is num ? value.toInt() : int.tryParse('${value ?? ''}'.trim());
  return parsed != null && parsed > 0 ? parsed : 1;
}

String normalizeSummaryApiFormat(Object? value) {
  final format = value?.toString().trim().toLowerCase() ?? 'auto';
  return const {
        'auto',
        'gemini_native',
        'openai_compatible',
        'zhipu_compatible',
      }.contains(format)
      ? format
      : 'auto';
}

double _normalizeTemperature(Object? value) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse('${value ?? ''}');
  if (parsed == null) return 0.1;
  return parsed.clamp(0.0, 2.0).toDouble();
}

int _normalizeTimeout(Object? value) {
  final parsed = value is num ? value.toInt() : int.tryParse('${value ?? ''}');
  if (parsed == null) return 60;
  return parsed.clamp(1, 3600);
}

int? _normalizeBudget(Object? value) {
  final parsed = value is num ? value.toInt() : int.tryParse('${value ?? ''}');
  return parsed != null && parsed > 0 ? parsed : null;
}
