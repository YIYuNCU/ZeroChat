String normalizeApiFormat(Object? value) {
  final format = value?.toString().trim().toLowerCase() ?? 'auto';
  return const {'auto', 'gemini_native', 'openai_compatible'}.contains(format)
      ? format
      : 'auto';
}

enum ModelProfileCapability {
  chat,
  intent,
  vision,
  embedding;

  String get storageValue => name;

  static ModelProfileCapability? fromStorage(Object? value) {
    final raw = value?.toString().trim().toLowerCase();
    for (final capability in values) {
      if (capability.storageValue == raw) return capability;
    }
    return null;
  }
}

/// A reusable local endpoint profile. Its API key remains in secure storage.
class ModelApiProfile {
  final String id;
  final String name;
  final String apiUrl;
  final String model;
  final String apiKey;
  final String apiFormat;
  final Set<ModelProfileCapability> capabilities;
  final String? visionMode;
  final int? timeoutSeconds;
  final String? reasoningEffort;
  final bool? thinkingEnabled;
  final int? thinkingBudget;
  final bool? stream;

  const ModelApiProfile({
    required this.id,
    required this.name,
    required this.apiUrl,
    required this.model,
    required this.apiKey,
    required this.capabilities,
    this.apiFormat = 'auto',
    this.visionMode,
    this.timeoutSeconds,
    this.reasoningEffort,
    this.thinkingEnabled,
    this.thinkingBudget,
    this.stream,
  });

  bool supports(ModelProfileCapability capability) =>
      capabilities.contains(capability);

  factory ModelApiProfile.fromJson(
    Map<String, dynamic> json, {
    String apiKey = '',
  }) {
    final rawCapabilities = json['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities
              .map(ModelProfileCapability.fromStorage)
              .whereType<ModelProfileCapability>()
              .toSet()
        : <ModelProfileCapability>{};
    return ModelApiProfile(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['model'] ?? ''}',
      apiUrl: '${json['api_url'] ?? ''}',
      model: '${json['model'] ?? ''}',
      apiKey: apiKey,
      apiFormat: normalizeApiFormat(json['api_format']),
      capabilities: capabilities,
      visionMode: _normalizeVisionMode(json['vision_mode']),
      timeoutSeconds: _normalizeTimeout(json['timeout_seconds']),
      reasoningEffort: _normalizeReasoningEffort(json['reasoning_effort']),
      thinkingEnabled: json['thinking_enabled'] as bool?,
      thinkingBudget:
          normalizeThinkingBudget(json['thinking_budget']) ??
          normalizeThinkingBudget(json['reasoning_effort']),
      stream: json['stream'] is bool ? json['stream'] as bool : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'api_url': apiUrl,
    'model': model,
    'api_format': apiFormat,
    'capabilities': capabilities.map((item) => item.storageValue).toList(),
    if (visionMode != null) 'vision_mode': visionMode,
    if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
    if (reasoningEffort != null && reasoningEffort!.trim().isNotEmpty)
      'reasoning_effort': reasoningEffort,
    if (thinkingEnabled != null) 'thinking_enabled': thinkingEnabled,
    if (thinkingBudget != null) 'thinking_budget': thinkingBudget,
    if (stream != null) 'stream': stream,
  };
}

/// Compatibility alias for role settings, which expose chat-capable profiles.
typedef AiModelProfile = ModelApiProfile;

/// Legacy persisted vision profile format, used only while migrating old data.
class VisionModelProfile {
  final String id;
  final String name;
  final String apiUrl;
  final String model;
  final String apiKey;
  final String apiFormat;
  final bool enabled;
  final String mode;

  const VisionModelProfile({
    required this.id,
    required this.name,
    required this.apiUrl,
    required this.model,
    required this.apiKey,
    this.apiFormat = 'auto',
    this.enabled = true,
    this.mode = 'standalone',
  });

  factory VisionModelProfile.fromJson(
    Map<String, dynamic> json, {
    String apiKey = '',
  }) => VisionModelProfile(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? json['model'] ?? ''}',
    apiUrl: '${json['api_url'] ?? ''}',
    model: '${json['model'] ?? ''}',
    apiKey: apiKey,
    apiFormat: normalizeApiFormat(json['api_format']),
    enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    mode: _normalizeVisionMode(json['mode']) ?? 'standalone',
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'api_url': apiUrl,
    'model': model,
    'api_format': apiFormat,
    'enabled': enabled,
    'mode': mode,
  };
}

String? _normalizeVisionMode(Object? value) {
  final mode = value?.toString().trim().toLowerCase();
  return const {'standalone', 'pre_model', 'tool'}.contains(mode) ? mode : null;
}

int? _normalizeTimeout(Object? value) {
  final parsed = value is num ? value.toInt() : int.tryParse('${value ?? ''}');
  if (parsed == null) return null;
  return parsed.clamp(1, 3600);
}

String? _normalizeReasoningEffort(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty || int.tryParse(text) != null
      ? null
      : text;
}

int? normalizeThinkingBudget(Object? value) {
  final parsed = int.tryParse('${value ?? ''}');
  return parsed != null && parsed > 0 ? parsed : null;
}

bool supportsThinkingBudget(String apiUrl, String apiFormat, String model) {
  final uri = Uri.tryParse(apiUrl.trim());
  final host = uri?.host.toLowerCase() ?? '';
  return host.contains('siliconflow') ||
      host.contains('dashscope') ||
      host.contains('aliyuncs') ||
      apiFormat == 'gemini_native' ||
      (host == 'generativelanguage.googleapis.com' &&
          apiFormat != 'openai_compatible' &&
          !(uri?.path.contains('/openai') ?? false));
}
