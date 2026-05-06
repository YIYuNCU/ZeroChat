import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/onebot_config.dart';
import '../models/role.dart';

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
  late TextEditingController _cycleLengthController;
  late TextEditingController _periodLengthController;
  late TextEditingController _lastPeriodStartController;
  late String _gender;
  late int _maxContextRounds;
  late bool _allowWebSearch;
  late bool _onebotEnabled;
  late TextEditingController _onebotSecretController;
  late TextEditingController _onebotSelfIdController;
  late TextEditingController _onebotMainUserIdController;
  late TextEditingController _onebotAllowedUsersController;
  late TextEditingController _onebotAllowedGroupsController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.role.name);
    _descController = TextEditingController(text: widget.role.description);
    _promptController = TextEditingController(text: widget.role.systemPrompt);
    _aiModelController = TextEditingController(text: widget.role.aiModel);
    _aiApiUrlController = TextEditingController(text: widget.role.aiApiUrl);
    _aiApiKeyController = TextEditingController(text: widget.role.aiApiKey);
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
              _buildTextField(label: 'AI模型', controller: _aiModelController),
              const Divider(height: 1, indent: 16),
              _buildTextField(label: 'API地址', controller: _aiApiUrlController),
              const Divider(height: 1, indent: 16),
              _buildTextField(
                label: '密钥',
                controller: _aiApiKeyController,
                obscureText: true,
              ),
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
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
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
                    Row(
                      children: [
                        IconButton(
                          onPressed: _maxContextRounds > 1
                              ? () => setState(() => _maxContextRounds--)
                              : null,
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        Text(
                          '$_maxContextRounds',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        IconButton(
                          onPressed: _maxContextRounds < 60
                              ? () => setState(() => _maxContextRounds++)
                              : null,
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
                      activeColor: const Color(0xFF07C160),
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
                      activeColor: const Color(0xFF07C160),
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
                            final url =
                                '/onebot/ws/${widget.role.id}';
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

  void _resetToDefault() {
    setState(() {
      _maxContextRounds = 60;
    });
  }

  List<int> _parseIntList(String text) {
    return text
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .where((v) => v > 0)
        .toList();
  }

  void _saveRole() {
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
      allowWebSearch: _allowWebSearch,
      onebotConfig: OneBotConfig(
        enabled: _onebotEnabled,
        secret: _onebotSecretController.text.trim(),
        selfId: int.tryParse(_onebotSelfIdController.text.trim()) ?? 0,
        mainUserId: int.tryParse(_onebotMainUserIdController.text.trim()) ?? 0,
        allowedUsers: _parseIntList(_onebotAllowedUsersController.text),
        allowedGroups: _parseIntList(_onebotAllowedGroupsController.text),
      ),
    );
    Navigator.pop(context, updatedRole);
  }
}
