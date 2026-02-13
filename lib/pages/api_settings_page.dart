import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../services/settings_service.dart';

/// API 设置页面
/// 配置主聊天、意图识别、图像识别 API
class ApiSettingsPage extends StatefulWidget {
  const ApiSettingsPage({super.key});

  @override
  State<ApiSettingsPage> createState() => _ApiSettingsPageState();
}

class _ApiSettingsPageState extends State<ApiSettingsPage> {
  // 后端服务器
  late TextEditingController _backendUrlController;
  bool _isTestingConnection = false;
  bool? _connectionSuccess;
  String? _connectionError;

  // 模型列表
  List<String> _availableModels = [];
  bool _isLoadingModels = false;

  // 主聊天 API
  late TextEditingController _chatUrlController;
  late TextEditingController _chatKeyController;
  late TextEditingController _chatModelController;

  // 意图识别 API
  bool _intentEnabled = false;
  late TextEditingController _intentUrlController;
  late TextEditingController _intentKeyController;
  late TextEditingController _intentModelController;
  List<String> _intentModels = [];
  bool _isLoadingIntentModels = false;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;

    _backendUrlController = TextEditingController(text: settings.backendUrl);

    _chatUrlController = TextEditingController(text: settings.chatApiUrl);
    _chatKeyController = TextEditingController(text: settings.chatApiKey);
    _chatModelController = TextEditingController(text: settings.chatModel);

