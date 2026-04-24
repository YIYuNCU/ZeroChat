import 'package:flutter/material.dart';
import '../services/settings_service.dart';

/// 全局提示词设置页面
/// 配置 Base / Group / Memory 提示词
class GlobalPromptsPage extends StatefulWidget {
  const GlobalPromptsPage({super.key});

  @override
  State<GlobalPromptsPage> createState() => _GlobalPromptsPageState();
}

class _GlobalPromptsPageState extends State<GlobalPromptsPage> {
  late TextEditingController _baseController;
  late TextEditingController _groupController;
  late TextEditingController _memoryController;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;
    _baseController = TextEditingController(text: settings.basePrompt);
    _groupController = TextEditingController(text: settings.groupPrompt);
    _memoryController = TextEditingController(text: settings.memoryPrompt);
  }

  @override
  void dispose() {
    _baseController.dispose();
    _groupController.dispose();
    _memoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('全局提示词'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          TextButton(
            onPressed: _savePrompts,
            child: const Text('保存', style: TextStyle(color: Color(0xFF07C160))),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Base Prompt
          _buildPromptSection(
            title: 'Base Prompt',
            description: '基础角色扮演提示词，对所有角色生效',
            controller: _baseController,
            hint: '例如：你是一个AI助手，请以友好自然的方式与用户对话...',
          ),

          const SizedBox(height: 24),

          // Group Prompt
          _buildPromptSection(
            title: 'Group Prompt',
            description: '群聊专用提示词，在群聊场景下追加使用',
            controller: _groupController,
            hint: '例如：这是一个群聊环境，请注意区分不同发言者...',
          ),

          const SizedBox(height: 24),

          // Memory Prompt
          _buildPromptSection(
            title: 'Memory Prompt',
            description: '记忆总结提示词，AI 根据此提示提取和总结记忆',
            controller: _memoryController,
            hint: '例如：请根据对话内容提取关键信息并总结为简短记忆条目...',
          ),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildPromptSection({
    required String title,
    required String description,
    required TextEditingController controller,
    required String hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Color(0xFF07C160),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: TextField(
            controller: controller,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(
                color: Color(0xFFCCCCCC),
                fontSize: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ),
      ],
    );
  }

  Future<void> _savePrompts() async {
    await SettingsService.instance.updatePrompts(
      basePrompt: _baseController.text.trim(),
      groupPrompt: _groupController.text.trim(),
      memoryPrompt: _memoryController.text.trim(),
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('提示词已保存'), duration: Duration(seconds: 1)),
      );
      Navigator.pop(context);
    }
  }
}
