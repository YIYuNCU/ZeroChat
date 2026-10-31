import 'package:flutter/foundation.dart';

import 'secure_websocket_client.dart';

/// 发送一次后端 WebSocket 请求；测试里可注入假实现。
typedef TtsRequest =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, dynamic> payload, {
      Duration? timeout,
    });

/// 某个 TTS 供应商的一个配置字段。
class TtsProviderField {
  /// 与服务端配置一致的 key，例如 `api_url`。
  final String key;
  final String label;
  final String hint;

  /// 密钥字段：服务端只返回 `<key>_masked`，只有用户输入了新值才会提交。
  final bool secret;

  /// 数值字段：提交时按数字发送，无法解析则不提交。
  final bool numeric;

  /// 多行文本字段（如 JSON 模板），页面用等宽字体的多行输入框展示。
  final bool multiline;

  /// 固定选项（下拉选择）；为空表示自由输入。取值即提交给服务端的值。
  final List<String> options;

  /// 条件显示：仅当同一供应商的 `hideWhenKey` 字段值等于 `hideWhenValue` 时隐藏。
  /// 隐藏只影响展示，字段值仍会随表单一起提交。
  final String? hideWhenKey;
  final String? hideWhenValue;

  const TtsProviderField(
    this.key,
    this.label,
    this.hint, {
    this.secret = false,
    this.numeric = false,
    this.multiline = false,
    this.options = const [],
    this.hideWhenKey,
    this.hideWhenValue,
  });
}

/// TTS 供应商的字段声明（页面据此生成表单，提交据此组装 payload）。
class TtsProviderSpec {
  final String id;
  final String label;
  final List<TtsProviderField> fields;

  /// 显示在该供应商参数下方的说明文字（可选）。
  final String help;

  const TtsProviderSpec(this.id, this.label, this.fields, {this.help = ''});
}

/// 支持的 TTS 供应商；顺序即页面展示顺序。
const List<TtsProviderSpec> ttsProviderSpecs = [
  TtsProviderSpec('mimo', 'MiMo', [
    TtsProviderField('api_url', '接口地址', 'API 地址'),
    TtsProviderField('api_key', 'API Key', '', secret: true),
    TtsProviderField('model', '模型', '模型名称'),
    TtsProviderField('voice', '默认音色', '音色名称'),
    TtsProviderField('style', '默认风格', '语气/风格描述（可选）'),
  ]),
  TtsProviderSpec('qwen', 'Qwen', [
    TtsProviderField('api_url', '接口地址', 'API 地址'),
    TtsProviderField('api_key', 'API Key', '', secret: true),
    TtsProviderField('model', '模型', '模型名称'),
    TtsProviderField('voice', '默认音色', '音色名称'),
    TtsProviderField('language_type', '语言类型', '例如 Chinese'),
    TtsProviderField('style', '默认风格', '语气/风格描述（可选）'),
  ]),
  TtsProviderSpec('gpt_sovits', 'GPT-SoVITS', [
    TtsProviderField('api_url', '接口地址', 'http://127.0.0.1:9880'),
    TtsProviderField('ref_audio_path', '参考音频', '服务端可访问的参考音频路径'),
    TtsProviderField('prompt_text', '参考文本', '参考音频对应的文字'),
    TtsProviderField('prompt_lang', '参考语言', 'zh'),
    TtsProviderField('text_lang', '合成语言', 'zh'),
    TtsProviderField('text_split_method', '切分方式', 'cut5'),
    TtsProviderField('speed_factor', '语速', '1.0', numeric: true),
  ]),
  TtsProviderSpec(
    'custom',
    '自定义',
    [
      TtsProviderField(
        'api_url',
        '接口地址',
        'https://example.com/v1/audio/speech',
      ),
      TtsProviderField('api_key', 'API Key', '', secret: true),
      TtsProviderField('method', '请求方法', '', options: ['POST', 'GET']),
      TtsProviderField(
        'headers',
        '请求头',
        '{"Authorization": "Bearer {{api_key}}"}',
        multiline: true,
      ),
      TtsProviderField(
        'body',
        '请求体',
        '{"input": "{{text}}", "voice": "{{voice}}"}',
        multiline: true,
      ),
      TtsProviderField('model', '模型', '对应 {{model}}（可选）'),
      TtsProviderField('voice', '默认音色', '对应 {{voice}}（可选）'),
      TtsProviderField('style', '默认风格', '对应 {{style}}（可选）'),
      TtsProviderField(
        'response_type',
        '响应类型',
        '',
        options: ['binary', 'base64', 'url'],
      ),
      TtsProviderField(
        'response_path',
        '响应字段',
        '例如 data.audio 或 choices[0].audio',
        hideWhenKey: 'response_type',
        hideWhenValue: 'binary',
      ),
    ],
    help:
        '请求头、请求体为 JSON 模板，可用占位符：{{text}}（必须）、{{voice}}、'
        '{{style}}、{{model}}、{{api_key}}；接口地址里也可使用，会自动 URL 编码。'
        'GET 时请求体的键值会作为查询参数。响应类型：binary 直接返回音频；'
        'base64 / url 表示音频在 JSON 的「响应字段」里。仅支持 wav / mp3。'
        '建议用 {{api_key}} 引用密钥，不要把密钥直接写进请求头。',
  ),
];

