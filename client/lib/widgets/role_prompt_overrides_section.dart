import 'package:flutter/material.dart';

import '../models/role_prompt_overrides.dart';
import '../models/summary_config.dart';
import '../services/settings_service.dart';
import 'prompt_editor.dart';

typedef PromptRegistryLoader =
    Future<Map<String, ConfigurablePrompt>> Function({bool force});

/// 角色设置页里的“提示词（仅此角色）”分组。
///
/// 只列出对聊天生效（`applies_to` 含 `chat`）的提示词；总结类提示词只有全局一层。
/// 编辑结果通过 [onChanged] 以完整的新 metadata 交还给调用方（保留其他 key），
/// 由调用方随角色一起保存。
class RolePromptOverridesSection extends StatefulWidget {
  final String roleName;
  final Map<String, dynamic> metadata;
  final ValueChanged<Map<String, dynamic>> onChanged;

  /// 提示词注册表加载函数；默认走 [SettingsService]，测试可注入。
  final PromptRegistryLoader? loadRegistry;

  const RolePromptOverridesSection({
    super.key,
    required this.roleName,
    required this.metadata,
    required this.onChanged,
    this.loadRegistry,
  });

  @override
  State<RolePromptOverridesSection> createState() =>
      _RolePromptOverridesSectionState();
}

class _RolePromptOverridesSectionState
    extends State<RolePromptOverridesSection> {
  bool _loading = true;
  String? _error;
  List<ConfigurablePrompt> _prompts = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  PromptRegistryLoader get _loader =>
      widget.loadRegistry ?? SettingsService.instance.loadPromptRegistry;

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final registry = await _loader(force: force);
      final prompts =
          registry.values.where((prompt) => prompt.isChat).toList()
            ..sort((a, b) => a.id.compareTo(b.id));
      if (!mounted) return;
      setState(() {
        _prompts = prompts;
        _loading = false;
        // loadPromptRegistry 会吞掉网络错误并返回空表，空表同样视为加载失败。
        _error = prompts.isEmpty ? '提示词列表加载失败' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '提示词列表加载失败：$e';
      });
    }
  }

  Future<void> _edit(ConfigurablePrompt prompt) async {
    final edited = await showPromptEditor(
      context,
      prompt: prompt,
      current: readRolePromptOverride(widget.metadata, prompt.id),
      scopeLabel: widget.roleName,
    );
    if (edited == null || !mounted) return;
    widget.onChanged(
      writeRolePromptOverride(widget.metadata, prompt.id, edited),
    );
  }

  Widget _badge(String text, Color color) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Text(text, style: TextStyle(fontSize: 12, color: color)),
  );

  Widget _row(ConfigurablePrompt prompt) {
    final override = readRolePromptOverride(widget.metadata, prompt.id);
    final overridden = override.isNotEmpty;
    final stale = prompt.isOverrideStale(override);
    return ListTile(
      key: ValueKey('role-prompt-${prompt.id}'),
      title: Text(prompt.title),
      subtitle: Text(
        prompt.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stale) _badge('基于旧版', const Color(0xFFE6A23C)),
          if (overridden) _badge('已自定义', const Color(0xFF07C160)),
          const Icon(Icons.arrow_forward_ios, size: 16),
        ],
      ),
      onTap: () => _edit(prompt),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < _prompts.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16),
          _row(_prompts[i]),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 16, bottom: 8),
          child: Text(
            '提示词（仅此角色）',
            style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
          ),
        ),
        // 用 Material 而不是带颜色的 Container，ListTile 的水波纹才能正常绘制。
        Material(
          color: Colors.white,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '直接编辑提示词全文，只对此角色生效，优先于全局提示词；'
                  '修改后点右上角「保存」才会生效。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
                ),
              ),
              _body(),
            ],
          ),
        ),
      ],
    );
  }
}
