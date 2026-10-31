import 'package:flutter/material.dart';

import '../models/role_voice_config.dart';
import '../services/tts_settings_service.dart';

/// 角色设置页里的“语音（仅此角色）”分组。
///
/// 编辑结果通过 [onChanged] 以完整的新 metadata 交还给调用方（保留其他 key），
/// 由调用方随角色一起保存。顶部的「语音档案」选择该角色使用的 TTS 档案
/// （留空跟随默认档案），其余留空的字段表示沿用所选档案的配置。
class RoleVoiceSection extends StatefulWidget {
  final String roleName;
  final Map<String, dynamic> metadata;
  final ValueChanged<Map<String, dynamic>> onChanged;

  /// 是否显示顶部的灰色小标题；嵌在带标题的可折叠分组里时应关掉，避免重复。
  final bool showHeader;

  /// 读取档案列表用的服务；默认走 [TtsSettingsService.instance]，测试可注入。
  final TtsSettingsService? ttsService;

  const RoleVoiceSection({
    super.key,
    required this.roleName,
    required this.metadata,
    required this.onChanged,
    this.showHeader = true,
    this.ttsService,
  });

  @override
  State<RoleVoiceSection> createState() => _RoleVoiceSectionState();
}

class _RoleVoiceSectionState extends State<RoleVoiceSection> {
  late RoleVoiceConfig _config;
  late final TextEditingController _voice;
  late final TextEditingController _style;
  late final TextEditingController _refAudioPath;
  late final TextEditingController _promptText;
  late final TextEditingController _promptLang;
  late final TextEditingController _textLang;

  /// 已加载的 TTS 档案；null 表示尚未加载或加载失败。
  List<TtsProfile>? _profiles;

  @override
  void initState() {
    super.initState();
    _config = readRoleVoiceConfig(widget.metadata);
    _voice = TextEditingController(text: _config.voice);
    _style = TextEditingController(text: _config.style);
    _refAudioPath = TextEditingController(text: _config.refAudioPath);
    _promptText = TextEditingController(text: _config.promptText);
    _promptLang = TextEditingController(text: _config.promptLang);
    _textLang = TextEditingController(text: _config.textLang);
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    try {
      final settings = await (widget.ttsService ?? TtsSettingsService.instance)
          .load();
      if (!mounted) return;
      setState(() => _profiles = settings.profiles);
    } catch (_) {
      // 加载失败时只提供「跟随默认档案」和当前值，不阻塞其他字段。
    }
  }

  @override
  void dispose() {
    _voice.dispose();
    _style.dispose();
    _refAudioPath.dispose();
    _promptText.dispose();
    _promptLang.dispose();
    _textLang.dispose();
    super.dispose();
  }

  void _update(RoleVoiceConfig next) {
    setState(() => _config = next);
    widget.onChanged(writeRoleVoiceConfig(widget.metadata, next));
  }

  Widget _field({
    required String keyName,
    required String label,
    required String hint,
    required TextEditingController controller,
    required RoleVoiceConfig Function(String value) apply,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 82, child: Text(label)),
          Expanded(
            child: TextField(
              key: ValueKey('role-voice-$keyName'),
              controller: controller,
              onChanged: (value) => _update(apply(value)),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: hint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「语音档案」下拉：跟随默认档案 + 所有档案；当前值不在列表里时保留为额外项。
  Widget _profileSelector() {
    final profiles = _profiles;
    final current = _config.profileId;
    final known = profiles?.any((p) => p.id == current) ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          const SizedBox(width: 82, child: Text('语音档案')),
          Expanded(
            child: DropdownButton<String>(
              key: const ValueKey('role-voice-profile'),
              value: current,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem<String>(
                  value: '',
                  child: Text('跟随默认档案'),
                ),
                for (final profile in profiles ?? const <TtsProfile>[])
                  DropdownMenuItem<String>(
                    value: profile.id,
                    child: Text(
                      profile.name.isEmpty ? '未命名' : profile.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (current.isNotEmpty && !known)
                  DropdownMenuItem<String>(
                    value: current,
                    enabled: false,
                    child: Text(
                      profiles == null ? '当前档案：$current' : '（已删除的档案）',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFF999999)),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                _update(_config.copyWith(profileId: value));
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSovits =
        _config.refAudioPath.isNotEmpty ||
        _config.promptText.isNotEmpty ||
        _config.promptLang.isNotEmpty ||
        _config.textLang.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader)
          const Padding(
            padding: EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              '语音（仅此角色）',
              style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
            ),
          ),
        Material(
          color: Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                key: const ValueKey('role-voice-enabled'),
                title: const Text('允许发送语音'),
                subtitle: const Text(
                  '关闭后此角色只发文字；需先在「API 设置 → 语音合成」启用并配置。',
                  style: TextStyle(fontSize: 12),
                ),
                value: _config.enabled,
                activeThumbColor: const Color(0xFF07C160),
                onChanged: (value) => _update(_config.copyWith(enabled: value)),
              ),
              if (_config.enabled) ...[
                const Divider(height: 1, indent: 16),
                _profileSelector(),
                const Divider(height: 1, indent: 16),
                _field(
                  keyName: 'voice',
                  label: '音色',
                  hint: '留空沿用档案默认',
                  controller: _voice,
                  apply: (value) => _config.copyWith(voice: value),
                ),
                const Divider(height: 1, indent: 16),
                _field(
                  keyName: 'style',
                  label: '风格',
                  hint: '语气/风格描述，留空沿用档案默认',
                  controller: _style,
                  apply: (value) => _config.copyWith(style: value),
                ),
                const Divider(height: 1, indent: 16),
                ExpansionTile(
                  key: const ValueKey('role-voice-sovits'),
                  initiallyExpanded: hasSovits,
                  title: const Text('GPT-SoVITS 参考音频'),
                  subtitle: const Text(
                    '仅使用 GPT-SoVITS 时需要',
                    style: TextStyle(fontSize: 12),
                  ),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  children: [
                    _field(
                      keyName: 'ref_audio_path',
                      label: '参考音频',
                      hint: '服务端可访问的音频路径',
                      controller: _refAudioPath,
                      apply: (value) => _config.copyWith(refAudioPath: value),
                    ),
                    const Divider(height: 1, indent: 16),
                    _field(
                      keyName: 'prompt_text',
                      label: '参考文本',
                      hint: '参考音频对应的文字',
                      controller: _promptText,
                      apply: (value) => _config.copyWith(promptText: value),
                    ),
                    const Divider(height: 1, indent: 16),
                    _field(
                      keyName: 'prompt_lang',
                      label: '参考语言',
                      hint: '例如 zh',
                      controller: _promptLang,
                      apply: (value) => _config.copyWith(promptLang: value),
                    ),
                    const Divider(height: 1, indent: 16),
                    _field(
                      keyName: 'text_lang',
                      label: '合成语言',
                      hint: '例如 zh',
                      controller: _textLang,
                      apply: (value) => _config.copyWith(textLang: value),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
