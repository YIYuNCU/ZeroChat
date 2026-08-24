String normalizeApiFormat(Object? value) {
  final format = value?.toString().trim().toLowerCase() ?? 'auto';
  return const {'auto', 'gemini_native', 'openai_compatible'}.contains(format)
      ? format
      : 'auto';
}

/// A locally saved chat model endpoint profile.
class AiModelProfile {
  final String id;
  final String name;
  final String apiUrl;
  final String model;
  final String apiKey;
  final String apiFormat;

  const AiModelProfile({
    required this.id,
    required this.name,
    required this.apiUrl,
    required this.model,
    required this.apiKey,
    this.apiFormat = 'auto',
  });

  factory AiModelProfile.fromJson(
    Map<String, dynamic> json, {
    String apiKey = '',
  }) {
    return AiModelProfile(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['model'] ?? ''}',
      apiUrl: '${json['api_url'] ?? ''}',
      model: '${json['model'] ?? ''}',
      apiKey: apiKey,
      apiFormat: normalizeApiFormat(json['api_format']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'api_url': apiUrl,
    'model': model,
    'api_format': apiFormat,
  };
}

/// A locally saved vision model endpoint profile.
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
  }) {
    final mode = json['mode']?.toString().trim().toLowerCase() ?? 'standalone';
    return VisionModelProfile(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? json['model'] ?? ''}',
      apiUrl: '${json['api_url'] ?? ''}',
      model: '${json['model'] ?? ''}',
      apiKey: apiKey,
      apiFormat: normalizeApiFormat(json['api_format']),
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      mode: const {'standalone', 'pre_model', 'tool'}.contains(mode)
          ? mode
          : 'standalone',
    );
  }

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
