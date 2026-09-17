import '../widgets/prompt_editor.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/ai_model_profile.dart';
import '../models/provider_quiet_rule.dart';
import '../models/summary_config.dart';
import '../services/role_service.dart';
import '../services/secure_backend_client.dart';
import '../services/secure_websocket_client.dart';
import '../services/settings_service.dart';
import '../widgets/quiet_rule_editor.dart';

class ApiSettingsPage extends StatelessWidget {
  const ApiSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const _ApiSettingsOverview();
}

class _ApiSettingsOverview extends StatefulWidget {
  const _ApiSettingsOverview();

  @override
  State<_ApiSettingsOverview> createState() => _ApiSettingsOverviewState();
}

class _ApiSettingsOverviewState extends State<_ApiSettingsOverview> {
  @override
  void initState() {
    super.initState();
    SettingsService.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    SettingsService.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('AI 接口设置'),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),
          _Section(
            children: [
              _NavigationRow(
                icon: Icons.dns_outlined,
                title: '后端连接',
                subtitle: settings.backendUrl.isEmpty
                    ? '未配置'
                    : settings.backendUrl,
                onTap: () => _push(context, const BackendConnectionPage()),
              ),
            ],
          ),
          const _SectionGap(),
          _Section(
            children: [
              _NavigationRow(
                icon: Icons.chat_bubble_outline,
                title: '默认聊天模型',
                subtitle: _modelSummary(
                  settings.chatModel,
                  settings.chatApiUrl,
                ),
                onTap: () => _push(
                  context,
                  const ModelSettingsPage(kind: ModelSettingsKind.chat),
                ),
              ),
              const Divider(height: 1, indent: 56),
              _NavigationRow(
                icon: Icons.psychology_outlined,
                title: '意图识别模型',
                subtitle: _featureSummary(
                  settings.intentEnabled,
                  settings.intentModel,
                  settings.intentApiUrl,
                ),
                onTap: () => _push(
                  context,
                  const ModelSettingsPage(kind: ModelSettingsKind.intent),
                ),
              ),
              const Divider(height: 1, indent: 56),
              _NavigationRow(
                icon: Icons.visibility_outlined,
                title: '视觉识别模型',
                subtitle: _featureSummary(
                  settings.visionEnabled,
                  settings.visionModel,
                  settings.visionApiUrl,
                ),
                onTap: () => _push(
                  context,
                  const ModelSettingsPage(kind: ModelSettingsKind.vision),
                ),
              ),
              const Divider(height: 1, indent: 56),
              _NavigationRow(
                icon: Icons.memory_outlined,
                title: '向量记忆模型',
                subtitle: _featureSummary(
                  settings.embeddingEnabled,
                  settings.embeddingModel,
                  settings.embeddingApiUrl,
                ),
                onTap: () => _push(
                  context,
                  const ModelSettingsPage(kind: ModelSettingsKind.embedding),
                ),
              ),
            ],
          ),
          const _SectionGap(),
          _Section(
            children: [
              _NavigationRow(
                icon: Icons.history_toggle_off,
                title: SummaryFeature.context.title,
                subtitle: _summarySummary(settings.contextSummaryConfig),
                onTap: () => _push(
                  context,
                  const SummaryModelSettingsPage(
                    feature: SummaryFeature.context,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 56),
              _NavigationRow(
                icon: Icons.psychology_alt_outlined,
                title: SummaryFeature.coreMemory.title,
                subtitle: _summarySummary(settings.coreMemorySummaryConfig),
                onTap: () => _push(
                  context,
                  const SummaryModelSettingsPage(
                    feature: SummaryFeature.coreMemory,
                  ),
                ),
              ),
              const Divider(height: 1, indent: 56),
              _NavigationRow(
                icon: Icons.article_outlined,
                title: '系统提示词',
                subtitle: _promptsSubtitle(),
                onTap: () => _push(context, const PromptsPage()),
              ),
            ],
          ),
          const _SectionGap(),
          _Section(
            children: [
              _NavigationRow(
                icon: Icons.bookmarks_outlined,
                title: '模型档案管理',
                subtitle:
                    '${settings.modelProfilesFor(ModelProfileCapability.chat).length} 个聊天档案，${settings.modelProfilesFor(ModelProfileCapability.intent).length} 个意图档案',
                onTap: () => _push(context, const ModelProfilesPage()),
              ),
              const Divider(height: 1, indent: 56),
              _NavigationRow(
                icon: Icons.bedtime_outlined,
                title: '模型安静时间',
                subtitle: '${settings.providerQuietRules.length} 条规则',
                onTap: () => _push(context, const ProviderQuietRulesPage()),
              ),
            ],
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

String _modelSummary(String model, String url) => url.trim().isEmpty
    ? '未配置'
    : model.trim().isEmpty
    ? url
    : model;

String _featureSummary(bool enabled, String model, String url) {
  if (!enabled) return '未启用';
  return _modelSummary(model, url);
}

String _summarySummary(SummaryApiConfig config) {
  if (!config.enabled) return '未启用';
  if (config.apiUrl.trim().isEmpty && config.model.trim().isEmpty) {
    return '使用默认聊天模型';
  }
  return _modelSummary(config.model, config.apiUrl);
}

void _push(BuildContext context, Widget page) {
  Navigator.push(context, MaterialPageRoute(builder: (_) => page));
}

class BackendConnectionPage extends StatefulWidget {
  const BackendConnectionPage({super.key});

  @override
  State<BackendConnectionPage> createState() => _BackendConnectionPageState();
}

class _BackendConnectionPageState extends State<BackendConnectionPage> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _secret;
  bool _testing = false;
  bool _pulling = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;
    _url = TextEditingController(text: settings.backendUrl);
    _token = TextEditingController(text: settings.backendAuthToken);
    _secret = TextEditingController(text: settings.backendEncryptionSecret);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _saveLocal() async {
    final settings = SettingsService.instance;
    await settings.updateBackendUrl(_url.text.trim());
    await settings.updateBackendSecurity(
      authToken: _token.text.trim(),
      encryptionSecret: _secret.text.trim(),
    );
  }

  Future<void> _test() async {
    if (_url.text.trim().isEmpty) {
      _showMessage(context, '请输入服务器地址');
      return;
    }
    setState(() => _testing = true);
    try {
      await _saveLocal();
      await SecureWebSocketClient.instance.close();
      final response = await SecureWebSocketClient.instance.request(
        'health',
        const <String, dynamic>{},
        timeout: const Duration(seconds: 5),
      );
      if (response['status']?.toString() != 'healthy') {
        throw Exception('后端健康检查失败');
      }
      unawaited(RoleService.fetchFromBackend());
      if (mounted) setState(() => _result = '连接成功');
    } catch (error) {
      if (mounted) setState(() => _result = '连接失败: $error');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pull() async {
    setState(() => _pulling = true);
    try {
      await _saveLocal();
      await SecureWebSocketClient.instance.close();
      final ok = await SettingsService.instance.syncAllSettingsFromBackend();
      if (!ok) throw Exception('后端未返回有效配置');
      if (mounted) _showMessage(context, '已从后端拉取配置');
    } catch (error) {
      if (mounted) _showMessage(context, '拉取失败: $error');
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFEDEDED),
    appBar: AppBar(
      backgroundColor: const Color(0xFFEDEDED),
      elevation: 0,
      title: const Text('后端连接'),
      actions: [TextButton(onPressed: _saveLocal, child: const Text('保存'))],
    ),
    body: ListView(
      children: [
        const _PageHint('Token 与传输密钥仅保存在当前设备，不会覆盖服务端安全配置。'),
        _Section(
          children: [
            _FieldRow(
              label: '服务器地址',
              controller: _url,
              hint: 'http://localhost:8000',
            ),
            const Divider(height: 1),
            _FieldRow(
              label: 'Token',
              controller: _token,
              hint: '后端鉴权 Token',
              obscure: true,
            ),
            const Divider(height: 1),
            _FieldRow(
              label: '传输密钥',
              controller: _secret,
              hint: '后端传输加密密钥',
              obscure: true,
            ),
          ],
        ),
        const _SectionGap(),
        _Section(
          children: [
            _ActionRow(
              icon: Icons.network_check_outlined,
              label: _testing ? '测试中...' : '测试连接',
              busy: _testing,
              onTap: _testing ? null : _test,
            ),
            const Divider(height: 1),
            _ActionRow(
              icon: Icons.cloud_sync_outlined,
              label: _pulling ? '拉取中...' : '从后端拉取全部配置',
              busy: _pulling,
              onTap: _pulling ? null : _pull,
            ),
          ],
        ),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _result!,
              style: const TextStyle(color: Color(0xFF666666)),
            ),
          ),
      ],
    ),
  );
}

enum ModelSettingsKind { chat, intent, vision, embedding }

extension on ModelSettingsKind {
  String get title => switch (this) {
    ModelSettingsKind.chat => '默认聊天模型',
    ModelSettingsKind.intent => '意图识别模型',
    ModelSettingsKind.vision => '视觉识别模型',
    ModelSettingsKind.embedding => '向量记忆模型',
  };

  ModelProfileCapability get capability => switch (this) {
    ModelSettingsKind.chat => ModelProfileCapability.chat,
    ModelSettingsKind.intent => ModelProfileCapability.intent,
    ModelSettingsKind.vision => ModelProfileCapability.vision,
    ModelSettingsKind.embedding => ModelProfileCapability.embedding,
  };

  bool get hasToggle => this != ModelSettingsKind.chat;
  bool get hasFormat => this != ModelSettingsKind.embedding;
  bool get hasVisionMode => this == ModelSettingsKind.vision;
}

class ModelSettingsPage extends StatefulWidget {
  final ModelSettingsKind kind;
  const ModelSettingsPage({super.key, required this.kind});

  @override
  State<ModelSettingsPage> createState() => _ModelSettingsPageState();
}

class ModelProfilesPage extends StatefulWidget {
  const ModelProfilesPage({super.key});

  @override
  State<ModelProfilesPage> createState() => _ModelProfilesPageState();
}

class _ModelProfilesPageState extends State<ModelProfilesPage> {
  ModelProfileCapability? _filter;

  Future<void> _edit([ModelApiProfile? existing]) async {
    final result = await _showProfileEditor(context, existing: existing);
    if (result == null) return;
    final roleIds = SettingsService.instance
        .roleIdsUsingModelProfile(result.id)
        .toList();
    await SettingsService.instance.saveApiProfile(result);
    await RoleService.updateModelProfileContextLength(
      roleIds,
      result.maxContextLength,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final all = SettingsService.instance.modelProfilesFor;
    final profiles = _filter == null
        ? ModelProfileCapability.values.expand(all).toSet().toList()
        : all(_filter!);
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('模型档案管理'),
        actions: [
          IconButton(
            tooltip: '新建档案',
            onPressed: () => _edit(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 54,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
                for (final capability in ModelProfileCapability.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      label: Text(_capabilityLabel(capability)),
                      selected: _filter == capability,
                      onSelected: (_) => setState(() => _filter = capability),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: profiles.isEmpty
                ? const Center(child: Text('暂无模型档案'))
                : ListView.separated(
                    itemCount: profiles.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final profile = profiles[index];
                      return Material(
                        color: Colors.white,
                        child: ListTile(
                          title: Text(profile.name),
                          subtitle: Text(
                            '${profile.model} | ${profile.capabilities.map(_capabilityLabel).join('、')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: '编辑档案',
                                onPressed: () => _edit(profile),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: '删除档案',
                                onPressed: () async {
                                  final roleIds = SettingsService.instance
                                      .roleIdsUsingModelProfile(profile.id)
                                      .toList();
                                  await SettingsService.instance
                                      .deleteModelProfile(profile.id);
                                  await RoleService.updateModelProfileContextLength(
                                    roleIds,
                                    null,
                                  );
                                  if (mounted) setState(() {});
                                },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class ProviderQuietRulesPage extends StatefulWidget {
  const ProviderQuietRulesPage({super.key});

  @override
  State<ProviderQuietRulesPage> createState() => _ProviderQuietRulesPageState();
}

class _ProviderQuietRulesPageState extends State<ProviderQuietRulesPage> {
  List<({String name, String url, String model})> _targets() {
    final settings = SettingsService.instance;
    final targets = <({String name, String url, String model})>[
      (name: '当前聊天模型', url: settings.chatApiUrl, model: settings.chatModel),
    ];
    final seen = <String>{'${settings.chatApiUrl}|${settings.chatModel}'};
    for (final profile in ModelProfileCapability.values.expand(
      settings.modelProfilesFor,
    )) {
      final key = '${profile.apiUrl}|${profile.model}';
      if (profile.apiUrl.isNotEmpty &&
          profile.model.isNotEmpty &&
          seen.add(key)) {
        targets.add((
          name: profile.name,
          url: profile.apiUrl,
          model: profile.model,
        ));
      }
    }
    return targets;
  }

  Future<void> _editTarget(String url, String model) async {
    if (url.isEmpty || model.isEmpty) {
      _showMessage(context, '请先配置 API 地址和模型');
      return;
    }
    final all = SettingsService.instance.providerQuietRules;
    final existing = all
        .where((rule) => ProviderQuietRule.matches(rule, url, model))
        .toList();
    final edited = await showQuietRuleEditor(
      context,
      initialRules: existing.map((rule) => rule.toRule()).toList(),
    );
    if (edited == null) return;
    final updated = edited
        .map(
          (rule) => ProviderQuietRule.fromRuleAndTarget(
            rule: rule,
            apiUrl: url,
            model: model,
          ),
        )
        .toList();
    await SettingsService.instance.updateProviderQuietRules([
      ...all.where((rule) => !ProviderQuietRule.matches(rule, url, model)),
      ...updated,
    ]);
    final synced = await SettingsService.instance.syncApiSettingsToBackend();
    if (mounted) {
      setState(() {});
      _showMessage(context, synced ? '规则已保存' : '规则已本地保存，后端同步失败');
    }
  }

  Future<void> _addCustom() async {
    final url = TextEditingController();
    final model = TextEditingController();
    final target = await showDialog<({String url, String model})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义模型'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: url,
              decoration: const InputDecoration(labelText: 'API 地址'),
            ),
            TextField(
              controller: model,
              decoration: const InputDecoration(labelText: '模型'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, (
              url: url.text.trim(),
              model: model.text.trim(),
            )),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    url.dispose();
    model.dispose();
    if (target != null &&
        target.url.isNotEmpty &&
        target.model.isNotEmpty &&
        mounted) {
      await _editTarget(target.url, target.model);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = SettingsService.instance.providerQuietRules;
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('模型安静时间'),
        actions: [
          IconButton(
            tooltip: '添加自定义模型',
            onPressed: _addCustom,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        children: [
          const _PageHint('规则按 API 地址和模型生效，仅限制角色的自主消息、互动和自动回复。'),
          _Section(
            children: [
              for (final target in _targets()) ...[
                ListTile(
                  title: Text(target.name),
                  subtitle: Text(
                    rules
                            .where(
                              (rule) => ProviderQuietRule.matches(
                                rule,
                                target.url,
                                target.model,
                              ),
                            )
                            .map((rule) => rule.label)
                            .join('；')
                            .isEmpty
                        ? '未设置'
                        : rules
                              .where(
                                (rule) => ProviderQuietRule.matches(
                                  rule,
                                  target.url,
                                  target.model,
                                ),
                              )
                              .map((rule) => rule.label)
                              .join('；'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => _editTarget(target.url, target.model),
                ),
                const Divider(height: 1),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class SummaryModelSettingsPage extends StatefulWidget {
  final SummaryFeature feature;
  const SummaryModelSettingsPage({super.key, required this.feature});

  @override
  State<SummaryModelSettingsPage> createState() =>
      _SummaryModelSettingsPageState();
}

class _SummaryModelSettingsPageState extends State<SummaryModelSettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  late final TextEditingController _temperature;
  late final TextEditingController _timeout;
  late final TextEditingController _effort;
  late final TextEditingController _budget;
  late final TextEditingController _systemPrompt;
  late bool _enabled;
  late String _format;
  bool? _thinkingEnabled;
  String? _profileId;
  bool _saving = false;

  SummaryApiConfig get _config =>
      SettingsService.instance.summaryConfigFor(widget.feature);

  /// 总结是纯文本生成，可选档案复用「聊天」能力档案。
  List<ModelApiProfile> get _chatProfiles =>
      SettingsService.instance.modelProfilesFor(ModelProfileCapability.chat);

  ModelApiProfile? _profileById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final profile in _chatProfiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// 选中的档案只有在地址/模型仍与表单一致时才算生效，
  /// 手动改过其中之一即视为脱离档案（与其它模型设置页一致）。
  String? get _effectiveProfileId {
    final profile = _profileById(_profileId);
    if (profile == null) return null;
    if (profile.apiUrl != _url.text.trim() ||
        profile.model != _model.text.trim()) {
      return null;
    }
    return profile.id;
  }

  void _applyProfile(String? id) {
    final profile = _profileById(id);
    if (profile == null) return;
    setState(() {
      _profileId = profile.id;
      _url.text = profile.apiUrl;
      _key.text = profile.apiKey;
      _model.text = profile.model;
      _format = profile.apiFormat;
      _timeout.text =
          (profile.timeoutSeconds ??
                  SettingsService.instance.chatTimeoutSeconds)
              .toString();
      _effort.text = profile.reasoningEffort ?? '';
      _thinkingEnabled = profile.thinkingEnabled;
      _budget.text = profile.thinkingBudget?.toString() ?? '';
    });
  }

  Future<void> _saveAsProfile() async {
    if (_url.text.trim().isEmpty || _model.text.trim().isEmpty) {
      _showMessage(context, '请先填写 API 地址和模型');
      return;
    }
    final name = await _askProfileName(context, _model.text.trim());
    if (name == null || name.isEmpty) return;
    final id = 'model_profile_${DateTime.now().microsecondsSinceEpoch}';
    await SettingsService.instance.saveApiProfile(
      ModelApiProfile(
        id: id,
        name: name,
        apiUrl: _url.text.trim(),
        model: _model.text.trim(),
        apiKey: _key.text.trim(),
        apiFormat: _format,
        capabilities: {ModelProfileCapability.chat},
        timeoutSeconds: int.tryParse(_timeout.text.trim())?.clamp(1, 3600),
        reasoningEffort: _effort.text.trim().isEmpty
            ? null
            : _effort.text.trim(),
        thinkingEnabled: _thinkingEnabled,
        thinkingBudget: normalizeThinkingBudget(_budget.text.trim()),
      ),
    );
    if (mounted) setState(() => _profileId = id);
  }

  @override
  void initState() {
    super.initState();
    final config = SettingsService.instance.applyBoundProfile(_config.copy());
    _enabled = config.enabled;
    _url = TextEditingController(text: config.apiUrl);
    _key = TextEditingController(text: config.apiKey);
    _model = TextEditingController(text: config.model);
    _format = config.apiFormat;
    _temperature = TextEditingController(text: '${config.temperature}');
    _timeout = TextEditingController(text: '${config.timeoutSeconds}');
    _effort = TextEditingController(text: config.reasoningEffort);
    _thinkingEnabled = config.thinkingEnabled;
    _budget = TextEditingController(
      text: config.thinkingBudget?.toString() ?? '',
    );
    _systemPrompt = TextEditingController(text: config.systemPrompt);
    _profileId = _profileById(config.profileId)?.id;
    SettingsService.instance.loadPromptRegistry().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    for (final controller in [
      _url,
      _key,
      _model,
      _temperature,
      _timeout,
      _effort,
      _budget,
      _systemPrompt,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 当前功能在提示词注册表里的条目（事件总结 / 核心记忆总结各一条）。
  ConfigurablePrompt? get _promptDefinition {
    for (final prompt in SettingsService.instance.promptRegistry.values) {
      if (!prompt.isSummary) continue;
      final matchesFeature = widget.feature == SummaryFeature.context
          ? prompt.id.contains('context')
          : prompt.id.contains('core_memory');
      if (matchesFeature) return prompt;
    }
    return null;
  }

  String get _builtinPrompt => _promptDefinition?.builtin ?? '';

  /// 完整覆盖内置提示词：可选全局默认，或只针对当前绑定的模型档案微调
  /// （与服务端 `model_prompt_overrides["<url>|<model>"]` 对应）。
  Future<void> _editPrompt() async {
    final prompt = _promptDefinition;
    if (prompt == null) {
      _showMessage(context, '提示词尚未加载，请稍后重试');
      return;
    }
    final profile = _profileById(_effectiveProfileId);
    final scope = await _askPromptScope(context, profile: profile);
    if (!mounted) return;
    if (scope == null) return;

    if (scope == _PromptScope.profile && profile != null) {
      final overrides = _copyOverrides(profile.promptOverrides);
      final edited = await showPromptEditor(
        context,
        prompt: prompt,
        current: overrides[prompt.id] ?? const {},
        scopeLabel: profile.name,
      );
      if (!mounted) return;
      if (edited == null) return;
      if (edited.isEmpty) {
        overrides.remove(prompt.id);
      } else {
        overrides[prompt.id] = edited;
      }
      await SettingsService.instance.saveApiProfile(
        ModelApiProfile(
          id: profile.id,
          name: profile.name,
          apiUrl: profile.apiUrl,
          model: profile.model,
          apiKey: profile.apiKey,
          apiFormat: profile.apiFormat,
          capabilities: profile.capabilities,
          visionMode: profile.visionMode,
          timeoutSeconds: profile.timeoutSeconds,
          reasoningEffort: profile.reasoningEffort,
          thinkingEnabled: profile.thinkingEnabled,
          thinkingBudget: profile.thinkingBudget,
          stream: profile.stream,
          maxContextLength: profile.maxContextLength,
          promptOverrides: overrides,
        ),
      );
    } else {
      final overrides = _copyOverrides(
        SettingsService.instance.promptOverrides,
      );
      final edited = await showPromptEditor(
        context,
        prompt: prompt,
        current: overrides[prompt.id] ?? const {},
        scopeLabel: '全局默认',
      );
      if (!mounted) return;
      if (edited == null) return;
      if (edited.isEmpty) {
        overrides.remove(prompt.id);
      } else {
        overrides[prompt.id] = edited;
      }
      await SettingsService.instance.updatePromptOverrides(overrides);
    }

    final synced = await SettingsService.instance.syncApiSettingsToBackend();
    if (mounted) {
      setState(() {});
      _showMessage(context, synced ? '提示词已保存' : '已本地保存，后端同步失败');
    }
  }

  Future<void> _save() async {
    final temperature = double.tryParse(_temperature.text.trim()) ?? 0.1;
    final timeout = int.tryParse(_timeout.text.trim()) ?? 60;
    final budget = int.tryParse(_budget.text.trim());
    final apiKey = _key.text.trim();
    setState(() => _saving = true);
    try {
      await SettingsService.instance.updateSummaryConfig(
        widget.feature,
        SummaryApiConfig(
          enabled: _enabled,
          apiUrl: _url.text.trim(),
          apiKey: apiKey,
          apiKeyMasked: apiKey.isEmpty ? _config.apiKeyMasked : '',
          model: _model.text.trim(),
          apiFormat: _format,
          temperature: temperature.clamp(0.0, 2.0).toDouble(),
          timeoutSeconds: timeout.clamp(1, 3600),
          reasoningEffort: _effort.text.trim(),
          thinkingEnabled: _thinkingEnabled,
          thinkingBudget: budget != null && budget > 0 ? budget : null,
          systemPrompt: _systemPrompt.text.trim(),
          profileId: _effectiveProfileId,
        ),
      );
      final synced = await SettingsService.instance.syncApiSettingsToBackend();
      if (!mounted) return;
      _showMessage(context, synced ? '已保存' : '已保存到本地，后端同步失败，可稍后重试');
    } catch (_) {
      if (mounted) _showMessage(context, '设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final builtin = _builtinPrompt;
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: Text(widget.feature.title),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存'),
          ),
        ],
      ),
      body: ListView(
        children: [
          _PageHint(
            '${widget.feature.description}。未绑定模型档案时，留空的 API 配置将回退到默认聊天模型；'
            '这两个总结功能独立于角色，不再需要配置总结助手角色。',
          ),
          _Section(
            children: [
              SwitchListTile(
                title: const Text('启用'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
            ],
          ),
          const _SectionGap(),
          _Section(
            children: [
              _ProfileSelector(
                value: _profileId,
                profiles: _chatProfiles,
                onChanged: _applyProfile,
              ),
              const Divider(height: 1),
              _ActionRow(
                icon: Icons.bookmark_add_outlined,
                label: '把当前配置保存为模型档案',
                onTap: _saveAsProfile,
              ),
            ],
          ),
          const _SectionGap(),
          _Section(
            children: [
              _FieldRow(
                label: 'API 地址',
                controller: _url,
                hint: '留空使用默认聊天 API',
              ),
              _FieldRow(
                label: 'API Key',
                controller: _key,
                hint: '留空使用默认聊天 API',
                obscure: true,
              ),
              _FieldRow(label: '模型', controller: _model, hint: '留空使用默认聊天模型'),
              _FormatSelector(
                value: _format,
                onChanged: (value) => setState(() => _format = value),
              ),
              _FieldRow(
                label: '温度',
                controller: _temperature,
                hint: '0 - 2，总结建议 0.1',
              ),
              _FieldRow(label: '超时时间（秒）', controller: _timeout, hint: '默认 60'),
            ],
          ),
          const _SectionGap(),
          _Section(
            children: [
              _FieldRow(label: '推理强度', controller: _effort, hint: '留空继承默认聊天模型'),
              _FieldRow(label: '思考预算', controller: _budget, hint: '留空继承默认聊天模型'),
            ],
          ),
          const _SectionGap(),
          _PageHint(
            '系统提示词：留空使用内置提示词。填写后将追加在内置提示词之后，'
            '便于补充输出格式要求。需要整体改写内置提示词时，用下面的'
            '「编辑提示词」。',
          ),
          _Section(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _systemPrompt,
                  maxLines: 8,
                  minLines: 4,
                  decoration: const InputDecoration(
                    labelText: '附加系统提示词（可选）',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (builtin.isNotEmpty) ...[
                const Divider(height: 1),
                ListTile(
                  title: const Text('编辑提示词'),
                  subtitle: Text(
                    _promptDefinition == null
                        ? '提示词加载中…'
                        : '覆盖内置提示词（${_promptDefinition!.id}）',
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: _promptDefinition == null ? null : _editPrompt,
                ),
                ListTile(
                  title: const Text('查看内置提示词'),
                  subtitle: const Text('只读'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () => _showBuiltinPrompt(context, builtin),
                ),
              ],
            ],
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

/// 提示词覆盖的作用域：全局默认，或单个模型档案。
enum _PromptScope { global, profile }

Future<_PromptScope?> _askPromptScope(
  BuildContext context, {
  ModelApiProfile? profile,
}) async {
  if (profile == null) return _PromptScope.global;
  return showDialog<_PromptScope>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('编辑哪一级提示词'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, _PromptScope.global),
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('全局默认'),
            subtitle: Text('对所有模型生效'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, _PromptScope.profile),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('档案：${profile.name}'),
            subtitle: Text(
              '只对 ${profile.model} 生效',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 系统提示词入口的摘要：同时反映全局覆盖与按档案微调。
String _promptsSubtitle() {
  final settings = SettingsService.instance;
  final global = settings.promptOverrides.length;
  final profiles = settings.modelPromptOverridesForSync().length;
  if (global == 0 && profiles == 0) return '使用内置提示词';
  return [
    if (global > 0) '全局 $global 项',
    if (profiles > 0) '$profiles 个档案微调',
  ].join('，');
}

/// 系统提示词的作用域选择器：默认（全局）或某一个模型档案，一次只显示一个。
class _PromptScopeSelector extends StatelessWidget {
  final String? value;
  final List<ModelApiProfile> profiles;
  final ValueChanged<String?> onChanged;

  const _PromptScopeSelector({
    required this.value,
    required this.profiles,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        const SizedBox(width: 82, child: Text('作用范围')),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              value: profiles.any((item) => item.id == value) ? value : null,
              isExpanded: true,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('默认（全局）'),
                ),
                for (final profile in profiles)
                  DropdownMenuItem<String?>(
                    value: profile.id,
                    child: Text(
                      '档案：${profile.name}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    ),
  );
}

void _showBuiltinPrompt(BuildContext context, String text) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('内置提示词'),
      content: SingleChildScrollView(child: SelectableText(text)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 提示词编辑页：全局默认覆盖 + 按模型档案微调。
class PromptsPage extends StatefulWidget {
  const PromptsPage({super.key});

  @override
  State<PromptsPage> createState() => _PromptsPageState();
}

class _PromptsPageState extends State<PromptsPage> {
  bool _loading = true;
  String? _error;

  /// 当前显示的作用域：`null` 表示全局默认，否则是模型档案 id。
  /// 一次只显示一个作用域，避免全局与其下所有档案的提示词同时铺满页面。
  String? _scopeProfileId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SettingsService.instance.loadPromptRegistry(force: true);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  List<ModelApiProfile> get _profiles => ModelProfileCapability.values
      .expand(SettingsService.instance.modelProfilesFor)
      .toSet()
      .toList();

  /// 当前选中的档案；未选（全局默认）或档案已被删除时返回 null。
  ModelApiProfile? get _selectedProfile {
    final id = _scopeProfileId;
    if (id == null) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Widget _scopeSubtitle() {
    final profile = _selectedProfile;
    final overrides = profile == null
        ? SettingsService.instance.promptOverrides
        : profile.promptOverrides;
    final count = overrides.length;
    return ListTile(
      dense: true,
      title: Text(
        profile == null
            ? '全局默认：未单独配置档案时使用'
            : '${profile.model} | ${profile.apiUrl}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
      ),
      trailing: count == 0
          ? null
          : Text(
              '已自定义 $count 项',
              style: const TextStyle(fontSize: 12, color: Color(0xFF07C160)),
            ),
    );
  }

  bool _isOverridden(ConfigurablePrompt prompt) {
    final profile = _selectedProfile;
    final overrides = profile == null
        ? SettingsService.instance.promptOverrides
        : profile.promptOverrides;
    return (overrides[prompt.id] ?? const {}).isNotEmpty;
  }

  Future<void> _editScoped(ConfigurablePrompt prompt) async {
    final profile = _selectedProfile;
    if (profile == null) {
      await _editGlobal(prompt);
    } else {
      await _editProfile(profile, prompt);
    }
  }

  Future<void> _editGlobal(ConfigurablePrompt prompt) async {
    final overrides = _copyOverrides(SettingsService.instance.promptOverrides);
    final edited = await showPromptEditor(
      context,
      prompt: prompt,
      current: overrides[prompt.id] ?? const {},
      scopeLabel: '全局默认',
    );
    if (edited == null) return;
    if (edited.isEmpty) {
      overrides.remove(prompt.id);
    } else {
      overrides[prompt.id] = edited;
    }
    await SettingsService.instance.updatePromptOverrides(overrides);
    final synced = await SettingsService.instance.syncApiSettingsToBackend();
    if (mounted) {
      setState(() {});
      _showMessage(context, synced ? '提示词已保存' : '已本地保存，后端同步失败');
    }
  }

  Future<void> _editProfile(
    ModelApiProfile profile,
    ConfigurablePrompt prompt,
  ) async {
    final overrides = _copyOverrides(profile.promptOverrides);
    final edited = await showPromptEditor(
      context,
      prompt: prompt,
      current: overrides[prompt.id] ?? const {},
      scopeLabel: profile.name,
    );
    if (edited == null) return;
    if (edited.isEmpty) {
      overrides.remove(prompt.id);
    } else {
      overrides[prompt.id] = edited;
    }
    await SettingsService.instance.saveApiProfile(
      ModelApiProfile(
        id: profile.id,
        name: profile.name,
        apiUrl: profile.apiUrl,
        model: profile.model,
        apiKey: profile.apiKey,
        apiFormat: profile.apiFormat,
        capabilities: profile.capabilities,
        visionMode: profile.visionMode,
        timeoutSeconds: profile.timeoutSeconds,
        reasoningEffort: profile.reasoningEffort,
        thinkingEnabled: profile.thinkingEnabled,
        thinkingBudget: profile.thinkingBudget,
        stream: profile.stream,
        maxContextLength: profile.maxContextLength,
        promptOverrides: overrides,
      ),
    );
    final synced = await SettingsService.instance.syncApiSettingsToBackend();
    if (mounted) {
      setState(() {});
      _showMessage(context, synced ? '提示词已保存' : '已本地保存，后端同步失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final registry = SettingsService.instance.promptRegistry;
    // 只列聊天系统提示词：两个记忆总结的提示词属于各自功能页，不在这里重复出现。
    final prompts =
        registry.values
            .where((prompt) => prompt.appliesTo.contains('chat'))
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('系统提示词'),
        actions: [
          IconButton(
            tooltip: '重新加载',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('加载失败：$_error', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              ),
            )
          : ListView(
              children: [
                const _PageHint(
                  '提示词按「内置默认 → 全局覆盖 → 模型档案微调」的顺序生效；'
                  '留空表示沿用上一级内容。修改会同步到服务端并在下一次请求生效。\n'
                  '用上方「作用范围」切换默认与单个档案，一次只显示一个作用域。\n'
                  '此处只列聊天所用系统提示词；工具调用规则由程序内置（与实际可用工具'
                  '和表情插件强绑定，不可修改），事件总结与核心记忆总结的提示词在'
                  '各自的功能页配置。',
                ),
                _Section(
                  children: [
                    _PromptScopeSelector(
                      value: _selectedProfile?.id,
                      profiles: _profiles,
                      onChanged: (value) =>
                          setState(() => _scopeProfileId = value),
                    ),
                    const Divider(height: 1),
                    _scopeSubtitle(),
                  ],
                ),
                const _SectionGap(),
                _Section(
                  children: [
                    for (final prompt in prompts)
                      _promptRow(
                        prompt: prompt,
                        overridden: _isOverridden(prompt),
                        onTap: () => _editScoped(prompt),
                      ),
                  ],
                ),
                const SizedBox(height: 30),
              ],
            ),
    );
  }

  Widget _promptRow({
    required ConfigurablePrompt prompt,
    required bool overridden,
    required VoidCallback onTap,
  }) => ListTile(
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
        if (overridden)
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Text(
              '已自定义',
              style: TextStyle(fontSize: 12, color: Color(0xFF07C160)),
            ),
          ),
        const Icon(Icons.arrow_forward_ios, size: 16),
      ],
    ),
    onTap: onTap,
  );
}

/// 深拷贝提示词覆盖表，避免直接修改服务里的不可变视图。
Map<String, Map<String, String>> _copyOverrides(
  Map<String, Map<String, String>> source,
) => {
  for (final entry in source.entries)
    entry.key: Map<String, String>.of(entry.value),
};

Future<ModelApiProfile?> _showProfileEditor(
  BuildContext context, {
  ModelApiProfile? existing,
}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final url = TextEditingController(text: existing?.apiUrl ?? '');
  final key = TextEditingController(text: existing?.apiKey ?? '');
  final model = TextEditingController(text: existing?.model ?? '');
  var format = existing?.apiFormat ?? 'auto';
  var visionMode = existing?.visionMode ?? 'standalone';
  final timeout = TextEditingController(
    text: existing?.timeoutSeconds?.toString() ?? '',
  );
  final reasoningEffort = TextEditingController(
    text: existing?.reasoningEffort ?? '',
  );
  final budget = TextEditingController(
    text: existing?.thinkingBudget?.toString() ?? '',
  );
  final maxContextLength = TextEditingController(
    text: existing?.maxContextLength?.toString() ?? '',
  );
  bool? thinkingEnabled = existing == null ? true : existing.thinkingEnabled;
  final formKey = GlobalKey<FormState>();
  bool? stream = existing?.stream;
  var capabilities = {...?existing?.capabilities};
  final route = DialogRoute<ModelApiProfile>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(existing == null ? '新建模型档案' : '编辑模型档案'),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '档案名称'),
                ),
                TextField(
                  controller: url,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'API 地址'),
                ),
                TextField(
                  controller: key,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'API Key'),
                ),
                TextField(
                  controller: model,
                  decoration: const InputDecoration(labelText: '模型'),
                ),
                TextField(
                  controller: timeout,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '超时时间（秒，留空继承全局）',
                  ),
                ),
                TextFormField(
                  controller: maxContextLength,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '最大上下文长度（字符，留空不限制）',
                  ),
                  validator: (value) {
                    final text = value?.trim() ?? '';
                    return text.isEmpty ||
                            (int.tryParse(text) != null && int.parse(text) > 0)
                        ? null
                        : '请输入大于 0 的整数';
                  },
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用模型思考'),
                  subtitle: Text(
                    thinkingEnabled == null
                        ? '继承全局'
                        : thinkingEnabled!
                        ? '已启用'
                        : '已关闭',
                  ),
                  tristate: true,
                  value: thinkingEnabled,
                  onChanged: (value) => setState(() => thinkingEnabled = value),
                ),
                _ReasoningEffortSelector(
                  value: reasoningEffort.text,
                  inherit: true,
                  enabled: thinkingEnabled != false,
                  onChanged: (value) =>
                      setState(() => reasoningEffort.text = value),
                ),
                if (supportsThinkingBudget(url.text, format, model.text))
                  TextFormField(
                    controller: budget,
                    enabled: thinkingEnabled != false,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '思考预算（tokens）',
                    ),
                    validator: _validateThinkingBudget,
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('使用流式传输（未选中继承全局）'),
                  value: stream ?? false,
                  tristate: true,
                  onChanged: (value) => setState(() => stream = value),
                ),
                DropdownButtonFormField<String>(
                  initialValue: format,
                  decoration: const InputDecoration(labelText: '协议格式'),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                    DropdownMenuItem(
                      value: 'openai_compatible',
                      child: Text('OpenAI 兼容'),
                    ),
                    DropdownMenuItem(
                      value: 'zhipu_compatible',
                      child: Text('智谱兼容'),
                    ),
                    DropdownMenuItem(
                      value: 'gemini_native',
                      child: Text('Gemini 原生'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => format = value ?? 'auto'),
                ),
                const SizedBox(height: 8),
                for (final capability in ModelProfileCapability.values)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_capabilityLabel(capability)),
                    value: capabilities.contains(capability),
                    onChanged: (selected) => setState(() {
                      if (selected == true) {
                        capabilities.add(capability);
                      } else {
                        capabilities.remove(capability);
                      }
                    }),
                  ),
                if (capabilities.contains(ModelProfileCapability.vision))
                  DropdownButtonFormField<String>(
                    initialValue: visionMode,
                    decoration: const InputDecoration(labelText: '视觉运行模式'),
                    items: const [
                      DropdownMenuItem(
                        value: 'standalone',
                        child: Text('独立识图'),
                      ),
                      DropdownMenuItem(
                        value: 'pre_model',
                        child: Text('预处理模型'),
                      ),
                      DropdownMenuItem(value: 'tool', child: Text('工具调用')),
                    ],
                    onChanged: (value) =>
                        setState(() => visionMode = value ?? 'standalone'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              if (name.text.trim().isEmpty ||
                  url.text.trim().isEmpty ||
                  model.text.trim().isEmpty ||
                  capabilities.isEmpty) {
                return;
              }
              Navigator.pop(
                context,
                ModelApiProfile(
                  id:
                      existing?.id ??
                      'model_profile_${DateTime.now().microsecondsSinceEpoch}',
                  name: name.text.trim(),
                  apiUrl: url.text.trim(),
                  apiKey: key.text.trim(),
                  model: model.text.trim(),
                  apiFormat: format,
                  capabilities: capabilities,
                  visionMode:
                      capabilities.contains(ModelProfileCapability.vision)
                      ? visionMode
                      : null,
                  timeoutSeconds: int.tryParse(
                    timeout.text.trim(),
                  )?.clamp(1, 3600),
                  reasoningEffort: reasoningEffort.text.trim().isEmpty
                      ? null
                      : reasoningEffort.text.trim(),
                  thinkingEnabled: thinkingEnabled,
                  thinkingBudget:
                      supportsThinkingBudget(url.text, format, model.text)
                      ? normalizeThinkingBudget(budget.text.trim())
                      : null,
                  stream: stream,
                  maxContextLength: int.tryParse(maxContextLength.text.trim()),
                  promptOverrides: existing?.promptOverrides ?? const {},
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  name.dispose();
  url.dispose();
  key.dispose();
  model.dispose();
  timeout.dispose();
  reasoningEffort.dispose();
  budget.dispose();
  maxContextLength.dispose();
  return result;
}

String? _validateThinkingBudget(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return normalizeThinkingBudget(value.trim()) == null ? '请输入正整数' : null;
}

class _ReasoningEffortSelector extends StatelessWidget {
  final String value;
  final bool inherit;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _ReasoningEffortSelector({
    required this.value,
    required this.onChanged,
    this.inherit = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final choices = <String, String>{
      '': inherit ? '继承全局' : '供应商默认',
      'minimal': '最低（minimal）',
      'low': '低（low）',
      'medium': '中（medium）',
      'high': '高（high）',
      'xhigh': '最高（xhigh）',
      if (value.isNotEmpty &&
          !const {'minimal', 'low', 'medium', 'high', 'xhigh'}.contains(value))
        value: value,
    };
    return DropdownButtonFormField<String>(
      key: ValueKey(value),
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '思考强度'),
      items: choices.entries
          .map(
            (entry) =>
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          )
          .toList(),
      onChanged: enabled ? (value) => onChanged(value ?? '') : null,
    );
  }
}

Future<String?> _askProfileName(BuildContext context, String initial) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('保存模型档案'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '档案名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class _Section extends StatelessWidget {
  final List<Widget> children;
  const _Section({required this.children});

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    child: Column(children: children),
  );
}

class _SectionGap extends StatelessWidget {
  const _SectionGap();
  @override
  Widget build(BuildContext context) => const SizedBox(height: 12);
}

class _PageHint extends StatelessWidget {
  final String text;
  const _PageHint(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: Color(0xFF777777)),
    ),
  );
}

class _NavigationRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _NavigationRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: const Color(0xFF07C160)),
    title: Text(title),
    subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const Icon(
      Icons.arrow_forward_ios,
      size: 16,
      color: Color(0xFFBBBBBB),
    ),
    onTap: onTap,
  );
}

class _FieldRow extends StatefulWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  const _FieldRow({
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
  });

  @override
  State<_FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<_FieldRow> {
  late bool _obscured = widget.obscure;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        SizedBox(width: 82, child: Text(widget.label)),
        Expanded(
          child: TextField(
            controller: widget.controller,
            obscureText: _obscured,
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              hintText: widget.hint,
              suffixIcon: widget.obscure
                  ? IconButton(
                      tooltip: _obscured ? '显示' : '隐藏',
                      onPressed: () => setState(() => _obscured = !_obscured),
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback? onTap;
  const _ActionRow({
    required this.icon,
    required this.label,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    leading: busy
        ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon),
    title: Text(label),
    trailing: const Icon(
      Icons.arrow_forward_ios,
      size: 16,
      color: Color(0xFFBBBBBB),
    ),
    onTap: onTap,
  );
}

class _FormatSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _FormatSelector({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(
      children: [
        const SizedBox(width: 82, child: Text('协议格式')),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('自动识别')),
                DropdownMenuItem(
                  value: 'openai_compatible',
                  child: Text('OpenAI 兼容'),
                ),
                DropdownMenuItem(
                  value: 'zhipu_compatible',
                  child: Text('智谱兼容'),
                ),
                DropdownMenuItem(
                  value: 'gemini_native',
                  child: Text('Gemini 原生'),
                ),
              ],
              onChanged: (next) {
                if (next != null) onChanged(next);
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class _VisionModeSelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _VisionModeSelector({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(
      children: [
        const SizedBox(width: 82, child: Text('运行模式')),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'standalone', child: Text('独立识图')),
                DropdownMenuItem(value: 'pre_model', child: Text('预处理模型')),
                DropdownMenuItem(value: 'tool', child: Text('工具调用')),
              ],
              onChanged: (next) {
                if (next != null) onChanged(next);
              },
            ),
          ),
        ),
      ],
    ),
  );
}

class _ModelRow extends StatelessWidget {
  final TextEditingController controller;
  final List<String> models;
  final ValueChanged<String> onChanged;
  const _ModelRow({
    required this.controller,
    required this.models,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final current = controller.text.trim();
    // 已配置但不在拉取列表中的模型（例如套用模型档案后）也要显示出来，
    // 否则下拉框会退回到提示文案。
    final options = current.isEmpty || models.contains(current)
        ? models
        : <String>[current, ...models];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const SizedBox(width: 82, child: Text('模型')),
          Expanded(
            child: options.isEmpty
                ? TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '输入模型名称',
                    ),
                  )
                : DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: options.contains(current) ? current : null,
                      hint: const Text('选择模型'),
                      isExpanded: true,
                      items: options
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(
                                item,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) onChanged(value);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProfileSelector extends StatelessWidget {
  final String? value;
  final List<ModelApiProfile> profiles;
  final ValueChanged<String?> onChanged;
  const _ProfileSelector({
    required this.value,
    required this.profiles,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(
      children: [
        const SizedBox(width: 82, child: Text('模型档案')),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: profiles.any((item) => item.id == value) ? value : null,
              hint: const Text('选择并应用档案'),
              isExpanded: true,
              items: profiles
                  .map(
                    (item) => DropdownMenuItem(
                      value: item.id,
                      child: Text(item.name, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    ),
  );
}

String _capabilityLabel(ModelProfileCapability capability) =>
    switch (capability) {
      ModelProfileCapability.chat => '聊天',
      ModelProfileCapability.intent => '意图识别',
      ModelProfileCapability.vision => '视觉识别',
      ModelProfileCapability.embedding => '向量记忆',
    };

void _showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

({String url, Map<String, String> headers, bool nativeGemini})
_buildModelsRequest(String apiUrl, String apiKey, String apiFormat) {
  final uri = Uri.parse(apiUrl.trim());
  final google = uri.host.toLowerCase() == 'generativelanguage.googleapis.com';
  final native =
      apiFormat == 'gemini_native' ||
      (apiFormat != 'openai_compatible' &&
          google &&
          !uri.path.toLowerCase().contains('/openai'));
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (native) {
    path = _nativeGeminiBasePath(path);
    if (!path.toLowerCase().endsWith('/v1') &&
        !path.toLowerCase().endsWith('/v1beta')) {
      path = '$path/v1beta';
    }
    return (
      url: uri
          .replace(path: '$path/models', queryParameters: {'key': apiKey})
          .toString(),
      headers: const {},
      nativeGemini: true,
    );
  }
  if (google &&
      apiFormat == 'openai_compatible' &&
      !path.toLowerCase().contains('/openai')) {
    path = '$path/openai';
  }
  path = path.replaceFirst(RegExp(r'/chat/completions$'), '');
  if (!path.endsWith('/models')) {
    path = path.endsWith('/v1') ? '$path/models' : '$path/v1/models';
    if ((uri.host.toLowerCase() == 'open.bigmodel.cn' ||
            uri.host.toLowerCase() == 'api.z.ai' ||
            uri.host.toLowerCase().endsWith('.bigmodel.cn')) &&
        (path.toLowerCase().contains('/api/paas/') ||
            path.toLowerCase().endsWith('/v4/v1/models'))) {
      path = path.replaceFirst(RegExp(r'/v4/v1/models$'), '/v4/models');
    }
  }
  return (
    url: uri.replace(path: path, query: null).toString(),
    headers: {'Authorization': 'Bearer $apiKey'},
    nativeGemini: false,
  );
}

List<String> _readModelIds(dynamic decoded, bool nativeGemini) {
  if (decoded is! Map<String, dynamic>) return [];
  final records = decoded[nativeGemini ? 'models' : 'data'];
  if (records is! List) return [];
  final result = <String>{};
  for (final item in records) {
    if (item is! Map) continue;
    if (nativeGemini) {
      final methods = item['supportedGenerationMethods'];
      if (methods is List && !methods.contains('generateContent')) continue;
      final id = '${item['name'] ?? ''}'.replaceFirst(RegExp(r'^models/'), '');
      if (id.isNotEmpty) result.add(id);
    } else {
      final id = '${item['id'] ?? ''}';
      if (id.isNotEmpty) result.add(id);
    }
  }
  return result.toList()..sort();
}

bool _usesNativeGemini(String value, String apiFormat) {
  final uri = Uri.parse(value.trim());
  if (apiFormat == 'gemini_native') return true;
  return uri.host.toLowerCase() == 'generativelanguage.googleapis.com' &&
      apiFormat != 'openai_compatible' &&
      !uri.path.toLowerCase().contains('/openai');
}

String _nativeGeminiBasePath(String path) {
  var result = path.replaceFirst(
    RegExp(r'/openai(?:/|$)', caseSensitive: false),
    '/',
  );
  result = result.replaceFirst(
    RegExp(r'/models(?:/.*)?$', caseSensitive: false),
    '',
  );
  result = result.replaceFirst(
    RegExp(r'/chat/completions$', caseSensitive: false),
    '',
  );
  return result.replaceAll(RegExp(r'/+$'), '');
}

String _nativeGeminiEndpoint(String value, String model, String apiKey) {
  final uri = Uri.parse(value.trim());
  var path = _nativeGeminiBasePath(uri.path);
  if (!path.toLowerCase().endsWith('/v1') &&
      !path.toLowerCase().endsWith('/v1beta')) {
    path = '$path/v1beta';
  }
  return uri
      .replace(
        path:
            '$path/models/${model.replaceFirst(RegExp(r'^models/'), '')}:generateContent',
        queryParameters: {'key': apiKey.trim()},
        fragment: '',
      )
      .toString();
}

Map<String, dynamic> _nativeGeminiTestBody(ModelSettingsKind kind) {
  final parts = <Map<String, dynamic>>[
    {'text': 'Reply with OK.'},
  ];
  if (kind == ModelSettingsKind.vision) {
    parts.add({
      'inlineData': {
        'mimeType': 'image/png',
        'data':
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl0fZcAAAAASUVORK5CYII=',
      },
    });
  }
  return {
    'contents': [
      {'role': 'user', 'parts': parts},
    ],
    'generationConfig': {'maxOutputTokens': 8},
  };
}

Map<String, dynamic> _chatTestBody(ModelSettingsKind kind, String model) {
  if (kind == ModelSettingsKind.vision) {
    return {
      'model': model,
      'max_tokens': 8,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Reply with OK.'},
            {
              'type': 'image_url',
              'image_url': {
                'url':
                    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl0fZcAAAAASUVORK5CYII=',
              },
            },
          ],
        },
      ],
    };
  }
  return {
    'model': model,
    'max_tokens': 8,
    'messages': [
      {'role': 'user', 'content': 'Reply with OK.'},
    ],
  };
}

String _chatEndpoint(String value) {
  final uri = Uri.parse(value.trim());
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (!path.endsWith('/chat/completions')) {
    path = path.endsWith('/v1')
        ? '$path/chat/completions'
        : ((uri.host.toLowerCase() == 'open.bigmodel.cn' ||
                      uri.host.toLowerCase() == 'api.z.ai' ||
                      uri.host.toLowerCase().endsWith('.bigmodel.cn')) &&
                  (path.toLowerCase().endsWith('/v4') ||
                      path.toLowerCase().contains('/api/paas/'))
              ? '$path/chat/completions'
              : '$path/v1/chat/completions');
  }
  return uri.replace(path: path, query: '', fragment: '').toString();
}

String _embeddingEndpoint(String value) {
  final uri = Uri.parse(value.trim());
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (path.endsWith('/chat/completions')) {
    path =
        '${path.substring(0, path.length - '/chat/completions'.length)}/embeddings';
  } else if (!path.endsWith('/embeddings')) {
    path = path.endsWith('/v1') ? '$path/embeddings' : '$path/v1/embeddings';
  }
  return uri.replace(path: path, query: '', fragment: '').toString();
}

String _responseSummary(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized.length > 120
      ? '${normalized.substring(0, 120)}...'
      : normalized;
}

class _ModelSettingsPageState extends State<ModelSettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
  bool _enabled = true;
  String _format = 'auto';
  String _visionMode = 'standalone';
  late final TextEditingController _timeout;
  late final TextEditingController _reasoningEffort;
  late final TextEditingController _thinkingBudget;
  bool _stream = false;
  bool _thinkingEnabled = true;
  List<String> _models = [];
  bool _fetching = false;
  bool _testing = false;
  bool _saving = false;
  String? _profileId;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;
    switch (widget.kind) {
      case ModelSettingsKind.chat:
        _url = TextEditingController(text: settings.chatApiUrl);
        _key = TextEditingController(text: settings.chatApiKey);
        _model = TextEditingController(text: settings.chatModel);
        _format = settings.chatApiFormat;
      case ModelSettingsKind.intent:
        _url = TextEditingController(text: settings.intentApiUrl);
        _key = TextEditingController(text: settings.intentApiKey);
        _model = TextEditingController(text: settings.intentModel);
        _enabled = settings.intentEnabled;
        _format = settings.intentApiFormat;
      case ModelSettingsKind.vision:
        _url = TextEditingController(text: settings.visionApiUrl);
        _key = TextEditingController(text: settings.visionApiKey);
        _model = TextEditingController(text: settings.visionModel);
        _enabled = settings.visionEnabled;
        _format = settings.visionApiFormat;
        _visionMode = settings.visionMode;
      case ModelSettingsKind.embedding:
        _url = TextEditingController(text: settings.embeddingApiUrl);
        _key = TextEditingController(text: settings.embeddingApiKey);
        _model = TextEditingController(text: settings.embeddingModel);
        _enabled = settings.embeddingEnabled;
    }
    _profileId = _matchingProfile()?.id;
    _timeout = TextEditingController(
      text: settings.chatTimeoutSeconds.toString(),
    );
    _reasoningEffort = TextEditingController(
      text: settings.chatReasoningEffort,
    );
    _stream = settings.chatStream;
    _thinkingEnabled = settings.thinkingEnabled;
    final thinking = settings.thinkingSettingsFor(widget.kind.name);
    if (widget.kind != ModelSettingsKind.chat) {
      _thinkingEnabled =
          thinking['thinking_enabled'] as bool? ?? settings.thinkingEnabled;
      _reasoningEffort.text = thinking['reasoning_effort'] as String? ?? '';
    }
    _thinkingBudget = TextEditingController(
      text:
          (widget.kind == ModelSettingsKind.chat
                  ? settings.thinkingBudget
                  : thinking['thinking_budget'])
              ?.toString() ??
          '',
    );
    _url.addListener(_refreshThinkingProvider);
  }

  void _refreshThinkingProvider() => setState(() {});

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _timeout.dispose();
    _reasoningEffort.dispose();
    _thinkingBudget.dispose();
    super.dispose();
  }

  ModelApiProfile? _matchingProfile() {
    for (final profile in SettingsService.instance.modelProfilesFor(
      widget.kind.capability,
    )) {
      if (profile.apiUrl == _url.text && profile.model == _model.text) {
        return profile;
      }
    }
    return null;
  }

  /// 选中模型后必须重建页面，否则下拉框仍显示上一个模型，
  /// 需要其它操作（切换开关、重进页面等）才会刷新。
  void _applyModel(String model) {
    setState(() {
      _model.text = model;
      _profileId = _matchingProfile()?.id;
    });
  }

  Future<void> _fetchModels() async {
    if (_url.text.trim().isEmpty || _key.text.trim().isEmpty) {
      _showMessage(context, '请先填写 API 地址和 API Key');
      return;
    }
    setState(() => _fetching = true);
    try {
      final request = _buildModelsRequest(_url.text, _key.text, _format);
      final response = await SecureBackendClient.getRaw(
        request.url,
        headers: request.headers,
        includeAuth: false,
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final models = _readModelIds(
        jsonDecode(response.body),
        request.nativeGemini,
      );
      if (!mounted) return;
      setState(() {
        _models = models;
        if (models.isNotEmpty && !models.contains(_model.text)) {
          _model.text = models.first;
        }
        _profileId = _matchingProfile()?.id;
      });
      _showMessage(context, '获取到 ${models.length} 个模型');
    } catch (error) {
      if (mounted) _showMessage(context, '获取模型失败: $error');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _test() async {
    if (_url.text.trim().isEmpty ||
        _key.text.trim().isEmpty ||
        _model.text.trim().isEmpty) {
      _showMessage(context, '请先填写 API 地址、API Key 和模型');
      return;
    }
    setState(() => _testing = true);
    try {
      final nativeGemini = _usesNativeGemini(_url.text, _format);
      final response = widget.kind == ModelSettingsKind.embedding
          ? await SecureBackendClient.postRawJson(
              _embeddingEndpoint(_url.text),
              body: {
                'model': _model.text.trim(),
                'input': 'ZeroChat configuration test',
              },
              headers: {'Authorization': 'Bearer ${_key.text.trim()}'},
              includeAuth: false,
              timeout: const Duration(seconds: 20),
            )
          : await SecureBackendClient.postRawJson(
              nativeGemini
                  ? _nativeGeminiEndpoint(_url.text, _model.text, _key.text)
                  : _chatEndpoint(_url.text),
              body: nativeGemini
                  ? _nativeGeminiTestBody(widget.kind)
                  : _chatTestBody(widget.kind, _model.text.trim()),
              headers: nativeGemini
                  ? const {'Content-Type': 'application/json'}
                  : {'Authorization': 'Bearer ${_key.text.trim()}'},
              includeAuth: false,
              timeout: const Duration(seconds: 30),
            );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}: ${_responseSummary(response.body)}',
        );
      }
      if (mounted) _showMessage(context, '当前配置可用');
    } catch (error) {
      if (mounted) {
        _showMessage(context, '测试失败: ${_responseSummary(error.toString())}');
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (supportsThinkingBudget(_url.text, _format, _model.text) &&
        _validateThinkingBudget(_thinkingBudget.text) != null) {
      _showMessage(context, '思考预算请输入正整数');
      return;
    }
    setState(() => _saving = true);
    try {
      final settings = SettingsService.instance;
      switch (widget.kind) {
        case ModelSettingsKind.chat:
          await settings.updateChatApi(
            url: _url.text.trim(),
            key: _key.text.trim(),
            model: _model.text.trim(),
            apiFormat: _format,
            timeoutSeconds: int.tryParse(_timeout.text.trim()),
            reasoningEffort: _reasoningEffort.text.trim(),
            thinkingEnabled: _thinkingEnabled,
            thinkingBudget: normalizeThinkingBudget(
              _thinkingBudget.text.trim(),
            ),
            clearThinkingBudget: true,
            stream: _stream,
          );
        case ModelSettingsKind.intent:
          await settings.updateIntentApi(
            enabled: _enabled,
            url: _url.text.trim(),
            key: _key.text.trim(),
            model: _model.text.trim(),
            apiFormat: _format,
          );
        case ModelSettingsKind.vision:
          await settings.updateVisionApi(
            enabled: _enabled,
            url: _url.text.trim(),
            key: _key.text.trim(),
            model: _model.text.trim(),
            mode: _visionMode,
            apiFormat: _format,
          );
        case ModelSettingsKind.embedding:
          await settings.updateEmbeddingApi(
            enabled: _enabled,
            url: _url.text.trim(),
            key: _key.text.trim(),
            model: _model.text.trim(),
          );
      }
      if (widget.kind == ModelSettingsKind.intent ||
          widget.kind == ModelSettingsKind.vision) {
        await settings.updateModelThinkingSettings(
          widget.kind.name,
          enabled: _thinkingEnabled,
          effort: _reasoningEffort.text.trim(),
          budget: normalizeThinkingBudget(_thinkingBudget.text.trim()),
        );
      }
      final synced = await settings.syncApiSettingsToBackend();
      if (!mounted) return;
      if (!synced) {
        _showMessage(context, '已保存到本地，后端同步失败，可稍后重试');
        return;
      }
      Navigator.pop(context);
    } catch (error) {
      if (mounted) _showMessage(context, '保存失败: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAsProfile() async {
    if (_validateThinkingBudget(_thinkingBudget.text) != null) {
      _showMessage(context, '思考预算请输入正整数');
      return;
    }
    final name = await _askProfileName(context, _model.text.trim());
    if (name == null || name.isEmpty) return;
    final id = 'model_profile_${DateTime.now().microsecondsSinceEpoch}';
    await SettingsService.instance.saveApiProfile(
      ModelApiProfile(
        id: id,
        name: name,
        apiUrl: _url.text.trim(),
        model: _model.text.trim(),
        apiKey: _key.text.trim(),
        apiFormat: _format,
        capabilities: {widget.kind.capability},
        visionMode: widget.kind == ModelSettingsKind.vision
            ? _visionMode
            : null,
        timeoutSeconds: int.tryParse(_timeout.text.trim())?.clamp(1, 3600),
        reasoningEffort: _reasoningEffort.text.trim().isEmpty
            ? null
            : _reasoningEffort.text.trim(),
        thinkingEnabled: _thinkingEnabled,
        thinkingBudget: normalizeThinkingBudget(_thinkingBudget.text.trim()),
        stream: _stream,
      ),
    );
    if (mounted) setState(() => _profileId = id);
  }

  void _applyProfile(String? id) {
    if (id == null || id.isEmpty) return;
    final settings = SettingsService.instance;
    final profile = SettingsService.instance
        .modelProfilesFor(widget.kind.capability)
        .firstWhere((item) => item.id == id);
    setState(() {
      _profileId = profile.id;
      _url.text = profile.apiUrl;
      _key.text = profile.apiKey;
      _model.text = profile.model;
      _format = profile.apiFormat;
      _timeout.text =
          profile.timeoutSeconds?.toString() ??
          settings.chatTimeoutSeconds.toString();
      _reasoningEffort.text =
          profile.reasoningEffort ?? settings.chatReasoningEffort;
      _thinkingEnabled = profile.thinkingEnabled ?? settings.thinkingEnabled;
      _thinkingBudget.text =
          (profile.thinkingBudget ?? settings.thinkingBudget)?.toString() ?? '';
      _stream = profile.stream ?? settings.chatStream;
      if (profile.visionMode != null) _visionMode = profile.visionMode!;
    });
  }

  @override
  Widget build(BuildContext context) {
    final profiles = SettingsService.instance.modelProfilesFor(
      widget.kind.capability,
    );
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: Text(widget.kind.title),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中...' : '保存'),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (widget.kind.hasToggle) ...[
            _Section(
              children: [
                SwitchListTile(
                  title: Text('启用${widget.kind.title}'),
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ],
            ),
            const _SectionGap(),
          ],
          _Section(
            children: [
              _FieldRow(
                label: 'API 地址',
                controller: _url,
                hint: 'https://api.example.com/v1',
              ),
              if (widget.kind.hasFormat) ...[
                const Divider(height: 1),
                _FormatSelector(
                  value: _format,
                  onChanged: (value) => setState(() => _format = value),
                ),
              ],
              const Divider(height: 1),
              _FieldRow(
                label: 'API Key',
                controller: _key,
                hint: 'sk-xxx',
                obscure: true,
              ),
              const Divider(height: 1),
              _ModelRow(
                controller: _model,
                models: _models,
                onChanged: _applyModel,
              ),
              if (widget.kind == ModelSettingsKind.chat) ...[
                const Divider(height: 1),
                _FieldRow(
                  label: '超时时间（秒）',
                  controller: _timeout,
                  hint: '1-3600',
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('使用流式传输'),
                  value: _stream,
                  onChanged: (value) => setState(() => _stream = value),
                ),
              ],
              if (widget.kind != ModelSettingsKind.embedding) ...[
                SwitchListTile(
                  title: const Text('启用模型思考'),
                  value: _thinkingEnabled,
                  onChanged: (value) =>
                      setState(() => _thinkingEnabled = value),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: _ReasoningEffortSelector(
                    value: _reasoningEffort.text,
                    enabled: _thinkingEnabled,
                    onChanged: (value) =>
                        setState(() => _reasoningEffort.text = value),
                  ),
                ),
                if (supportsThinkingBudget(_url.text, _format, _model.text))
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: TextFormField(
                      controller: _thinkingBudget,
                      enabled: _thinkingEnabled,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '思考预算（tokens）',
                      ),
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      validator: _validateThinkingBudget,
                    ),
                  ),
              ],
              const Divider(height: 1),
              _ActionRow(
                icon: Icons.cloud_download_outlined,
                label: _fetching ? '获取中...' : '获取模型列表',
                busy: _fetching,
                onTap: _fetching ? null : _fetchModels,
              ),
              const Divider(height: 1),
              _ActionRow(
                icon: Icons.play_circle_outline,
                label: _testing ? '测试中...' : '测试当前配置',
                busy: _testing,
                onTap: _testing ? null : _test,
              ),
              if (widget.kind.hasVisionMode) ...[
                const Divider(height: 1),
                _VisionModeSelector(
                  value: _visionMode,
                  onChanged: (value) => setState(() => _visionMode = value),
                ),
              ],
            ],
          ),
          const _SectionGap(),
          _Section(
            children: [
              _ProfileSelector(
                value: _profileId,
                profiles: profiles,
                onChanged: _applyProfile,
              ),
              const Divider(height: 1),
              _ActionRow(
                icon: Icons.bookmark_add_outlined,
                label: '保存为模型档案',
                onTap: _saveAsProfile,
              ),
            ],
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
