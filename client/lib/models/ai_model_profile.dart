/// A locally saved OpenAI-compatible model endpoint profile.
class AiModelProfile {
  final String id;
  final String name;
  final String apiUrl;
  final String model;
  final String apiKey;

  const AiModelProfile({
    required this.id,
    required this.name,
    required this.apiUrl,
    required this.model,
    required this.apiKey,
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
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'api_url': apiUrl,
    'model': model,
  };
}
