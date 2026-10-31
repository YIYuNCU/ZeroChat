import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/tts_settings_service.dart';
import '../widgets/settings_group.dart';

/// 各供应商里收进「高级请求格式」折叠组的字段 key（请求模板与响应解析）。
/// 未登记的供应商没有高级字段，全部平铺。
const Map<String, Set<String>> _ttsAdvancedFieldKeys = {
  'custom': {'method', 'headers', 'body', 'response_type', 'response_path'},
};

/// TTS 档案编辑页：档案名称、供应商、超时 / 字数上限与该供应商的参数。
///
/// 密钥只在用户输入了新值时才提交，留空表示保持服务端原值。保存、测试、
/// 设为默认、删除都在本页完成；离开本页后由列表页重新加载。
class TtsProfileEditorPage extends StatefulWidget {
  /// 设置读写服务；默认走 [TtsSettingsService.instance]，测试可注入。
  final TtsSettingsService? service;

  /// 要编辑的档案；新档案用 [TtsProfile.blank]（并设 [isNew]）。
  final TtsProfile profile;

  /// 档案尚未保存到服务端。
  final bool isNew;

  /// 该档案当前是否为默认档案。
  final bool isDefault;

  /// 首次保存时同时设为默认档案（例如这是第一个档案）。
  final bool makeDefaultOnCreate;

  const TtsProfileEditorPage({
    super.key,
    this.service,
    required this.profile,
    this.isNew = false,
    this.isDefault = false,
    this.makeDefaultOnCreate = false,
  });

  @override
  State<TtsProfileEditorPage> createState() => _TtsProfileEditorPageState();
}

