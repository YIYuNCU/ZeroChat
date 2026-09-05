import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import '../models/ai_model_profile.dart';
import '../models/onebot_config.dart';
import '../models/role.dart';
import '../models/stats_config.dart';
import '../services/secure_backend_client.dart';
import '../services/settings_service.dart';

/// 角色参数设置页面
/// 调整 AI 角色的参数配置
class RoleSettingsPage extends StatefulWidget {
  final Role role;

  const RoleSettingsPage({super.key, required this.role});

  @override
  State<RoleSettingsPage> createState() => _RoleSettingsPageState();
}

class _RoleSettingsPageState extends State<RoleSettingsPage> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late TextEditingController _promptController;
  late TextEditingController _aiModelController;
  late TextEditingController _aiApiUrlController;
  late TextEditingController _aiApiKeyController;
  late TextEditingController _aiTemperatureController;
  int? _aiTimeoutSeconds;
  String? _aiReasoningEffort;
  bool? _aiThinkingEnabled;
  String? _aiApiFormat;
  int? _aiThinkingBudget;
  bool? _aiStream;
  late TextEditingController _cycleLengthController;
  late TextEditingController _periodLengthController;
  late TextEditingController _lastPeriodStartController;
  late String _gender;
  late int _maxContextRounds;
  late int _maxContextLength;
  late bool _allowWebSearch;
  late bool _onebotEnabled;
  late TextEditingController _onebotSecretController;
  late TextEditingController _onebotSelfIdController;
  late TextEditingController _onebotMainUserIdController;
  late TextEditingController _onebotAllowedUsersController;
  late TextEditingController _onebotAllowedGroupsController;
  List<String> _availableAiModels = [];
  bool _isLoadingAiModels = false;
  String? _selectedModelProfileId;
  bool _isApplyingModelProfile = false;

  // 数值系统
  late bool _statsEnabled;
  late List<StatItem> _statItems;
  // 消息部分显隐
  late bool _showAction;
  late bool _showSound;
  late bool _showPsychology;
  late bool _showStats;
  late bool _showNoReply;
  late bool _archived;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.role.name);
    _descController = TextEditingController(text: widget.role.description);
    _promptController = TextEditingController(text: widget.role.systemPrompt);
    _aiModelController = TextEditingController(text: widget.role.aiModel);
    _aiApiUrlController = TextEditingController(text: widget.role.aiApiUrl);
    _aiApiKeyController = TextEditingController(text: widget.role.aiApiKey);
    _aiTimeoutSeconds = widget.role.aiTimeoutSeconds;
    _aiReasoningEffort = widget.role.aiReasoningEffort;
    _aiThinkingEnabled = widget.role.aiThinkingEnabled;
    _aiApiFormat = widget.role.aiApiFormat;
    _aiThinkingBudget = widget.role.aiThinkingBudget;
    _aiStream = widget.role.aiStream;
    final savedProfileId = SettingsService.instance
        .selectedModelProfileIdForRole(widget.role.id);
    _selectedModelProfileId =
        SettingsService.instance.modelProfiles.any(
          (profile) => profile.id == savedProfileId,
        )
        ? savedProfileId
        : null;
    _aiModelController.addListener(_clearModelProfileSelection);
    _aiApiUrlController.addListener(_clearModelProfileSelection);
    _aiApiKeyController.addListener(_clearModelProfileSelection);
    _aiTemperatureController = TextEditingController(
      text: widget.role.aiTemperature.toStringAsFixed(1),
    );
    _cycleLengthController = TextEditingController(
      text: '${widget.role.menstruationCycle['cycle_length'] ?? 30}',
    );
    _periodLengthController = TextEditingController(
      text: '${widget.role.menstruationCycle['period_length'] ?? 6}',
    );
    _lastPeriodStartController = TextEditingController(
      text:
          widget.role.menstruationCycle['last_period_start']?.toString() ??
          '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}',
    );
    _gender = widget.role.gender;
    _maxContextRounds = widget.role.maxContextRounds;
    _maxContextLength = widget.role.maxContextLength;
    _allowWebSearch = widget.role.allowWebSearch;
    _onebotEnabled = widget.role.onebotConfig.enabled;
    _onebotSecretController = TextEditingController(
      text: widget.role.onebotConfig.secret,
    );
    _onebotSelfIdController = TextEditingController(
      text: widget.role.onebotConfig.selfId > 0
          ? widget.role.onebotConfig.selfId.toString()
          : '',
    );
    _onebotMainUserIdController = TextEditingController(
      text: widget.role.onebotConfig.mainUserId > 0
          ? widget.role.onebotConfig.mainUserId.toString()
          : '',
    );
    _onebotAllowedUsersController = TextEditingController(
      text: widget.role.onebotConfig.allowedUsers.join(','),
    );
    _onebotAllowedGroupsController = TextEditingController(
      text: widget.role.onebotConfig.allowedGroups.join(','),
    );
    _statsEnabled = widget.role.statsConfig.enabled;
    _statItems = List<StatItem>.from(widget.role.statsConfig.stats);
    _showAction = widget.role.showAction;
    _showSound = widget.role.showSound;
    _showPsychology = widget.role.showPsychology;
    _showStats = widget.role.showStats;
    _showNoReply = widget.role.showNoReply;
    _archived = widget.role.archived;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _promptController.dispose();
    _aiModelController.dispose();
    _aiApiUrlController.dispose();
    _aiApiKeyController.dispose();
    _aiTemperatureController.dispose();
    _cycleLengthController.dispose();
    _periodLengthController.dispose();
    _lastPeriodStartController.dispose();
    _onebotSecretController.dispose();
    _onebotSelfIdController.dispose();
    _onebotMainUserIdController.dispose();
    _onebotAllowedUsersController.dispose();
    _onebotAllowedGroupsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: const Text(
          '角色设置',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          TextButton(
            onPressed: _saveRole,
            child: const Text(
              '保存',
              style: TextStyle(color: Color(0xFF07C160), fontSize: 16),
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 基本信息
          _buildSection(
            title: '基本信息',
            children: [
              _buildTextField(label: '角色名称', controller: _nameController),
              const Divider(height: 1, indent: 16),
              _buildTextField(
                label: '角色描述',
                controller: _descController,
                hintText: '简短描述这个角色',
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 系统提示词
          _buildSection(
            title: '系统提示词 (System Prompt)',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _promptController,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    hintText: '定义 AI 的角色、性格和行为...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 后端角色配置
          _buildSection(
            title: '后端角色配置',
            children: [
              _buildModelProfileSelector(),
              if (!_hasSelectedModelProfile) ...[
                const Divider(height: 1, indent: 16),
                _buildAiModelField(),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: 'API地址',
                  controller: _aiApiUrlController,
                ),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '密钥',
                  controller: _aiApiKeyController,
                  obscureText: true,
                ),
              ],
              const Divider(height: 1, indent: 16),
              _buildTextField(
                label: '温度',
                controller: _aiTemperatureController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
              ),
              const Divider(height: 1, indent: 16),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 80,
                      child: Text('性别', style: TextStyle(fontSize: 16)),
                    ),
                    Expanded(
                      child: DropdownButton<String>(
                        value: _gender,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 'men', child: Text('men')),
                          DropdownMenuItem(
                            value: 'women',
                            child: Text('women'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _gender = value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              if (_gender != 'men') ...[
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '周期长度',
                  controller: _cycleLengthController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '月经时长',
                  controller: _periodLengthController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '上次月经时间',
                  controller: _lastPeriodStartController,
                ),
              ],
            ],
          ),

          const SizedBox(height: 10),

          // 上下文设置
          _buildSection(
            title: '上下文设置',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('最大上下文轮数', style: TextStyle(fontSize: 16)),
                          SizedBox(height: 4),
                          Text(
                            '每轮包含一条用户消息和一条AI回复',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF888888),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: _maxContextRounds > 1
                              ? () => setState(() => _maxContextRounds--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        GestureDetector(
                          onTap: _showEditContextRoundsDialog,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$_maxContextRounds',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => setState(() => _maxContextRounds++),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: 16),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('最大上下文长度', style: TextStyle(fontSize: 16)),
                          const SizedBox(height: 4),
                          Text(
                            '按消息字符数计算，条数或长度任一达到即更新窗口',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF888888),
                            ),
                          ),
                          if (_selectedModelProfileContextLength != null)
                            Text(
                              '模型档案上限 $_selectedModelProfileContextLength，实际使用 $_effectiveMaxContextLength',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF888888),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: _maxContextLength > 100
                              ? () => setState(() => _maxContextLength -= 100)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        GestureDetector(
                          onTap: _showEditContextLengthDialog,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F5F5),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$_maxContextLength',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () =>
                              setState(() => _maxContextLength += 100),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 其他设置
          _buildSection(
            title: '其他设置',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('允许联网搜索', style: TextStyle(fontSize: 16)),
                        SizedBox(height: 4),
                        Text(
                          '开启后角色可以调用网络搜索能力',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ],
                    ),
                    Switch(
                      value: _allowWebSearch,
                      activeThumbColor: const Color(0xFF07C160),
                      onChanged: (v) => setState(() => _allowWebSearch = v),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // OneBot 接口
          _buildSection(
            title: 'OneBot V11 接口',
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('启用 OneBot 接口', style: TextStyle(fontSize: 16)),
                        SizedBox(height: 4),
                        Text(
                          '接收 QQ 机器人框架消息',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ],
                    ),
                    Switch(
                      value: _onebotEnabled,
                      activeThumbColor: const Color(0xFF07C160),
                      onChanged: (v) => setState(() => _onebotEnabled = v),
                    ),
                  ],
                ),
              ),
              if (_onebotEnabled) ...[
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: 'Secret',
                  controller: _onebotSecretController,
                  hintText: '鉴权密钥',
                ),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '机器人QQ号',
                  controller: _onebotSelfIdController,
                  hintText: '机器人自身QQ号，用于判断@',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                  ],
                ),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '主QQ号',
                  controller: _onebotMainUserIdController,
                  hintText: '与默认前端用户视为同一人',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                  ],
                ),
                const Divider(height: 1, indent: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 80,
                        child: Text('Endpoint', style: TextStyle(fontSize: 16)),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            final url = '/onebot/ws/${widget.role.id}';
                            Clipboard.setData(ClipboardData(text: url));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('已复制 WebSocket 路径'),
                                duration: Duration(seconds: 1),
                              ),
                            );
                          },
                          child: Text(
                            '/onebot/ws/${widget.role.id}',
                            style: const TextStyle(
                              fontSize: 14,
                              color: Color(0xFF07C160),
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '用户白名单',
                  controller: _onebotAllowedUsersController,
                  hintText: 'QQ号，逗号分隔，为空则不处理私聊',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9,]')),
                  ],
                ),
                const Divider(height: 1, indent: 16),
                _buildTextField(
                  label: '群聊白名单',
                  controller: _onebotAllowedGroupsController,
                  hintText: '群号，逗号分隔，为空则不处理群聊',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9,]')),
                  ],
                ),
              ],
            ],
          ),

          const SizedBox(height: 10),

          // 消息显示设置（对话始终显示）
          _buildSection(
            title: '消息显示',
            children: [
              _buildSwitchRow(
                title: '显示动作',
                subtitle: '气泡中显示 <动作> 部分',
                value: _showAction,
                onChanged: (v) => setState(() => _showAction = v),
              ),
              const Divider(height: 1, indent: 16),
              _buildSwitchRow(
                title: '显示心理',
                subtitle: '气泡中显示 <心理> 部分',
                value: _showPsychology,
                onChanged: (v) => setState(() => _showPsychology = v),
              ),
              const Divider(height: 1, indent: 16),
              _buildSwitchRow(
                title: '显示数值',
                subtitle: '气泡中显示 <数值> 部分',
                value: _showStats,
                onChanged: (v) => setState(() => _showStats = v),
              ),
              const Divider(height: 1, indent: 16),
              _buildSwitchRow(
                title: '显示声音',
                subtitle: '气泡中显示 <声音> 部分',
                value: _showSound,
                onChanged: (v) => setState(() => _showSound = v),
              ),
              const Divider(height: 1, indent: 16),
              _buildSwitchRow(
                title: '显示无回复提示',
                subtitle: 'AI 返回 <无回复/> 时在聊天中显示提示',
                value: _showNoReply,
                onChanged: (v) => setState(() => _showNoReply = v),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 数值系统
          _buildSection(
            title: '数值系统',
            children: [
              _buildSwitchRow(
                title: '启用数值',
                subtitle: '让 AI 维护并在回复中输出数值',
                value: _statsEnabled,
                onChanged: (v) => setState(() => _statsEnabled = v),
              ),
              if (_statsEnabled) ...[
                const Divider(height: 1, indent: 16),
                ..._buildStatItemRows(),
                const Divider(height: 1, indent: 16),
                InkWell(
                  onTap: _addStatItem,
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add, size: 18, color: Color(0xFF07C160)),
                        SizedBox(width: 4),
                        Text(
                          '添加数值',
                          style: TextStyle(
                            color: Color(0xFF07C160),
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 10),

          // 状态管理（归档）
          _buildSection(
            title: '状态管理',
            children: [
              _buildSwitchRow(
                title: '归档角色',
                subtitle: '归档后无法聊天、不发朋友圈和主动消息，可随时恢复',
                value: _archived,
                onChanged: (v) => setState(() => _archived = v),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 重置按钮
          _buildSection(
            children: [
              InkWell(
                onTap: _resetToDefault,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: Text(
                      '重置为默认值',
                      style: TextStyle(color: Color(0xFFFA5151), fontSize: 16),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildSwitchRow({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16)),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF888888),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: const Color(0xFF07C160),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  List<Widget> _buildStatItemRows() {
    final rows = <Widget>[];
    for (var i = 0; i < _statItems.length; i++) {
      final item = _statItems[i];
      if (i > 0) rows.add(const Divider(height: 1, indent: 16));
      final displayName = item.name.isNotEmpty ? item.name : item.key;
      rows.add(
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(
            displayName.isNotEmpty ? displayName : '(未命名)',
            style: const TextStyle(fontSize: 16),
          ),
          subtitle: Text(
            '键 ${item.key.isEmpty ? "?" : item.key} · 范围 [${_fmtNum(item.min)}, ${_fmtNum(item.max)}]'
            '${item.description.isNotEmpty ? " · ${item.description}" : ""}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
          trailing: IconButton(
            icon: const Icon(
              Icons.delete_outline,
              size: 20,
              color: Color(0xFFFA5151),
            ),
            onPressed: () => setState(() => _statItems.removeAt(i)),
          ),
          onTap: () => _editStatItem(i),
        ),
      );
    }
    if (rows.isEmpty) {
      rows.add(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            '暂无数值，点击下方添加',
            style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
          ),
        ),
      );
    }
    return rows;
  }

  String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  void _addStatItem() => _editStatItem(null);

  /// 编辑或新增一个数值定义。index 为 null 表示新增。
  void _editStatItem(int? index) {
    final existing = index != null ? _statItems[index] : null;
    final keyCtrl = TextEditingController(text: existing?.key ?? '');
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final minCtrl = TextEditingController(
      text: existing != null ? _fmtNum(existing.min) : '0',
    );
    final maxCtrl = TextEditingController(
      text: existing != null ? _fmtNum(existing.max) : '100',
    );
    final initCtrl = TextEditingController(
      text: existing?.initial != null ? _fmtNum(existing!.initial!) : '',
    );
    final descCtrl = TextEditingController(text: existing?.description ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(index == null ? '添加数值' : '编辑数值'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDialogField(keyCtrl, '键（唯一，英文/拼音）', hint: '如 affection'),
              _buildDialogField(nameCtrl, '名称', hint: '如 好感度'),
              Row(
                children: [
                  Expanded(
                    child: _buildDialogField(
                      minCtrl,
                      '下限',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildDialogField(
                      maxCtrl,
                      '上限',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                    ),
                  ),
                ],
              ),
              _buildDialogField(
                initCtrl,
                '初始值（可空，默认取下限）',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
              ),
              _buildDialogField(descCtrl, '作用/含义', hint: '这个数值代表什么'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final key = keyCtrl.text.trim();
              if (key.isEmpty) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('键不能为空')));
                return;
              }
              var min = double.tryParse(minCtrl.text.trim()) ?? 0;
              var max = double.tryParse(maxCtrl.text.trim()) ?? 100;
              if (min > max) {
                final t = min;
                min = max;
                max = t;
              }
              final initial = initCtrl.text.trim().isEmpty
                  ? null
                  : double.tryParse(initCtrl.text.trim());
              final newItem = StatItem(
                key: key,
                name: nameCtrl.text.trim(),
                min: min,
                max: max,
                initial: initial,
                description: descCtrl.text.trim(),
              );
              setState(() {
                if (index == null) {
                  _statItems.add(newItem);
                } else {
                  _statItems[index] = newItem;
                }
              });
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildDialogField(
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildSection({String? title, required List<Widget> children}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(fontSize: 13, color: Color(0xFF888888)),
            ),
          ),
        Container(
          color: Colors.white,
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hintText,
    bool obscureText = false,
    bool readOnly = false,
    VoidCallback? onTap,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscureText,
              readOnly: readOnly,
              onTap: onTap,
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                hintText: hintText,
                border: InputBorder.none,
                isDense: true,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiModelField() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('AI模型', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: _availableAiModels.isEmpty
                ? TextField(
                    controller: _aiModelController,
                    decoration: const InputDecoration(
                      hintText: '填写模型名称',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    textAlign: TextAlign.right,
                  )
                : DropdownButtonFormField<String>(
                    initialValue:
                        _availableAiModels.contains(_aiModelController.text)
                        ? _aiModelController.text
                        : null,
                    decoration: const InputDecoration(
                      hintText: '选择模型',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items: _availableAiModels
                        .map(
                          (model) => DropdownMenuItem(
                            value: model,
                            child: Text(model, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) _aiModelController.text = value;
                    },
                  ),
          ),
          IconButton(
            tooltip: '从 API 获取模型',
            onPressed: _isLoadingAiModels ? null : _fetchAiModels,
            icon: _isLoadingAiModels
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildModelProfileSelector() {
    final profiles = SettingsService.instance.modelProfiles;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('本地档案', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _hasSelectedModelProfile
                  ? _selectedModelProfileId
                  : '',
              isExpanded: true,
              decoration: const InputDecoration(
                hintText: '选择 AI 接口设置中的档案',
                border: InputBorder.none,
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('不选择')),
                ...profiles.map(
                  (profile) => DropdownMenuItem(
                    value: profile.id,
                    child: Text(profile.name, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
              onChanged: (profileId) {
                if (profileId == null || profileId.isEmpty) {
                  setState(() => _selectedModelProfileId = null);
                  return;
                }
                final profile = profiles.firstWhere(
                  (item) => item.id == profileId,
                );
                _applyModelProfile(profile);
              },
            ),
          ),
        ],
      ),
    );
  }

  bool get _hasSelectedModelProfile {
    final selectedId = _selectedModelProfileId;
    return selectedId != null &&
        SettingsService.instance.modelProfiles.any(
          (profile) => profile.id == selectedId,
        );
  }

  int? get _selectedModelProfileContextLength {
    final selectedId = _selectedModelProfileId;
    if (selectedId == null) return null;
    for (final profile in SettingsService.instance.modelProfiles) {
      if (profile.id == selectedId) return profile.maxContextLength;
    }
    return null;
  }

  int get _effectiveMaxContextLength {
    final modelLength = _selectedModelProfileContextLength;
    return modelLength == null || _maxContextLength <= modelLength
        ? _maxContextLength
        : modelLength;
  }

  void _applyModelProfile(AiModelProfile profile) {
    _isApplyingModelProfile = true;
    _aiModelController.text = profile.model;
    _aiApiUrlController.text = profile.apiUrl;
    _aiApiKeyController.text = profile.apiKey;
    _aiTimeoutSeconds = profile.timeoutSeconds;
    _aiReasoningEffort = profile.reasoningEffort;
    _aiThinkingEnabled = profile.thinkingEnabled;
    _aiApiFormat = profile.apiFormat;
    _aiThinkingBudget = profile.thinkingBudget;
    _aiStream = profile.stream;
    _isApplyingModelProfile = false;
    setState(() => _selectedModelProfileId = profile.id);
  }

  void _clearModelProfileSelection() {
    if (_isApplyingModelProfile || _selectedModelProfileId == null) return;
    setState(() => _selectedModelProfileId = null);
  }

  Future<void> _fetchAiModels() async {
    final url = _aiApiUrlController.text.trim();
    final key = _aiApiKeyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写 API 地址和密钥')));
      return;
    }
    setState(() => _isLoadingAiModels = true);
    try {
      var modelsUrl = url.replaceFirst(RegExp(r'/chat/completions/?$'), '');
      modelsUrl = modelsUrl.replaceFirst(RegExp(r'/models/?$'), '');
      modelsUrl = modelsUrl.endsWith('/') ? modelsUrl : '$modelsUrl/';
      if (!modelsUrl.endsWith('v1/')) modelsUrl += 'v1/';
      modelsUrl += 'models';
      final response = await SecureBackendClient.getRaw(
        modelsUrl,
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
        },
        includeAuth: false,
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final models =
          ((data['data'] as List?) ?? [])
              .whereType<Map>()
              .map((item) => '${item['id'] ?? ''}'.trim())
              .where((item) => item.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      if (mounted) {
        setState(() {
          _availableAiModels = models;
          if (models.isNotEmpty && !models.contains(_aiModelController.text)) {
            _aiModelController.text = models.first;
          }
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取到 ${models.length} 个模型')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取模型列表失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoadingAiModels = false);
    }
  }

  void _resetToDefault() {
    setState(() {
      _maxContextRounds = 60;
      _maxContextLength = 12000;
    });
  }

  void _showEditContextLengthDialog() {
    final controller = TextEditingController(text: '$_maxContextLength');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('最大上下文长度'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            hintText: '输入字符数',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null && value > 0) {
                setState(() => _maxContextLength = value);
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showEditContextRoundsDialog() {
    final controller = TextEditingController(text: '$_maxContextRounds');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('最大上下文轮数'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            hintText: '输入轮数（每轮=用户+AI各一条）',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null && value > 0) {
                setState(() => _maxContextRounds = value);
              }
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  List<int> _parseIntList(String text) {
    return text
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .where((v) => v > 0)
        .toList();
  }

  Future<void> _saveRole() async {
    var parsedAiTemperature =
        double.tryParse(_aiTemperatureController.text.trim()) ??
        widget.role.aiTemperature;
    if (parsedAiTemperature < 0) parsedAiTemperature = 0;
    if (parsedAiTemperature > 2.0) parsedAiTemperature = 2.0;
    parsedAiTemperature = (parsedAiTemperature * 10).round() / 10;

    var parsedCycleLength =
        int.tryParse(_cycleLengthController.text.trim()) ??
        (widget.role.menstruationCycle['cycle_length'] as int? ?? 30);
    if (parsedCycleLength < 20) parsedCycleLength = 20;
    if (parsedCycleLength > 40) parsedCycleLength = 40;

    var parsedPeriodLength =
        int.tryParse(_periodLengthController.text.trim()) ??
        (widget.role.menstruationCycle['period_length'] as int? ?? 6);
    if (parsedPeriodLength < 3) parsedPeriodLength = 3;
    if (parsedPeriodLength > 6) parsedPeriodLength = 6;

    final parsedLastPeriodStart = _lastPeriodStartController.text.trim().isEmpty
        ? (widget.role.menstruationCycle['last_period_start']?.toString() ??
              '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}')
        : _lastPeriodStartController.text.trim();

    final updatedRole = widget.role.copyWith(
      name: _nameController.text,
      description: _descController.text,
      systemPrompt: _promptController.text,
      aiModel: _aiModelController.text.trim(),
      aiApiUrl: _aiApiUrlController.text.trim(),
      aiApiKey: _aiApiKeyController.text.trim(),
      aiTemperature: parsedAiTemperature,
      aiTimeoutSeconds: _aiTimeoutSeconds,
      aiReasoningEffort: _aiReasoningEffort,
      aiThinkingEnabled: _aiThinkingEnabled,
      aiApiFormat: _aiApiFormat,
      aiThinkingBudget: _aiThinkingBudget,
      clearThinkingOverrides: true,
      aiStream: _aiStream,
      gender: _gender,
      menstruationCycle: {
        'cycle_length': parsedCycleLength,
        'period_length': parsedPeriodLength,
        'last_period_start': parsedLastPeriodStart,
      },
      temperature: widget.role.temperature,
      topP: widget.role.topP,
      frequencyPenalty: widget.role.frequencyPenalty,
      presencePenalty: widget.role.presencePenalty,
      maxContextRounds: _maxContextRounds,
      maxContextLength: _maxContextLength,
      modelMaxContextLength: _selectedModelProfileContextLength,
      clearModelMaxContextLength: _selectedModelProfileContextLength == null,
      allowWebSearch: _allowWebSearch,
      onebotConfig: OneBotConfig(
        enabled: _onebotEnabled,
        secret: _onebotSecretController.text.trim(),
        selfId: int.tryParse(_onebotSelfIdController.text.trim()) ?? 0,
        mainUserId: int.tryParse(_onebotMainUserIdController.text.trim()) ?? 0,
        allowedUsers: _parseIntList(_onebotAllowedUsersController.text),
        allowedGroups: _parseIntList(_onebotAllowedGroupsController.text),
      ),
      statsConfig: StatsConfig(
        enabled: _statsEnabled,
        stats: List<StatItem>.from(_statItems),
      ),
      showAction: _showAction,
      showSound: _showSound,
      showPsychology: _showPsychology,
      showStats: _showStats,
      showNoReply: _showNoReply,
      archived: _archived,
    );
    await SettingsService.instance.setSelectedModelProfileForRole(
      updatedRole.id,
      _selectedModelProfileId,
    );
    if (!mounted) return;
    Navigator.pop(context, updatedRole);
  }
}