    _intentEnabled = settings.intentEnabled;
    _intentUrlController = TextEditingController(text: settings.intentApiUrl);
    _intentKeyController = TextEditingController(text: settings.intentApiKey);
    _intentModelController = TextEditingController(text: settings.intentModel);
  }

  @override
  void dispose() {
    _backendUrlController.dispose();
    _chatUrlController.dispose();
    _chatKeyController.dispose();
    _chatModelController.dispose();
    _intentUrlController.dispose();
    _intentKeyController.dispose();
    _intentModelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        elevation: 0,
        title: const Text('AI 接口设置'),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
        actions: [
          TextButton(
            onPressed: _saveSettings,
            child: const Text('保存', style: TextStyle(color: Color(0xFF07C160))),
          ),
        ],
      ),
      body: ListView(
        children: [
          const SizedBox(height: 10),

          // 后端服务器
          _buildSectionTitle('后端服务器'),
          _buildSection([
            _buildTextField(
              '服务器地址',
              _backendUrlController,
              'http://localhost:8000',
            ),
            _buildDivider(),
            _buildConnectionTestButton(),
          ]),

          const SizedBox(height: 20),

          // 主聊天 API
          _buildSectionTitle('主聊天 API'),
          _buildSection([
            _buildTextField(
              'API URL',
              _chatUrlController,
              'https://api.openai.com/v1',
            ),
            _buildDivider(),
            _buildTextField(
              'API Key',
              _chatKeyController,
              'sk-xxx',
              obscure: true,
            ),
            _buildDivider(),
            _buildApiConnectButton(),
            _buildDivider(),
            _buildModelSelector(),
          ]),

          const SizedBox(height: 20),

          // 意图识别 API
          _buildSectionTitle('意图识别 API'),
          _buildSection([
            _buildSwitchItem('启用意图识别', _intentEnabled, (v) {
              setState(() => _intentEnabled = v);
            }),
            if (_intentEnabled) ...[
              _buildDivider(),
              _buildTextField(
                'API URL',
                _intentUrlController,
                'https://api.openai.com/v1',
              ),
              _buildDivider(),
              _buildTextField(
                'API Key',
                _intentKeyController,
                'sk-xxx',
                obscure: true,
              ),
              _buildDivider(),
              _buildIntentModelFetchButton(),
              _buildDivider(),
              _buildIntentModelSelector(),
            ],
          ]),

          const SizedBox(height: 20),

          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 14, color: Color(0xFF888888)),
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      color: Colors.white,
      child: Column(children: children),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    String hint, {
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(fontSize: 15)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: Color(0xFFCCCCCC)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchItem(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 15)),
          Switch(
            value: value,
            activeColor: const Color(0xFF07C160),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return const Divider(height: 1, indent: 16);
  }

  Widget _buildConnectionTestButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isTestingConnection ? null : _testConnection,
              icon: _isTestingConnection
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _connectionSuccess == null
                          ? Icons.wifi_find
                          : (_connectionSuccess!
                                ? Icons.check_circle
                                : Icons.error),
                      size: 18,
                    ),
              label: Text(_isTestingConnection ? '测试中...' : '测试连接'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _connectionSuccess == true
                    ? const Color(0xFF07C160)
                    : (_connectionSuccess == false ? Colors.red : null),
                foregroundColor: _connectionSuccess != null
                    ? Colors.white
                    : null,
              ),
            ),
          ),
          if (_connectionError != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _connectionError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _testConnection() async {
    final url = _backendUrlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _connectionSuccess = false;
        _connectionError = '请输入服务器地址';
      });
      return;
    }

    setState(() {
      _isTestingConnection = true;
      _connectionSuccess = null;
      _connectionError = null;
    });

    try {
      debugPrint('Testing connection to: $url/api/health');
      final response = await http
          .get(Uri.parse('$url/api/health'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        setState(() {
          _connectionSuccess = true;
          _connectionError = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ 连接成功'),
              backgroundColor: Color(0xFF07C160),
            ),
          );
        }
      } else {
        setState(() {
          _connectionSuccess = false;
          _connectionError = 'HTTP ${response.statusCode}';
        });
      }
    } catch (e) {
      debugPrint('Connection test failed: $e');
      setState(() {
        _connectionSuccess = false;
        _connectionError = e.toString().length > 50
            ? '${e.toString().substring(0, 50)}...'
            : e.toString();
      });
    } finally {
      setState(() {
        _isTestingConnection = false;
      });
    }
  }

  /// 获取可用模型列表
  Future<void> _fetchModels() async {
    setState(() => _isLoadingModels = true);

    try {
      final backendUrl = _backendUrlController.text.trim();
      final response = await http.get(
        Uri.parse('$backendUrl/api/settings/models'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final models = List<String>.from(data['models'] ?? []);
          setState(() {
            _availableModels = models;
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch models: $e');
    } finally {
      setState(() => _isLoadingModels = false);
    }
  }

  Widget _buildApiConnectButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _isLoadingModels ? null : _fetchModels,
              icon: _isLoadingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download),
              label: Text(_isLoadingModels ? '获取中...' : '获取模型列表'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF07C160),
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('模型', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: _availableModels.isEmpty
                ? TextField(
                    controller: _chatModelController,
                    decoration: const InputDecoration(
                      hintText: 'gpt-3.5-turbo',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 16),
                  )
                : DropdownButtonFormField<String>(
                    value: _availableModels.contains(_chatModelController.text)
                        ? _chatModelController.text
                        : null,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    hint: const Text('选择模型'),
                    items: _availableModels.map((model) {
                      return DropdownMenuItem(
                        value: model,
                        child: Text(
                          model,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        _chatModelController.text = value;
                      }
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 意图识别模型获取按钮
  Widget _buildIntentModelFetchButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('模型列表', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _isLoadingIntentModels ? null : _fetchIntentModels,
              icon: _isLoadingIntentModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(_isLoadingIntentModels ? '获取中...' : '获取模型列表'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF07C160),
                side: const BorderSide(color: Color(0xFF07C160)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 意图识别模型选择器
  Widget _buildIntentModelSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('模型', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: _intentModels.isEmpty
                ? TextField(
                    controller: _intentModelController,
                    decoration: const InputDecoration(
                      hintText: 'gpt-3.5-turbo',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 16),
                  )
                : DropdownButtonFormField<String>(
                    value: _intentModels.contains(_intentModelController.text)
                        ? _intentModelController.text
                        : null,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    hint: const Text('选择模型'),
                    items: _intentModels.map((model) {
                      return DropdownMenuItem(
                        value: model,
                        child: Text(
                          model,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        _intentModelController.text = value;
                      }
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 获取意图识别模型列表
  Future<void> _fetchIntentModels() async {
    final url = _intentUrlController.text.trim();
    final key = _intentKeyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写 API URL 和 API Key')));
      return;
    }

    setState(() => _isLoadingIntentModels = true);

    try {
      // 构建模型列表请求 URL
      var modelsUrl = url;
      if (!modelsUrl.endsWith('/')) modelsUrl += '/';
      if (!modelsUrl.endsWith('v1/')) modelsUrl += 'v1/';
      modelsUrl += 'models';

      final response = await http
          .get(
            Uri.parse(modelsUrl),
            headers: {
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final models =
            (data['data'] as List).map((m) => m['id'].toString()).toList()
              ..sort();

        setState(() {
          _intentModels = models;
          _isLoadingIntentModels = false;
        });

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('获取到 ${models.length} 个模型')));
        }
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Fetch intent models error: $e');
      if (mounted) {
        setState(() => _isLoadingIntentModels = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取模型列表失败: $e')));
      }
    }
  }

  Future<void> _saveSettings() async {
    final settings = SettingsService.instance;

    // 保存后端服务器地址
    await settings.updateBackendUrl(_backendUrlController.text.trim());

    // 保存主聊天 API
    await settings.updateChatApi(
      url: _chatUrlController.text.trim(),
      key: _chatKeyController.text.trim(),
      model: _chatModelController.text.trim(),
    );

    // 保存意图识别 API
    await settings.updateIntentApi(
      enabled: _intentEnabled,
      url: _intentUrlController.text.trim(),
      key: _intentKeyController.text.trim(),
      model: _intentModelController.text.trim(),
    );

    // 自动同步到后端
    final synced = await settings.syncApiSettingsToBackend();
    debugPrint('API settings synced to backend: $synced');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(synced ? '设置已保存并同步' : '设置已保存（后端同步失败）'),
          duration: const Duration(seconds: 1),
        ),
      );
      Navigator.pop(context);
    }
  }
}