class _TtsProfileEditorPageState extends State<TtsProfileEditorPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _timeout = TextEditingController();
  final TextEditingController _maxChars = TextEditingController();

  /// 各供应商字段的输入框，key 为 `<provider>/<field>`。
  final Map<String, TextEditingController> _controllers = {};

  /// 各供应商密钥的脱敏展示值，key 为 `<provider>/<field>`。
  final Map<String, String> _maskedKeys = {};

  bool _saving = false;
  bool _testing = false;
  bool _showSecrets = false;

  late bool _isNew = widget.isNew;
  late bool _isDefault = widget.isDefault;
  bool _configured = false;
  String _provider = ttsProviderSpecs.first.id;

  String? _testResult;
  bool _testOk = false;

  TtsSettingsService get _service =>
      widget.service ?? TtsSettingsService.instance;

  String get _profileId => widget.profile.id;

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
    _apply(widget.profile);
  }

  @override
  void dispose() {
    _name.dispose();
    _timeout.dispose();
    _maxChars.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 把档案写入表单；密钥输入框始终清空，只展示脱敏值作为提示。
  void _apply(TtsProfile profile) {
    _name.text = profile.name;
    _configured = profile.configured;
    _provider = profile.provider;
    _timeout.text = profile.timeoutSeconds.toString();
    _maxChars.text = profile.maxChars.toString();
    for (final spec in ttsProviderSpecs) {
      for (final field in spec.fields) {
        final key = _controllerKey(spec.id, field.key);
        if (field.secret) {
          _controllers[key]!.clear();
          _maskedKeys[key] = profile.valueOf(spec.id, '${field.key}_masked');
        } else if (field.options.isNotEmpty) {
          // 下拉字段的值必须落在选项内，否则提交时会带上空值。
          final value = profile.valueOf(spec.id, field.key).trim();
          _controllers[key]!.text = field.options.contains(value)
              ? value
              : field.options.first;
        } else {
          _controllers[key]!.text = profile.valueOf(spec.id, field.key);
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

  /// 保存当前表单；成功后用服务端返回的最新档案刷新脱敏密钥与「已配置」状态。
  /// [makeDefault] 为 true 时同时把本档案设为默认。
  Future<bool> _save({bool makeDefault = false}) async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('请输入档案名称');
      return false;
    }
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

    final becomeDefault = makeDefault || (_isNew && widget.makeDefaultOnCreate);
    setState(() => _saving = true);
    try {
      var settings = await _service.update(
        defaultProfileId: becomeDefault ? _profileId : null,
        profiles: [
          TtsSettingsService.buildProfileUpdate(
            id: _profileId,
            name: name,
            provider: _provider,
            timeoutSeconds: timeout,
            maxChars: maxChars,
            providers: _collectProviders(),
          ),
        ],
      );
      _isNew = false;
      if (becomeDefault) _isDefault = true;
      if (settings == null) {
        try {
          settings = await _service.load();
        } catch (_) {
          // 刷新失败不影响已保存的结果，保留当前表单即可。
        }
      }
      final saved = settings?.profileById(_profileId);
      if (saved != null && mounted) {
        setState(() {
          _apply(saved);
          _isDefault = settings!.defaultProfileId == _profileId;
        });
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

  /// 先保存再测试：后端用已保存的档案合成，所以测试前必须先提交表单。
  Future<void> _onTestPressed() async {
    if (_testing || _saving) return;
    if (!await _save()) return;
    if (!mounted) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final result = await _service.test(profileId: _profileId);
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

  Future<void> _onSetDefaultPressed() async {
    if (_testing || _saving) return;
    if (await _save(makeDefault: true)) _toast('已设为默认档案');
  }

  Future<void> _onDeletePressed() async {
    if (_testing || _saving) return;
    final name = _name.text.trim().isEmpty ? '未命名' : _name.text.trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除档案'),
        content: Text(
          _isNew
              ? '放弃新建的档案「$name」？'
              : '确定删除档案「$name」吗？使用它的角色会改用默认档案'
                    '${_isDefault ? '；它是当前的默认档案，删除后将由第一个剩余档案接替' : ''}。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('tts-delete-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE64340))),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_isNew) {
      Navigator.pop(context);
      return;
    }
    setState(() => _saving = true);
    try {
      await _service.update(deleteProfileIds: [_profileId]);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      _toast('删除失败：$e');
      if (mounted) setState(() => _saving = false);
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
    List<TextInputFormatter>? inputFormatters,
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
            inputFormatters: inputFormatters,
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

  /// 下拉字段的当前值：控制器里的值不在选项内时取第一项。
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
    final spec = ttsProviderSpecs.firstWhere((s) => s.id == _provider);
    final fields = _providerFields();
    final busy = _testing || _saving;
    return ListView(
      children: [
        const SizedBox(height: 10),
        _section([
          _textRow(
            key: const ValueKey('tts-profile-name'),
            label: '档案名称',
            controller: _name,
            hint: '例如：日常 / 角色专用',
            inputFormatters: [LengthLimitingTextInputFormatter(40)],
          ),
        ]),
        const SizedBox(height: 12),
        _section([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SizedBox(
              width: double.infinity,
              // 供应商在窄屏上放不下一排分段按钮，用可换行的选择标签。
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
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    _configured ? '已配置' : '未配置',
                    key: const ValueKey('tts-configured'),
                    style: TextStyle(
                      fontSize: 12,
                      color: _configured
                          ? const Color(0xFF07C160)
                          : const Color(0xFFE6A23C),
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
            onTap: busy ? null : _onTestPressed,
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
        const SizedBox(height: 12),
        _section([
          if (_isDefault)
            const ListTile(
              key: ValueKey('tts-is-default'),
              leading: Icon(Icons.check_circle, color: Color(0xFF07C160)),
              title: Text('当前为默认档案'),
              subtitle: Text('未指定档案的角色使用它'),
            )
          else
            ListTile(
              key: const ValueKey('tts-set-default'),
              leading: const Icon(Icons.star_outline),
              title: const Text('设为默认档案'),
              subtitle: const Text('同时保存当前修改'),
              onTap: busy ? null : _onSetDefaultPressed,
            ),
          const Divider(height: 1, indent: 16),
          ListTile(
            key: const ValueKey('tts-delete'),
            leading: const Icon(
              Icons.delete_outline,
              color: Color(0xFFE64340),
            ),
            title: Text(
              _isNew ? '放弃新档案' : '删除档案',
              style: const TextStyle(color: Color(0xFFE64340)),
            ),
            onTap: busy ? null : _onDeletePressed,
          ),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Text(
            '密钥只保存在后端，这里仅显示脱敏值；输入新密钥才会覆盖。'
            '角色可在「角色设置」里选择使用哪个档案，或单独指定音色。',
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
        title: Text(_isNew ? '添加档案' : '编辑档案'),
        actions: [
          TextButton(
            key: const ValueKey('tts-save'),
            onPressed: (_saving || _testing) ? null : _onSavePressed,
            child: const Text('保存'),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}
