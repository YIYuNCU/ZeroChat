import 'package:flutter/material.dart';

import '../services/tts_settings_service.dart';
import '../widgets/settings_group.dart';

/// 各供应商里收进「高级请求格式」折叠组的字段 key（请求模板与响应解析）。
/// 未登记的供应商没有高级字段，全部平铺。
const Map<String, Set<String>> _ttsAdvancedFieldKeys = {
  'custom': {'method', 'headers', 'body', 'response_type', 'response_path'},
};

/// 语音合成（TTS）设置页。
///
/// 配置保存在后端：全局开关、当前供应商（MiMo / Qwen / GPT-SoVITS / 自定义）及其参数。
/// 密钥只在用户输入了新值时才提交，留空表示保持服务端原值。
class TtsSettingsPage extends StatefulWidget {
  /// 设置读写服务；默认走 [TtsSettingsService.instance]，测试可注入。
  final TtsSettingsService? service;

  const TtsSettingsPage({super.key, this.service});

  @override
  State<TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<TtsSettingsPage> {
  final TextEditingController _timeout = TextEditingController();
  final TextEditingController _maxChars = TextEditingController();

  /// 各供应商字段的输入框，key 为 `<provider>/<field>`。
  final Map<String, TextEditingController> _controllers = {};

  /// 各供应商密钥的脱敏展示值，key 为 `<provider>/<field>`。
  final Map<String, String> _maskedKeys = {};

  bool _loading = true;
  String? _loadError;
  bool _saving = false;
  bool _testing = false;
  bool _showSecrets = false;

  bool _enabled = false;
  bool _configured = false;
  String _provider = ttsProviderSpecs.first.id;

  String? _testResult;
  bool _testOk = false;

  TtsSettingsService get _service =>
      widget.service ?? TtsSettingsService.instance;

  String _controllerKey(String provider, String field) => '$provider/$field';

  @override
  void initState() {
    super.initState();
    for (final spec in ttsProviderSpecs) {
      for (final field in spec.fields) {
        _controllers[_controllerKey(spec.id, field.key)] =
            TextEditingController();
      }
    }
    _load();
  }

  @override
  void dispose() {
    _timeout.dispose();
    _maxChars.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final settings = await _service.load();
      if (!mounted) return;
      setState(() {
        _apply(settings);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '加载失败：$e';
      });
    }
  }

  /// 把后端设置写入表单；密钥输入框始终清空，只展示脱敏值作为提示。
  void _apply(TtsSettings settings) {
    _enabled = settings.enabled;
    _configured = settings.configured;
    _provider = settings.provider;
    _timeout.text = settings.timeoutSeconds.toString();
    _maxChars.text = settings.maxChars.toString();
    for (final spec in ttsProviderSpecs) {
      for (final field in spec.fields) {
        final key = _controllerKey(spec.id, field.key);
        if (field.secret) {
          _controllers[key]!.clear();
          _maskedKeys[key] = settings.valueOf(spec.id, '${field.key}_masked');
        } else {
          _controllers[key]!.text = settings.valueOf(spec.id, field.key);
        }
      }
    }
  }

