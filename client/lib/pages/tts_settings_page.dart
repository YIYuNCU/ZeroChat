import 'package:flutter/material.dart';

import '../services/tts_settings_service.dart';
import 'tts_profile_editor_page.dart';

/// 语音合成（TTS）设置页：全局开关 + 档案列表。
///
/// 配置保存在后端。每个档案有自己的供应商（MiMo / Qwen / GPT-SoVITS / 自定义）
/// 与参数；角色可在「角色设置」里选择使用哪个档案，未选择的跟随默认档案。
/// 点击档案进入 [TtsProfileEditorPage] 编辑。
class TtsSettingsPage extends StatefulWidget {
  /// 设置读写服务；默认走 [TtsSettingsService.instance]，测试可注入。
  final TtsSettingsService? service;

  const TtsSettingsPage({super.key, this.service});

  @override
  State<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<TtsSettingsPage> {
  bool _loading = true;
  String? _loadError;
  bool _updatingEnabled = false;
  TtsSettings _settings = const TtsSettings();

  TtsSettingsService get _service =>
      widget.service ?? TtsSettingsService.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 读取设置。[silent] 为 true（从编辑页返回后刷新）时不显示加载圈，
  /// 失败也只提示一下，保留当前列表。
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final settings = await _service.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (silent) {
        _toast('刷新失败：$e');
        return;
      }
      setState(() {
        _loading = false;
        _loadError = '加载失败：$e';
      });
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 总开关立即保存；失败时回滚。
  Future<void> _onEnabledChanged(bool value) async {
    if (_updatingEnabled) return;
    final previous = _settings;
    setState(() {
      _updatingEnabled = true;
      _settings = TtsSettings(
        enabled: value,
        defaultProfileId: previous.defaultProfileId,
        profiles: previous.profiles,
      );
    });
    try {
      final latest = await _service.update(enabled: value);
      if (!mounted) return;
      setState(() {
        if (latest != null) _settings = latest;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _settings = previous);
      _toast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _updatingEnabled = false);
    }
  }

  Future<void> _openEditor(
    TtsProfile profile, {
    bool isNew = false,
    bool makeDefaultOnCreate = false,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => TtsProfileEditorPage(
          service: widget.service,
          profile: profile,
          isNew: isNew,
          isDefault: !isNew && profile.id == _defaultId,
          makeDefaultOnCreate: makeDefaultOnCreate,
        ),
      ),
    );
    if (mounted) await _load(silent: true);
  }

  /// 当前生效的默认档案 id（默认 id 无效时为第一个档案）。
  String get _defaultId => _settings.defaultProfile?.id ?? '';

  Future<void> _onAddPressed() async {
    if (_settings.profiles.length >= TtsSettingsService.maxProfiles) {
      _toast('最多可添加 ${TtsSettingsService.maxProfiles} 个档案');
      return;
    }
    await _openEditor(
      TtsProfile.blank(
        id: TtsSettingsService.newProfileId(),
        name: '档案${_settings.profiles.length + 1}',
      ),
      isNew: true,
      // 还没有可用的默认档案时，新建的第一个档案直接作为默认。
      makeDefaultOnCreate: _settings.defaultProfile == null,
    );
  }

  Widget _section(List<Widget> children) => Material(
    color: Colors.white,
    child: Column(children: children),
  );

  String _enabledSubtitle() {
    final profile = _settings.defaultProfile;
    if (profile == null) return '还没有语音档案，请先添加';
    return profile.configured ? '角色回复可同时发送语音' : '默认档案的参数尚未配置完整';
  }

  Widget _profileTile(TtsProfile profile) {
    final isDefault = profile.id == _defaultId;
    return ListTile(
      key: ValueKey('tts-profile-${profile.id}'),
      title: Row(
        children: [
          Flexible(
            child: Text(
              profile.name.isEmpty ? '未命名' : profile.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isDefault) ...[
            const SizedBox(width: 8),
            Container(
              key: const ValueKey('tts-profile-default-tag'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFD9F2E3),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '默认',
                style: TextStyle(fontSize: 11, color: Color(0xFF07C160)),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(profile.providerLabel),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            profile.configured ? '已配置' : '未配置',
            key: ValueKey('tts-profile-status-${profile.id}'),
            style: TextStyle(
              fontSize: 12,
              color: profile.configured
                  ? const Color(0xFF07C160)
                  : const Color(0xFFE6A23C),
            ),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFFBBBBBB)),
        ],
      ),
      onTap: () => _openEditor(profile),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final profiles = _settings.profiles;
    return ListView(
      children: [
        const SizedBox(height: 10),
        _section([
          SwitchListTile(
            key: const ValueKey('tts-enabled'),
            title: const Text('启用语音合成'),
            subtitle: Text(
              _enabledSubtitle(),
              style: const TextStyle(fontSize: 12),
            ),
            value: _settings.enabled,
            activeThumbColor: const Color(0xFF07C160),
            onChanged: _updatingEnabled ? null : _onEnabledChanged,
          ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '语音档案',
            style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
          ),
        ),
        _section([
          if (profiles.isEmpty)
            const Padding(
              key: ValueKey('tts-profiles-empty'),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '还没有档案，点击下方「添加档案」创建。',
                  style: TextStyle(fontSize: 13, color: Color(0xFF777777)),
                ),
              ),
            ),
          for (final profile in profiles) ...[
            _profileTile(profile),
            const Divider(height: 1, indent: 16),
          ],
          ListTile(
            key: const ValueKey('tts-add-profile'),
            leading: const Icon(Icons.add, color: Color(0xFF07C160)),
            title: const Text('添加档案'),
            onTap: _onAddPressed,
          ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Text(
            '每个档案有独立的供应商与参数，未指定档案的角色使用默认档案；'
            '角色可在「角色设置」里选择档案。密钥只保存在后端，这里仅显示脱敏值。',
            style: TextStyle(fontSize: 12, color: Color(0xFF777777)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('语音合成（TTS）'),
      ),
      body: _buildBody(),
    );
  }
}