/// 下拉选项的展示名；未登记的选项直接显示原值。
const Map<String, String> ttsOptionLabels = {
  'binary': 'binary（直接返回音频）',
  'base64': 'base64（JSON 内的 base64）',
  'url': 'url（JSON 内的音频链接）',
};

int _readTtsInt(dynamic value, int fallback) {
  if (value is num) return value.round();
  return int.tryParse(value?.toString().trim() ?? '') ?? fallback;
}

/// 一个 TTS 档案（`settings_tts_get` 里 `profiles` 的一项）：
/// 名称 + 当前供应商 + 超时 / 字数上限 + 各供应商的字段值。
class TtsProfile {
  final String id;
  final String name;

  /// 当前使用的供应商 id：`mimo` / `qwen` / `gpt_sovits` / `custom`。
  final String provider;
  final int timeoutSeconds;
  final int maxChars;

  /// 后端判断该档案当前供应商的配置是否完整可用。
  final bool configured;

  /// 各供应商的字段值（均为字符串）；密钥字段以 `<key>_masked` 存放脱敏值。
  final Map<String, Map<String, String>> providers;

  const TtsProfile({
    required this.id,
    this.name = '',
    this.provider = 'mimo',
    this.timeoutSeconds = 60,
    this.maxChars = 300,
    this.configured = false,
    this.providers = const {},
  });

  /// 尚未保存的新档案：所有字段为空，由用户填写。
  factory TtsProfile.blank({required String id, String name = ''}) =>
      TtsProfile(id: id, name: name);

  factory TtsProfile.fromJson(Map<String, dynamic> json) {
    final providers = <String, Map<String, String>>{};
    for (final spec in ttsProviderSpecs) {
      final section = json[spec.id];
      final map = section is Map ? section : const {};
      final values = <String, String>{};
      for (final field in spec.fields) {
        final key = field.secret ? '${field.key}_masked' : field.key;
        final value = map[key];
        values[key] = value == null ? '' : value.toString();
      }
      providers[spec.id] = values;
    }
    final provider = (json['provider'] ?? '').toString();
    return TtsProfile(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      provider: ttsProviderSpecs.any((spec) => spec.id == provider)
          ? provider
          : ttsProviderSpecs.first.id,
      timeoutSeconds: _readTtsInt(json['timeout_seconds'], 60),
      maxChars: _readTtsInt(json['max_chars'], 300),
      configured: json['configured'] == true,
      providers: providers,
    );
  }

  /// 当前供应商的展示名。
  String get providerLabel => ttsProviderSpecs
      .firstWhere(
        (spec) => spec.id == provider,
        orElse: () => ttsProviderSpecs.first,
      )
      .label;

  /// 指定供应商某字段的当前值（密钥字段取脱敏值）。
  String valueOf(String provider, String key) =>
      providers[provider]?[key] ?? '';
}

/// 后端返回的 TTS 设置（`settings_tts_get`）：全局开关 + 档案列表。
///
/// 服务端响应里镜像默认档案的旧版顶层字段（provider、mimo 等）会被忽略。
class TtsSettings {
  /// 全局总开关。
  final bool enabled;

  /// 未单独指定档案的角色使用的档案 id；没有任何档案时可能为空。
  final String defaultProfileId;
  final List<TtsProfile> profiles;

  const TtsSettings({
    this.enabled = false,
    this.defaultProfileId = '',
    this.profiles = const [],
  });

  /// 解析 `settings_tts_get` 的响应（`{tts: {...}}`；也兼容直接传入 tts 对象）。
  factory TtsSettings.fromResponse(Map<String, dynamic> response) {
    final raw = response['tts'];
    final json = raw is Map ? Map<String, dynamic>.from(raw) : response;
    final rawProfiles = json['profiles'];
    final profiles = <TtsProfile>[];
    if (rawProfiles is List) {
      for (final item in rawProfiles) {
        if (item is! Map) continue;
        final profile = TtsProfile.fromJson(Map<String, dynamic>.from(item));
        if (profile.id.isNotEmpty) profiles.add(profile);
      }
    }
    return TtsSettings(
      enabled: json['enabled'] == true,
      defaultProfileId: (json['default_profile_id'] ?? '').toString(),
      profiles: profiles,
    );
  }

  /// 按 id 查找档案；找不到返回 null。
  TtsProfile? profileById(String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// 默认档案；默认 id 无效时退回第一个档案，没有档案则为 null。
  TtsProfile? get defaultProfile =>
      profileById(defaultProfileId) ??
      (profiles.isEmpty ? null : profiles.first);
}

/// `settings_tts_test` 的结果。
class TtsTestResult {
  final bool success;
  final int? latencyMs;
  final int? size;
  final int? durationMs;
  final String error;

  const TtsTestResult({
    required this.success,
    this.latencyMs,
    this.size,
    this.durationMs,
    this.error = '',
  });