  Map<String, Map<String, String>> _collectProviders() => {
    for (final spec in ttsProviderSpecs)
      spec.id: {
        for (final field in spec.fields)
          field.key: _controllers[_controllerKey(spec.id, field.key)]!.text,
      },
  };

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// 保存当前表单；成功后重新加载以刷新脱敏密钥与「已配置」状态。
  Future<bool> _save() async {
    final timeout = int.tryParse(_timeout.text.trim());
    if (timeout == null || timeout <= 0) {
      _toast('超时时间请输入正整数（秒）');
      return false;
    }
    final maxChars = int.tryParse(_maxChars.text.trim());
    if (maxChars == null || maxChars <= 0) {
      _toast('最大字数请输入正整数');
      return false;
    }

    setState(() => _saving = true);
    try {
      await _service.save(
        enabled: _enabled,
        provider: _provider,
        timeoutSeconds: timeout,
        maxChars: maxChars,
        providers: _collectProviders(),
      );
      try {
        final settings = await _service.load();
        if (mounted) setState(() => _apply(settings));
      } catch (_) {
        // 刷新失败不影响已保存的结果，保留当前表单即可。
      }
      return true;
    } catch (e) {
      _toast('保存失败：$e');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _onSavePressed() async {
    if (await _save()) _toast('已保存');
  }

  /// 先保存再测试：后端用已保存的配置合成，所以测试前必须先提交表单。
  Future<void> _onTestPressed() async {
    if (_testing || _saving) return;
    if (!await _save()) return;
    if (!mounted) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final result = await _service.test();
      if (!mounted) return;
      setState(() {
        _testOk = result.success;
        _testResult = result.summary;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = '测试失败：$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _section(List<Widget> children) => Material(
    color: Colors.white,
    child: Column(children: children),
  );

  Widget _textRow({
    required Key key,
    required String label,
    required TextEditingController controller,
    String hint = '',
    bool obscure = false,
    TextInputType? keyboardType,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        SizedBox(width: 82, child: Text(label)),
        Expanded(
          child: TextField(
            key: key,
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
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

  /// 下拉字段的当前值：控制器里的值不在选项内（如旧后端返回空）时取第一项。
  String _optionValue(String provider, TtsProviderField field) {
    final text = _controllers[_controllerKey(provider, field.key)]!.text.trim();
    return field.options.contains(text) ? text : field.options.first;
  }

  bool _isHidden(TtsProviderSpec spec, TtsProviderField field) {
    final dependsOn = field.hideWhenKey;
    if (dependsOn == null) return false;
    final other = spec.fields.firstWhere((f) => f.key == dependsOn);
    final value = other.options.isEmpty
        ? _controllers[_controllerKey(spec.id, other.key)]!.text.trim()
        : _optionValue(spec.id, other);
    return value == field.hideWhenValue;
  }

  Widget _optionRow({
    required Key key,
    required String label,
    required TtsProviderField field,
    required String provider,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    child: Row(
      children: [
        SizedBox(width: 82, child: Text(label)),
        Expanded(
          child: DropdownButton<String>(
            key: key,
            value: _optionValue(provider, field),
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final option in field.options)
                DropdownMenuItem<String>(
                  value: option,
                  child: Text(ttsOptionLabels[option] ?? option),
                ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _controllers[_controllerKey(provider, field.key)]!.text = value;
              });
            },
          ),
        ),
      ],
    ),
  );

  Widget _multilineRow({
    required Key key,
    required String label,
    required TextEditingController controller,
    String hint = '',
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        const SizedBox(height: 6),
        TextField(
          key: key,
          controller: controller,
          minLines: 3,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0xFFF7F7F7),
            border: const OutlineInputBorder(borderSide: BorderSide.none),
            hintText: hint,
            hintStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
      ],
    ),
  );

  /// 当前供应商的字段行：[core] 平铺显示，[advanced] 收进「高级请求格式」组。
  ({List<Widget> core, List<Widget> advanced}) _providerFields() {
    final spec = ttsProviderSpecs.firstWhere((s) => s.id == _provider);
    final advancedKeys = _ttsAdvancedFieldKeys[spec.id] ?? const <String>{};
    final coreRows = <Widget>[];
    final advancedRows = <Widget>[];
    for (final field in spec.fields) {
      if (_isHidden(spec, field)) continue;
      final key = _controllerKey(spec.id, field.key);
      final rows = advancedKeys.contains(field.key) ? advancedRows : coreRows;
      if (rows.isNotEmpty) rows.add(const Divider(height: 1, indent: 16));
      if (field.options.isNotEmpty) {
        rows.add(
          _optionRow(
            key: ValueKey('tts-field-$key'),
            label: field.label,
            field: field,
            provider: spec.id,
          ),
        );
        continue;
      }
      if (field.multiline) {
        rows.add(
          _multilineRow(
            key: ValueKey('tts-field-$key'),
            label: field.label,
            controller: _controllers[key]!,
            hint: field.hint,
          ),
        );
        continue;
      }
      var hint = field.hint;
      if (field.secret) {
        final masked = _maskedKeys[key] ?? '';
        hint = masked.isEmpty ? '未设置' : '已设置：$masked（留空保持不变）';
      }
      rows.add(
        _textRow(
          key: ValueKey('tts-field-$key'),
          label: field.label,
          controller: _controllers[key]!,
          hint: hint,
          obscure: field.secret && !_showSecrets,
          keyboardType: field.numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : null,
        ),
      );
    }
    if (spec.help.isNotEmpty) {
      // 帮助文字讲的是请求模板和占位符，有高级组时放进组内。
      (advancedRows.isNotEmpty ? advancedRows : coreRows).add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            spec.help,
            key: const ValueKey('tts-provider-help'),
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF777777),
            ),
          ),
        ),
      );
    }
    return (core: coreRows, advanced: advancedRows);
  }

