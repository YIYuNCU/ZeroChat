import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/role_service.dart';
import '../services/settings_service.dart';
import '../services/secure_backend_client.dart';
import '../services/secure_websocket_client.dart';
import '../models/ai_model_profile.dart';

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
  late TextEditingController _backendTokenController;
  late TextEditingController _backendEncryptionSecretController;
  bool _backendTokenObscured = true;
  bool _backendEncryptionSecretObscured = true;
  bool _isTestingConnection = false;
  bool _isPullingBackendConfig = false;
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

  // 图像识别 API（全角色）
  bool _visionEnabled = false;
  late TextEditingController _visionUrlController;
  late TextEditingController _visionKeyController;
  late TextEditingController _visionModelController;
  String _visionMode = 'standalone';
  List<String> _visionModels = [];
  bool _isLoadingVisionModels = false;

  // 向量记忆 API
  bool _embeddingEnabled = false;
  late TextEditingController _embeddingUrlController;
  late TextEditingController _embeddingKeyController;
  late TextEditingController _embeddingModelController;
  List<String> _embeddingModels = [];
  bool _isLoadingEmbeddingModels = false;
  String? _testingApi;
  String? _selectedProfileId;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;

    _backendUrlController = TextEditingController(text: settings.backendUrl);
    _backendTokenController = TextEditingController(
      text: settings.backendAuthToken,
    );
    _backendEncryptionSecretController = TextEditingController(
      text: settings.backendEncryptionSecret,
    );
    _backendUrlController.addListener(_markConnectionDirty);
    _backendTokenController.addListener(_markConnectionDirty);
    _backendEncryptionSecretController.addListener(_markConnectionDirty);

    _chatUrlController = TextEditingController(text: settings.chatApiUrl);
    _chatKeyController = TextEditingController(text: settings.chatApiKey);
    _chatModelController = TextEditingController(text: settings.chatModel);
    _selectedProfileId =
        settings.modelProfiles.any(
          (p) =>
              p.apiUrl == settings.chatApiUrl && p.model == settings.chatModel,
        )
        ? settings.modelProfiles
              .firstWhere(
                (p) =>
                    p.apiUrl == settings.chatApiUrl &&
                    p.model == settings.chatModel,
              )
              .id
        : null;

    _intentEnabled = settings.intentEnabled;
    _intentUrlController = TextEditingController(text: settings.intentApiUrl);
    _intentKeyController = TextEditingController(text: settings.intentApiKey);
    _intentModelController = TextEditingController(text: settings.intentModel);

    _visionEnabled = settings.visionEnabled;
    _visionUrlController = TextEditingController(text: settings.visionApiUrl);
    _visionKeyController = TextEditingController(text: settings.visionApiKey);
    _visionModelController = TextEditingController(text: settings.visionModel);
    _visionMode = settings.visionMode;

    _embeddingEnabled = settings.embeddingEnabled;
    _embeddingUrlController = TextEditingController(
      text: settings.embeddingApiUrl,
    );
    _embeddingKeyController = TextEditingController(
      text: settings.embeddingApiKey,
    );
    _embeddingModelController = TextEditingController(
      text: settings.embeddingModel,
    );
  }

  @override
  void dispose() {
    _backendUrlController.dispose();
    _backendTokenController.dispose();
    _backendEncryptionSecretController.dispose();
    _chatUrlController.dispose();
    _chatKeyController.dispose();
    _chatModelController.dispose();
    _intentUrlController.dispose();
    _intentKeyController.dispose();
    _intentModelController.dispose();
    _visionUrlController.dispose();
    _visionKeyController.dispose();
    _visionModelController.dispose();
    _embeddingUrlController.dispose();
    _embeddingKeyController.dispose();
    _embeddingModelController.dispose();
    super.dispose();
  }

  void _markConnectionDirty() {
    if (_isTestingConnection) {
      return;
    }
    if (_connectionSuccess != null || _connectionError != null) {
      setState(() {
        _connectionSuccess = null;
        _connectionError = null;
      });
    }
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
            _buildTextField(
              'Token',
              _backendTokenController,
              '请填写后端鉴权 Token',
              obscure: _backendTokenObscured,
              onToggleObscure: () {
                setState(() {
                  _backendTokenObscured = !_backendTokenObscured;
                });
              },
            ),
            _buildDivider(),
            _buildTextField(
              '加密密钥',
              _backendEncryptionSecretController,
              '请填写后端传输加密密钥',
              obscure: _backendEncryptionSecretObscured,
              onToggleObscure: () {
                setState(() {
                  _backendEncryptionSecretObscured =
                      !_backendEncryptionSecretObscured;
                });
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '说明：服务器 Token 与加密密钥不会通过前端同步，需在后端手动配置。',
                style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
            ),
            _buildDivider(),
            _buildConnectionTestButton(),
            _buildDivider(),
            _buildPullBackendConfigButton(),
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
            _buildCurrentConfigTestButton('chat', '测试聊天配置'),
            _buildDivider(),
            _buildModelSelector(),
            _buildModelProfiles(),
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
              _buildCurrentConfigTestButton('intent', '测试意图配置'),
              _buildDivider(),
              _buildIntentModelSelector(),
            ],
          ]),

          const SizedBox(height: 20),

          // 图像识别 API
          _buildSectionTitle('图像识别 API'),
          _buildSection([
            _buildSwitchItem('启用图像识别模型', _visionEnabled, (v) {
              setState(() => _visionEnabled = v);
            }),
            if (_visionEnabled) ...[
              _buildDivider(),
              _buildTextField(
                'API URL',
                _visionUrlController,
                'https://api.openai.com/v1',
              ),
              _buildDivider(),
              _buildTextField(
                'API Key',
                _visionKeyController,
                'sk-xxx',
                obscure: true,
              ),
              _buildDivider(),
              _buildVisionModelFetchButton(),
              _buildDivider(),
              _buildCurrentConfigTestButton('vision', '测试视觉配置'),
              _buildDivider(),
              _buildVisionModelSelector(),
              _buildDivider(),
              _buildVisionModeSelector(),
            ],
          ]),

          const SizedBox(height: 20),

          // 向量记忆 API
          _buildSectionTitle('向量记忆 API (Embedding)'),
          _buildSection([
            _buildSwitchItem('启用向量记忆', _embeddingEnabled, (v) {
              setState(() => _embeddingEnabled = v);
            }),
            if (_embeddingEnabled) ...[
              _buildDivider(),
              _buildTextField(
                'API URL',
                _embeddingUrlController,
                'https://api.openai.com/v1',
              ),
              _buildDivider(),
              _buildTextField(
                'API Key',
                _embeddingKeyController,
                'sk-xxx',
                obscure: true,
              ),
              _buildDivider(),
              _buildEmbeddingModelFetchButton(),
              _buildDivider(),
              _buildCurrentConfigTestButton('embedding', '测试向量配置'),
              _buildDivider(),
              _buildEmbeddingModelSelector(),
            ],
          ]),

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
    VoidCallback? onToggleObscure,
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
                suffixIcon: onToggleObscure == null
                    ? null
                    : IconButton(
                        onPressed: onToggleObscure,
                        icon: Icon(
                          obscure ? Icons.visibility_off : Icons.visibility,
                          size: 18,
                          color: const Color(0xFF888888),
                        ),
                      ),
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

  Widget _buildVisionModeSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('运行模式', style: TextStyle(fontSize: 15)),
          ),
          Expanded(
            child: DropdownButtonFormField<String>(
              value:
                  const {
                    'standalone',
                    'pre_model',
                    'tool',
                  }.contains(_visionMode)
                  ? _visionMode
                  : 'standalone',
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: 'standalone',
                  child: Text('单独模型（直接输出）', style: TextStyle(fontSize: 14)),
                ),
                DropdownMenuItem(
                  value: 'pre_model',
                  child: Text(
                    '前置模型（识图后交给聊天模型）',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
                DropdownMenuItem(
                  value: 'tool',
                  child: Text(
                    '工具模式（AI 自主决定识图）',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _visionMode = value);
                }
              },
            ),
          ),
        ],
      ),
    );
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
    final token = _backendTokenController.text.trim();
    final encryptionSecret = _backendEncryptionSecretController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _connectionSuccess = false;
        _connectionError = '请输入服务器地址';
      });
      return;
    }

    // 测试连接时使用当前输入的安全配置
    SecureBackendClient.configureSecurity(
      authToken: token,
      encryptionSecret: encryptionSecret,
    );

    setState(() {
      _isTestingConnection = true;
      _connectionSuccess = null;
      _connectionError = null;
    });

    try {
      await _saveSettingsLocalOnly();
      await SecureWebSocketClient.instance.close();
      final response = await SecureWebSocketClient.instance.request(
        'health',
        const <String, dynamic>{},
        timeout: const Duration(seconds: 5),
      );

      if (response['status']?.toString() == 'healthy') {
        setState(() {
          _connectionSuccess = true;
          _connectionError = null;
        });
        unawaited(_refreshRolesAfterConnection());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ 连接成功（未自动同步）'),
              backgroundColor: Color(0xFF07C160),
            ),
          );
        }
      } else {
        setState(() {
          _connectionSuccess = false;
          _connectionError = '后端健康检查失败';
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

  Future<void> _refreshRolesAfterConnection() async {
    try {
      await RoleService.fetchFromBackend();
      debugPrint('ApiSettingsPage: roles refreshed after connection test');
    } catch (e) {
      debugPrint('ApiSettingsPage: refresh roles failed: $e');
    }
  }

  Widget _buildPullBackendConfigButton() {
    final canPull = _connectionSuccess == true && !_isTestingConnection;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: (canPull && !_isPullingBackendConfig)
                  ? _pullConfigFromBackend
                  : null,
              icon: _isPullingBackendConfig
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_sync, size: 18),
              label: Text(_isPullingBackendConfig ? '拉取中...' : '从后端读取配置（加密）'),
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

  Future<void> _pullConfigFromBackend() async {
    setState(() => _isPullingBackendConfig = true);
    try {
      // 确保使用当前页面输入的后端安全参数
      await _saveSettingsLocalOnly();
      await SecureWebSocketClient.instance.close();

      final ok = await SettingsService.instance.syncAllSettingsFromBackend();
      if (!ok) {
        throw Exception('后端未返回有效配置');
      }

      _reloadControllersFromSettings();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已从后端加密拉取配置并应用'),
            backgroundColor: Color(0xFF07C160),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('拉取后端配置失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isPullingBackendConfig = false);
      }
    }
  }

  void _reloadControllersFromSettings() {
    final settings = SettingsService.instance;
    setState(() {
      _chatUrlController.text = settings.chatApiUrl;
      _chatKeyController.text = settings.chatApiKey;
      _chatModelController.text = settings.chatModel;

      _intentEnabled = settings.intentEnabled;
      _intentUrlController.text = settings.intentApiUrl;
      _intentKeyController.text = settings.intentApiKey;
      _intentModelController.text = settings.intentModel;

      _visionEnabled = settings.visionEnabled;
      _visionUrlController.text = settings.visionApiUrl;
      _visionKeyController.text = settings.visionApiKey;
      _visionModelController.text = settings.visionModel;
      _visionMode = settings.visionMode;

      _embeddingEnabled = settings.embeddingEnabled;
      _embeddingUrlController.text = settings.embeddingApiUrl;
      _embeddingKeyController.text = settings.embeddingApiKey;
      _embeddingModelController.text = settings.embeddingModel;
    });
  }

  /// 获取可用模型列表
  Future<void> _fetchModels() async {
    final url = _chatUrlController.text.trim();
    final key = _chatKeyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写 API URL 和 API Key')));
      return;
    }

    setState(() => _isLoadingModels = true);

    try {
      var modelsUrl = url;
      if (!modelsUrl.endsWith('/')) modelsUrl += '/';
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

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final models =
            (data['data'] as List).map((m) => m['id'].toString()).toList()
              ..sort();

        setState(() {
          _availableModels = models;
          if (models.isNotEmpty &&
              !_availableModels.contains(_chatModelController.text)) {
            _chatModelController.text = models.first;
          }
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
      debugPrint('Failed to fetch chat models: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取模型列表失败: $e')));
      }
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

  Widget _buildCurrentConfigTestButton(String kind, String label) {
    final testing = _testingApi == kind;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _testingApi == null ? () => _testApiConfig(kind) : null,
          icon: testing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_circle_outline, size: 18),
          label: Text(testing ? '测试中...' : label),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF1677FF),
            side: const BorderSide(color: Color(0xFF1677FF)),
          ),
        ),
      ),
    );
  }

  Future<void> _testApiConfig(String kind) async {
    late final String url;
    late final String key;
    late final String model;
    switch (kind) {
      case 'chat':
        url = _chatUrlController.text.trim();
        key = _chatKeyController.text.trim();
        model = _chatModelController.text.trim();
        break;
      case 'intent':
        url = _intentUrlController.text.trim();
        key = _intentKeyController.text.trim();
        model = _intentModelController.text.trim();
        break;
      case 'vision':
        url = _visionUrlController.text.trim();
        key = _visionKeyController.text.trim();
        model = _visionModelController.text.trim();
        break;
      case 'embedding':
        url = _embeddingUrlController.text.trim();
        key = _embeddingKeyController.text.trim();
        model = _embeddingModelController.text.trim();
        break;
      default:
        return;
    }

    if (url.isEmpty || key.isEmpty || model.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写 API URL、API Key 和模型')));
      return;
    }

    setState(() => _testingApi = kind);
    try {
      final response = kind == 'embedding'
          ? await SecureBackendClient.postRawJson(
              _embeddingEndpoint(url),
              body: {'model': model, 'input': 'ZeroChat configuration test'},
              headers: {'Authorization': 'Bearer $key'},
              includeAuth: false,
              timeout: const Duration(seconds: 20),
            )
          : await SecureBackendClient.postRawJson(
              _chatEndpoint(url),
              body: _chatTestBody(kind, model),
              headers: {'Authorization': 'Bearer $key'},
              includeAuth: false,
              timeout: const Duration(seconds: 30),
            );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'HTTP ${response.statusCode}: ${_responseSummary(response.body)}',
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${_apiLabel(kind)} 配置可用')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_apiLabel(kind)} 测试失败: ${_responseSummary(error.toString())}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _testingApi = null);
    }
  }

  Map<String, dynamic> _chatTestBody(String kind, String model) {
    if (kind == 'vision') {
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
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (!path.endsWith('/chat/completions')) {
      path = path.endsWith('/v1')
          ? '$path/chat/completions'
          : '$path/v1/chat/completions';
    }
    return uri.replace(path: path, query: '', fragment: '').toString();
  }

  String _embeddingEndpoint(String value) {
    final uri = Uri.parse(value.trim());
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (path.endsWith('/chat/completions')) {
      path =
          '${path.substring(0, path.length - '/chat/completions'.length)}/embeddings';
    } else if (!path.endsWith('/embeddings')) {
      path = path.endsWith('/v1') ? '$path/embeddings' : '$path/v1/embeddings';
    }
    return uri.replace(path: path, query: '', fragment: '').toString();
  }

  String _apiLabel(String kind) {
    return switch (kind) {
      'chat' => '聊天 API',
      'intent' => '意图 API',
      'vision' => '视觉 API',
      'embedding' => '向量 API',
      _ => 'API',
    };
  }

  String _responseSummary(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length > 120
        ? '${normalized.substring(0, 120)}...'
        : normalized;
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

  Widget _buildModelProfiles() {
    final profiles = SettingsService.instance.modelProfiles;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text('本地配置档案', style: TextStyle(fontSize: 15)),
              ),
              TextButton.icon(
                onPressed: _saveCurrentModelProfile,
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('保存当前'),
              ),
            ],
          ),
        ),
        if (profiles.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '可保存多组模型、API 地址和密钥，随时切换。',
                style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
            ),
          )
        else
          ...profiles.map(
            (profile) => ListTile(
              dense: true,
              leading: Radio<String>(
                value: profile.id,
                groupValue: _selectedProfileId,
                onChanged: (_) => _applyModelProfile(profile),
              ),
              title: Text(profile.name),
              subtitle: Text(
                '${profile.model}  ·  ${profile.apiUrl}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '删除配置档案',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () async {
                  await SettingsService.instance.deleteModelProfile(profile.id);
                  if (mounted) setState(() {});
                },
              ),
              onTap: () => _applyModelProfile(profile),
            ),
          ),
      ],
    );
  }

  Future<void> _applyModelProfile(AiModelProfile profile) async {
    setState(() {
      _selectedProfileId = profile.id;
      _chatUrlController.text = profile.apiUrl;
      _chatModelController.text = profile.model;
      _chatKeyController.text = profile.apiKey;
    });
    await SettingsService.instance.updateChatApi(
      url: profile.apiUrl,
      key: profile.apiKey,
      model: profile.model,
    );
  }

  Future<void> _saveCurrentModelProfile() async {
    final nameController = TextEditingController(
      text: _chatModelController.text.trim(),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存模型配置档案'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '档案名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (name == null || name.isEmpty) return;
    final id = 'profile_${DateTime.now().microsecondsSinceEpoch}';
    await SettingsService.instance.saveModelProfile(
      id: id,
      name: name,
      url: _chatUrlController.text.trim(),
      model: _chatModelController.text.trim(),
      key: _chatKeyController.text.trim(),
    );
    if (mounted) setState(() => _selectedProfileId = id);
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

  /// 图像识别模型获取按钮
  Widget _buildVisionModelFetchButton() {
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
              onPressed: _isLoadingVisionModels ? null : _fetchVisionModels,
              icon: _isLoadingVisionModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(_isLoadingVisionModels ? '获取中...' : '获取模型列表'),
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

  /// 图像识别模型选择器
  Widget _buildVisionModelSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('模型', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: _visionModels.isEmpty
                ? TextField(
                    controller: _visionModelController,
                    decoration: const InputDecoration(
                      hintText: 'gpt-4o',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 16),
                  )
                : DropdownButtonFormField<String>(
                    value: _visionModels.contains(_visionModelController.text)
                        ? _visionModelController.text
                        : null,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    hint: const Text('选择模型'),
                    items: _visionModels.map((model) {
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
                        _visionModelController.text = value;
                      }
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 意图识别模型选择器
  /// 向量记忆模型获取按钮
  Widget _buildEmbeddingModelFetchButton() {
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
              onPressed: _isLoadingEmbeddingModels
                  ? null
                  : _fetchEmbeddingModels,
              icon: _isLoadingEmbeddingModels
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download, size: 18),
              label: Text(_isLoadingEmbeddingModels ? '获取中...' : '获取模型列表'),
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

  /// 向量记忆模型选择器
  Widget _buildEmbeddingModelSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 80,
            child: Text('模型', style: TextStyle(fontSize: 16)),
          ),
          Expanded(
            child: _embeddingModels.isEmpty
                ? TextField(
                    controller: _embeddingModelController,
                    decoration: const InputDecoration(
                      hintText: 'text-embedding-3-small',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 16),
                  )
                : DropdownButtonFormField<String>(
                    value:
                        _embeddingModels.contains(
                          _embeddingModelController.text,
                        )
                        ? _embeddingModelController.text
                        : null,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    hint: const Text('选择模型'),
                    items: _embeddingModels.map((model) {
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
                        _embeddingModelController.text = value;
                      }
                    },
                  ),
          ),
        ],
      ),
    );
  }

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
      modelsUrl = modelsUrl.replaceFirst(RegExp(r'/chat/completions/?$'), '');
      modelsUrl = modelsUrl.replaceFirst(RegExp(r'/models/?$'), '');
      if (!modelsUrl.endsWith('/')) modelsUrl += '/';
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

  /// 获取图像识别模型列表
  Future<void> _fetchVisionModels() async {
    final url = _visionUrlController.text.trim();
    final key = _visionKeyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写 API URL 和 API Key')));
      return;
    }

    setState(() => _isLoadingVisionModels = true);

    try {
      var modelsUrl = url;
      if (!modelsUrl.endsWith('/')) modelsUrl += '/';
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

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final models =
            (data['data'] as List).map((m) => m['id'].toString()).toList()
              ..sort();

        setState(() {
          _visionModels = models;
          if (models.isNotEmpty &&
              !_visionModels.contains(_visionModelController.text)) {
            _visionModelController.text = models.first;
          }
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
      debugPrint('Fetch vision models error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取模型列表失败: $e')));
      }
    } finally {
      setState(() => _isLoadingVisionModels = false);
    }
  }

  /// 获取向量记忆模型列表
  Future<void> _fetchEmbeddingModels() async {
    final url = _embeddingUrlController.text.trim();
    final key = _embeddingKeyController.text.trim();

    if (url.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写 API URL 和 API Key')));
      return;
    }

    setState(() => _isLoadingEmbeddingModels = true);

    try {
      var modelsUrl = url;
      if (!modelsUrl.endsWith('/')) modelsUrl += '/';
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

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final models =
            (data['data'] as List).map((m) => m['id'].toString()).toList()
              ..sort();

        setState(() {
          _embeddingModels = models;
          if (models.isNotEmpty &&
              !_embeddingModels.contains(_embeddingModelController.text)) {
            _embeddingModelController.text = models.first;
          }
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
      debugPrint('Fetch embedding models error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取模型列表失败: $e')));
      }
    } finally {
      setState(() => _isLoadingEmbeddingModels = false);
    }
  }

  Future<void> _saveSettings() async {
    await _saveSettingsLocalOnly();

    final synced = await SettingsService.instance.syncApiSettingsToBackend();
    if (synced) {
      if (mounted) {
        setState(() {
          _connectionSuccess = true;
          _connectionError = null;
        });
      }
    }

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

  Future<void> _saveSettingsLocalOnly() async {
    final settings = SettingsService.instance;

    // 保存后端服务器地址
    await settings.updateBackendUrl(_backendUrlController.text.trim());

    // 保存主聊天 API
    await settings.updateChatApi(
      url: _chatUrlController.text.trim(),
      key: _chatKeyController.text.trim(),
      model: _chatModelController.text.trim(),
    );

    // 保存后端鉴权与加密配置
    await settings.updateBackendSecurity(
      authToken: _backendTokenController.text.trim(),
      encryptionSecret: _backendEncryptionSecretController.text.trim(),
    );

    // 保存意图识别 API
    await settings.updateIntentApi(
      enabled: _intentEnabled,
      url: _intentUrlController.text.trim(),
      key: _intentKeyController.text.trim(),
      model: _intentModelController.text.trim(),
    );

    // 保存图像识别 API
    await settings.updateVisionApi(
      enabled: _visionEnabled,
      url: _visionUrlController.text.trim(),
      key: _visionKeyController.text.trim(),
      model: _visionModelController.text.trim(),
      mode: _visionMode,
    );

    // 保存向量记忆 API
    await settings.updateEmbeddingApi(
      enabled: _embeddingEnabled,
      url: _embeddingUrlController.text.trim(),
      key: _embeddingKeyController.text.trim(),
      model: _embeddingModelController.text.trim(),
    );
  }
}
