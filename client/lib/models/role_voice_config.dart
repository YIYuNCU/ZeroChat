/// 角色 `metadata` 中存放按角色语音（TTS）配置的 key。
///
/// 结构：`{enabled: bool, voice, style, ref_audio_path, prompt_text,
/// prompt_lang, text_lang}`；`enabled == false` 表示此角色不发语音，
/// 其余字符串留空表示沿用全局配置。
/// 服务端 `RoleUpdate.metadata` 是整体替换，所以写入时必须保留其他 key。
const String roleVoiceMetadataKey = 'voice';

/// 角色语音配置里的字符串字段 key（与服务端约定一致）。
const List<String> _voiceStringKeys = [
  'voice',
  'style',
  'ref_audio_path',
  'prompt_text',
  'prompt_lang',
  'text_lang',
];

/// 一个角色的语音配置（读取自 / 写回 `role.metadata['voice']`）。
class RoleVoiceConfig {
  /// 是否允许此角色发送语音；false 时服务端不会为该角色合成语音。
  final bool enabled;

  /// 音色（留空沿用全局默认）。
  final String voice;

  /// 语气 / 风格（留空沿用全局默认）。
  final String style;

  /// GPT-SoVITS：参考音频路径。
  final String refAudioPath;

  /// GPT-SoVITS：参考音频对应文本。
  final String promptText;

  /// GPT-SoVITS：参考音频语言。
  final String promptLang;

  /// GPT-SoVITS：合成文本语言。
  final String textLang;

  const RoleVoiceConfig({
    this.enabled = true,
    this.voice = '',
    this.style = '',
    this.refAudioPath = '',
    this.promptText = '',
    this.promptLang = '',
    this.textLang = '',
  });

  /// 全部为默认值（启用且没有任何覆盖）。
  bool get isDefault =>
      enabled &&
      voice.isEmpty &&
      style.isEmpty &&
      refAudioPath.isEmpty &&
      promptText.isEmpty &&
      promptLang.isEmpty &&
      textLang.isEmpty;

  RoleVoiceConfig copyWith({
    bool? enabled,
    String? voice,
    String? style,
    String? refAudioPath,
    String? promptText,
    String? promptLang,
    String? textLang,
  }) {
    return RoleVoiceConfig(
      enabled: enabled ?? this.enabled,
      voice: voice ?? this.voice,
      style: style ?? this.style,
      refAudioPath: refAudioPath ?? this.refAudioPath,
      promptText: promptText ?? this.promptText,
      promptLang: promptLang ?? this.promptLang,
      textLang: textLang ?? this.textLang,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoleVoiceConfig &&
      other.enabled == enabled &&
      other.voice == voice &&
      other.style == style &&
      other.refAudioPath == refAudioPath &&
      other.promptText == promptText &&
      other.promptLang == promptLang &&
      other.textLang == textLang;

  @override
  int get hashCode => Object.hash(
    enabled,
    voice,
    style,
    refAudioPath,
    promptText,
    promptLang,
    textLang,
  );
}

/// 读取角色 metadata 里的语音配置；缺失或结构不正确时返回默认配置。
RoleVoiceConfig readRoleVoiceConfig(Map<String, dynamic> metadata) {
  final raw = metadata[roleVoiceMetadataKey];
  if (raw is! Map) return const RoleVoiceConfig();
  String text(String key) => (raw[key] ?? '').toString().trim();
  return RoleVoiceConfig(
    // 只有显式 false 才算关闭，缺失按启用处理。
    enabled: raw['enabled'] != false,
    voice: text('voice'),
    style: text('style'),
    refAudioPath: text('ref_audio_path'),
    promptText: text('prompt_text'),
    promptLang: text('prompt_lang'),
    textLang: text('text_lang'),
  );
}

/// 返回写入语音配置后的新 metadata（不修改入参）。
///
/// - 启用状态只在关闭时写 `enabled: false`，启用则移除该 key；
/// - 字符串字段为空时移除对应 key；
/// - `voice` 子映射里不认识的 key 原样保留；
/// - 子映射最终为空：从 metadata 中移除 `voice`；
/// - metadata 里其他 key 保持不变。
Map<String, dynamic> writeRoleVoiceConfig(
  Map<String, dynamic> metadata,
  RoleVoiceConfig config,
) {
  final next = Map<String, dynamic>.of(metadata);
  final existing = metadata[roleVoiceMetadataKey];
  final voice = existing is Map
      ? Map<String, dynamic>.of(existing.cast<String, dynamic>())
      : <String, dynamic>{};

  if (config.enabled) {
    voice.remove('enabled');
  } else {
    voice['enabled'] = false;
  }

  final values = <String, String>{
    'voice': config.voice.trim(),
    'style': config.style.trim(),
    'ref_audio_path': config.refAudioPath.trim(),
    'prompt_text': config.promptText.trim(),
    'prompt_lang': config.promptLang.trim(),
    'text_lang': config.textLang.trim(),
  };
  for (final key in _voiceStringKeys) {
    final value = values[key]!;
    if (value.isEmpty) {
      voice.remove(key);
    } else {
      voice[key] = value;
    }
  }

  if (voice.isEmpty) {
    next.remove(roleVoiceMetadataKey);
  } else {
    next[roleVoiceMetadataKey] = voice;
  }
  return next;
}