  /// 「高级请求格式」组的副标题：请求方法与响应类型的当前值。
  String _advancedSummary(TtsProviderSpec spec) {
    final parts = <String>[
      for (final field in spec.fields)
        if (field.options.isNotEmpty &&
            (_ttsAdvancedFieldKeys[spec.id] ?? const <String>{}).contains(
              field.key,
            ))
          _optionValue(spec.id, field),
    ];
    return parts.where((part) => part.isNotEmpty).join(' · ');
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

    final spec = ttsProviderSpecs.firstWhere((s) => s.id == _provider);
    final fields = _providerFields();
    return ListView(
      children: [
        const SizedBox(height: 10),
        _section([
          SwitchListTile(
            key: const ValueKey('tts-enabled'),
            title: const Text('启用语音消息'),
            subtitle: Text(
              _configured ? '角色回复可同时发送语音' : '当前供应商参数尚未配置完整',
              style: const TextStyle(fontSize: 12),
            ),
            value: _enabled,
            activeThumbColor: const Color(0xFF07C160),
            onChanged: (value) => setState(() => _enabled = value),
          ),
        ]),
        const SizedBox(height: 12),
        _section([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SizedBox(
              width: double.infinity,
              // 四个供应商在窄屏上放不下一排分段按钮，用可换行的选择标签。
              child: Wrap(
                key: const ValueKey('tts-provider'),
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final s in ttsProviderSpecs)
                    ChoiceChip(
                      key: ValueKey('tts-provider-${s.id}'),
                      label: Text(s.label),
                      selected: _provider == s.id,
                      showCheckmark: false,
                      selectedColor: const Color(0xFFD9F2E3),
                      onSelected: (_) => setState(() => _provider = s.id),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, indent: 16),
          _textRow(
            key: const ValueKey('tts-timeout'),
            label: '超时(秒)',
            controller: _timeout,
            hint: '单次合成的最长等待时间',
            keyboardType: TextInputType.number,
          ),
          const Divider(height: 1, indent: 16),
          _textRow(
            key: const ValueKey('tts-max-chars'),
            label: '最大字数',
            controller: _maxChars,
            hint: '超过该字数的回复不转语音',
            keyboardType: TextInputType.number,
          ),
        ]),
        const SizedBox(height: 12),
        _section([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${spec.label} 参数',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF888888),
                    ),
                  ),
                ),
                if (spec.fields.any((f) => f.secret))
                  IconButton(
                    tooltip: _showSecrets ? '隐藏密钥' : '显示密钥',
                    onPressed: () =>
                        setState(() => _showSecrets = !_showSecrets),
                    icon: Icon(
                      _showSecrets
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                  ),
              ],
            ),
          ),
          ...fields.core,
          if (fields.advanced.isNotEmpty) ...[
            const Divider(height: 1, indent: 16),
            SettingsGroup(
              title: '高级请求格式',
              icon: Icons.tune,
              subtitle: _advancedSummary(spec),
              children: fields.advanced,
            ),
          ],
        ]),
        const SizedBox(height: 12),
        _section([
          ListTile(
            key: const ValueKey('tts-test'),
            leading: _testing
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.record_voice_over_outlined),
            title: const Text('保存并测试'),
            subtitle: const Text('用当前配置合成一句测试语音'),
            onTap: (_testing || _saving) ? null : _onTestPressed,
          ),
          if (_testResult != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _testResult!,
                  key: const ValueKey('tts-test-result'),
                  style: TextStyle(
                    fontSize: 13,
                    color: _testOk
                        ? const Color(0xFF07C160)
                        : const Color(0xFFE64340),
                  ),
                ),
              ),
            ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Text(
            '密钥只保存在后端，这里仅显示脱敏值；输入新密钥才会覆盖。'
            '角色可在「角色设置」里单独指定音色或关闭语音。',
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
        actions: [
          TextButton(
            key: const ValueKey('tts-save'),
            onPressed: (_loading || _loadError != null || _saving || _testing)
                ? null
                : _onSavePressed,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}
