import 'package:flutter/material.dart';
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
  late double _temperature;
  late double _topP;
  late double _frequencyPenalty;
  late double _presencePenalty;
  late int _maxContextRounds;
  late bool _allowWebSearch;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.role.name);
    _descController = TextEditingController(text: widget.role.description);
    _promptController = TextEditingController(text: widget.role.systemPrompt);
    _temperature = widget.role.temperature;
    _topP = widget.role.topP;
    _frequencyPenalty = widget.role.frequencyPenalty;
    _presencePenalty = widget.role.presencePenalty;
    _maxContextRounds = widget.role.maxContextRounds;
    _allowWebSearch = widget.role.allowWebSearch;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _promptController.dispose();
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

          // AI 参数
          _buildSection(
            title: 'AI 参数',
            children: [
              _buildSliderItem(
                label: 'Temperature',
                value: _temperature,
                min: 0.0,
                max: 2.0,
                description: '控制回复的随机性。低值更确定，高值更创意。',
                onChanged: (v) => setState(() => _temperature = v),
              ),
              const Divider(height: 1, indent: 16),
              _buildSliderItem(
                label: 'Top P',
                value: _topP,
                min: 0.0,
                max: 1.0,
                description: '核采样参数。1.0 使用所有可能的词。',
                onChanged: (v) => setState(() => _topP = v),
              ),
              const Divider(height: 1, indent: 16),
              _buildSliderItem(
                label: 'Frequency Penalty',
                value: _frequencyPenalty,
                min: -2.0,
                max: 2.0,
                description: '降低重复词语的概率。正值减少重复。',
                onChanged: (v) => setState(() => _frequencyPenalty = v),
              ),
              const Divider(height: 1, indent: 16),
              _buildSliderItem(
                label: 'Presence Penalty',
                value: _presencePenalty,
                min: -2.0,
                max: 2.0,
                description: '鼓励谈论新话题。正值增加多样性。',
                onChanged: (v) => setState(() => _presencePenalty = v),
              ),
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
                          onPressed: _maxContextRounds < 50
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

  Widget _buildSliderItem({
    required String label,
    required double value,
    required double min,
    required double max,
    required String description,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 16)),
              Text(
                value.toStringAsFixed(2),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF07C160),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            activeColor: const Color(0xFF07C160),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  void _resetToDefault() {
    setState(() {
      _temperature = 0.7;
      _topP = 1.0;
      _frequencyPenalty = 0.0;
      _presencePenalty = 0.0;
      _maxContextRounds = 10;
    });
  }

  void _saveRole() {
    final updatedRole = widget.role.copyWith(
      name: _nameController.text,
      description: _descController.text,
      systemPrompt: _promptController.text,
      temperature: _temperature,
      topP: _topP,
      frequencyPenalty: _frequencyPenalty,
      presencePenalty: _presencePenalty,
      maxContextRounds: _maxContextRounds,
      allowWebSearch: _allowWebSearch,
    );
    Navigator.pop(context, updatedRole);
  }
}
