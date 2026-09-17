/// 记忆总结（事件总结 / 核心记忆总结）的独立配置与可配置系统提示词模型。
///
/// 这两个功能不再挂靠在任何角色上，服务端以 `context_summary_config` /
/// `core_memory_summary_config` 单独存储；提示词来自服务端提示词注册表，可全局覆盖或按
/// 模型档案（provider + model）覆盖。
library;

/// 目的一致的两个总结功能标识，与服务端 `summary_config_service` 保持一致。
enum SummaryFeature {
  context('context_summary', '事件总结', '把历史对话压缩成上下文摘要与事件记忆'),
  coreMemory('core_memory_summary', '核心记忆总结', '把长期事实归纳进核心记忆');

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

  const ConfigurablePrompt({
    required this.id,
    required this.title,
    required this.group,
    required this.origin,
    required this.appliesTo,
    required this.builtin,
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
    );
  }

  bool get isSummary => appliesTo.contains('summary');
}

/// 与服务端 `prompt_config_service.model_target_key` 保持一致的档案键。
String modelPromptTargetKey(String apiUrl, String model) {
  final url = apiUrl.trim().toLowerCase();
  final name = model.trim().toLowerCase();
  if (url.isEmpty || name.isEmpty) return '';
  return '$url|$name';
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