  factory TtsTestResult.fromResponse(Map<String, dynamic> response) {
    int? readInt(dynamic value) =>
        value is num ? value.round() : int.tryParse('${value ?? ''}');
    return TtsTestResult(
      success: response['success'] == true,
      latencyMs: readInt(response['latency_ms']),
      size: readInt(response['size']),
      durationMs: readInt(response['duration_ms']),
      error: (response['error'] ?? '').toString(),
    );
  }

  /// 展示给用户的一句话结果。
  String get summary {
    if (!success) return error.isEmpty ? '测试失败' : '测试失败：$error';
    final parts = <String>[
      if (latencyMs != null) '耗时 ${latencyMs}ms',
      if (size != null) '大小 ${(size! / 1024).toStringAsFixed(1)}KB',
      if (durationMs != null) '时长 ${(durationMs! / 1000).toStringAsFixed(1)}s',
    ];
    return parts.isEmpty ? '测试成功' : '测试成功：${parts.join('，')}';
  }
}

/// TTS 全局设置的读取 / 保存 / 测试（经加密 WebSocket 与后端交互）。
class TtsSettingsService {
  TtsSettingsService({TtsRequest? request})
    : _request = request ?? _defaultRequest;

  static final TtsSettingsService instance = TtsSettingsService();

  final TtsRequest _request;

  static Future<Map<String, dynamic>> _defaultRequest(
    String action,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) {
    if (timeout == null) {
      return SecureWebSocketClient.instance.request(action, payload);
    }
    return SecureWebSocketClient.instance.request(
      action,
      payload,
      timeout: timeout,
    );
  }

  /// 读取当前设置；失败时抛出异常。
  Future<TtsSettings> load() async {
    final response = await _request('settings_tts_get', const {});
    return TtsSettings.fromResponse(response);
  }

  /// 服务端允许的档案数量上限。
  static const int maxProfiles = 20;

  /// 生成新档案 id：1-40 位 `[A-Za-z0-9_-]`。
  static String newProfileId() =>
      'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// 组装一个档案的 upsert 项（`updates.profiles` 的元素）。
  ///
  /// [providers] 为各供应商表单当前值（字符串）。密钥字段只在用户输入了新值
  /// （非空）时才提交，缺省即保留服务端原值；数值字段无法解析时不提交。
  static Map<String, dynamic> buildProfileUpdate({
    required String id,
    required String name,
    required String provider,
    required int timeoutSeconds,
    required int maxChars,
    required Map<String, Map<String, String>> providers,
  }) {
    final profile = <String, dynamic>{
      'id': id,
      'name': name.trim(),
      'provider': provider,
      'timeout_seconds': timeoutSeconds,
      'max_chars': maxChars,
    };
    for (final spec in ttsProviderSpecs) {
      final values = providers[spec.id] ?? const <String, String>{};
      final section = <String, dynamic>{};
      for (final field in spec.fields) {
        final raw = (values[field.key] ?? '').trim();
        if (field.secret) {
          if (raw.isNotEmpty) section[field.key] = raw;
        } else if (field.numeric) {
          final number = double.tryParse(raw);
          if (number != null) section[field.key] = number;
        } else {
          section[field.key] = raw;
        }
      }
      profile[spec.id] = section;
    }
    return profile;
  }

  /// 组装 `settings_tts_update` 的 `updates`；只包含传入的部分。
  @visibleForTesting
  static Map<String, dynamic> buildUpdates({
    bool? enabled,
    String? defaultProfileId,
    List<Map<String, dynamic>> profiles = const [],
    List<String> deleteProfileIds = const [],
  }) {
    return <String, dynamic>{
      'enabled': ?enabled,
      'default_profile_id': ?defaultProfileId,
      if (profiles.isNotEmpty) 'profiles': profiles,
      if (deleteProfileIds.isNotEmpty) 'delete_profile_ids': deleteProfileIds,
    };
  }

  /// 提交更新；失败时抛出异常。成功后返回服务端给出的最新设置（响应不含时为 null）。
  Future<TtsSettings?> update({
    bool? enabled,
    String? defaultProfileId,
    List<Map<String, dynamic>> profiles = const [],
    List<String> deleteProfileIds = const [],
  }) async {
    final response = await _request('settings_tts_update', {
      'updates': buildUpdates(
        enabled: enabled,
        defaultProfileId: defaultProfileId,
        profiles: profiles,
        deleteProfileIds: deleteProfileIds,
      ),
    });
    if (response['success'] == false) {
      final error = (response['error'] ?? '').toString();
      throw StateError(error.isEmpty ? '保存失败' : error);
    }
    return response['tts'] is Map ? TtsSettings.fromResponse(response) : null;
  }

  /// 用已保存的档案合成一句测试语音（耗时较长，使用更长的请求超时）。
  /// [profileId] 为空时测试默认档案。
  Future<TtsTestResult> test({String? profileId}) async {
    final id = (profileId ?? '').trim();
    final response = await _request(
      'settings_tts_test',
      id.isEmpty ? const <String, dynamic>{} : {'profile_id': id},
      timeout: const Duration(seconds: 90),
    );
    return TtsTestResult.fromResponse(response);
  }
}
