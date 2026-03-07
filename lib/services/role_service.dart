import 'package:flutter/foundation.dart';
import '../models/role.dart';
import 'storage_service.dart';
import 'memory_service.dart';
import 'settings_service.dart';
import 'secure_backend_client.dart';

/// 角色管理服务
/// 管理 AI 角色的创建、切换和持久化
class RoleService {
  static final List<Role> _roles = [];
  static String _currentRoleId = 'default';

  /// 初始化角色服务
  static Future<void> init() async {
    await _loadRoles();
    // 如果本地无角色，从后端获取
    if (_roles.isEmpty) {
      debugPrint('RoleService: No local roles, fetching from backend...');
      await fetchFromBackend();
    }
    debugPrint('RoleService initialized with ${_roles.length} roles');
  }

  /// 加载角色列表
  static Future<void> _loadRoles() async {
    final jsonList = StorageService.getJsonList(StorageService.keyRoles);
    if (jsonList != null) {
      _roles.clear();
      for (final json in jsonList) {
        try {
          _roles.add(Role.fromJson(json));
        } catch (e) {
          debugPrint('Error loading role: $e');
        }
      }
    }
    _currentRoleId =
        StorageService.getString(StorageService.keyCurrentRoleId) ?? 'default';
  }

  /// 保存角色列表
  static Future<void> _saveRoles() async {
    final jsonList = _roles.map((r) => r.toJson()).toList();
    await StorageService.setJsonList(StorageService.keyRoles, jsonList);
    await StorageService.setString(
      StorageService.keyCurrentRoleId,
      _currentRoleId,
    );
  }

  /// 获取所有角色
  static List<Role> getAllRoles() {
    return List.unmodifiable(_roles);
  }

  /// 获取当前角色
  static Role getCurrentRole() {
    return _roles.firstWhere(
      (r) => r.id == _currentRoleId,
      orElse: () => _roles.isNotEmpty ? _roles.first : Role.defaultRole(),
    );
  }

  /// 获取当前角色 ID
  static String get currentRoleId => _currentRoleId;

  /// 切换当前角色
  static Future<void> setCurrentRole(String roleId) async {
    if (_roles.any((r) => r.id == roleId)) {
      _currentRoleId = roleId;
      await StorageService.setString(StorageService.keyCurrentRoleId, roleId);
      debugPrint('Switched to role: $roleId');
    }
  }

  /// 根据 ID 获取角色
  static Role? getRoleById(String id) {
    try {
      return _roles.firstWhere((r) => r.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 添加角色
  static Future<void> addRole(Role role) async {
    // 检查 ID 是否重复
    _roles.removeWhere((r) => r.id == role.id);
    _roles.add(role);
    await _saveRoles();
    // 自动同步到后端（失败不影响本地）
    try {
      await syncRoleToBackend(role);
      debugPrint('Added role: ${role.name} (synced to backend)');
    } catch (e) {
      debugPrint(
        'Added role: ${role.name} (backend sync failed: $e, local only)',
      );
    }
  }

  /// 更新角色
  static Future<void> updateRole(Role role) async {
    final index = _roles.indexWhere((r) => r.id == role.id);
    if (index != -1) {
      _roles[index] = role;
      await _saveRoles();
      // 自动同步到后端（失败不影响本地）
      try {
        await syncRoleToBackend(role);
      } catch (e) {
        debugPrint('RoleService: updateRole backend sync failed: $e');
      }
    }
  }

  /// 删除角色
  static Future<void> deleteRole(String roleId) async {
    if (roleId == 'default') {
      debugPrint('Cannot delete default role');
      return;
    }
    _roles.removeWhere((r) => r.id == roleId);
    // 如果删除的是当前角色，切换到默认角色
    if (_currentRoleId == roleId) {
      _currentRoleId = 'default';
    }
    // 同时清除该角色的短期记忆
    MemoryService.clearShortTermMemory(roleId);
    await _saveRoles();
    // 自动从后端删除（失败不影响本地已删除状态）
    try {
      await SecureBackendClient.delete('$_backendUrl/api/roles/$roleId');
      debugPrint('Deleted role: $roleId (synced to backend)');
    } catch (e) {
      debugPrint(
        'Deleted role: $roleId (backend delete failed: $e, local only)',
      );
    }
  }

  /// 创建新角色
  static Future<Role> createRole({
    required String name,
    required String systemPrompt,
    String description = '',
    double temperature = 0.7,
    double topP = 1.0,
    double frequencyPenalty = 0.0,
    double presencePenalty = 0.0,
    int maxContextRounds = 10,
  }) async {
    final role = Role(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      description: description,
      systemPrompt: systemPrompt,
      temperature: temperature,
      topP: topP,
      frequencyPenalty: frequencyPenalty,
      presencePenalty: presencePenalty,
      maxContextRounds: maxContextRounds,
    );
    await addRole(role);
    return role;
  }

  /// 获取角色数量
  static int get roleCount => _roles.length;

  // ========== 后端同步 ==========

  /// 获取后端 URL
  static String get _backendUrl => SettingsService.instance.backendUrl;

  /// 从后端获取角色列表
  static Future<bool> fetchFromBackend() async {
    try {
      final secureResponse = await SecureBackendClient.get(
        '$_backendUrl/api/roles',
      );
      final response = secureResponse.isSuccess
          ? secureResponse.data as Map<String, dynamic>?
          : null;
      if (response != null && response['roles'] != null) {
        final List<dynamic> rolesJson = response['roles'];
        for (final json in rolesJson) {
          try {
            // 解析 core_memory
            List<String> coreMemory = [];
            if (json['core_memory'] != null) {
              coreMemory = (json['core_memory'] as List).cast<String>();
            }

            // 转换后端格式到本地 Role 格式
            final backendRole = Role(
              id: json['id'] ?? '',
              name: json['name'] ?? '',
              description: json['description'] ?? '',
              systemPrompt: json['system_prompt'] ?? '',
              avatarUrl: json['avatar_url'] ?? '',
              avatarHash: json['avatar_hash'] ?? '',
              aiModel: json['ai_model'] ?? 'deepseek-chat',
              aiApiUrl: json['ai_api_url'] ?? '',
              aiApiKey: json['ai_api_key'] ?? '',
              aiTemperature:
                  (json['ai_temperature'] as num?)?.toDouble() ?? 0.7,
              gender: json['gender'] ?? 'men',
              menstruationCycle:
                  (json['menstruation_cycle'] as Map<String, dynamic>?) ??
                  const {
                    'cycle_length': 30,
                    'period_length': 6,
                    'last_period_start': '2026-01-24',
                  },
              temperature:
                  (json['temperature'] as num?)?.toDouble() ??
                  (json['ai_temperature'] as num?)?.toDouble() ??
                  0.7,
              topP: 1.0,
              frequencyPenalty: 0.0,
              presencePenalty: 0.0,
              maxContextRounds: 10,
              coreMemory: coreMemory,
            );

            // 更新或添加角色（保留本地专有字段）
            final existingIndex = _roles.indexWhere(
              (r) => r.id == backendRole.id,
            );
            if (existingIndex != -1) {
              final existing = _roles[existingIndex];
              // 合并：用后端的基础信息（名称、描述、头像、系统提示词、核心记忆），
              // 保留本地的所有AI参数和高级配置
              _roles[existingIndex] = existing.copyWith(
                name: backendRole.name,
                description: backendRole.description,
                systemPrompt: backendRole.systemPrompt,
                avatarUrl: backendRole.avatarUrl,
                avatarHash: backendRole.avatarHash,
                coreMemory: backendRole.coreMemory,
                aiModel: backendRole.aiModel,
                aiApiUrl: backendRole.aiApiUrl,
                aiApiKey: backendRole.aiApiKey,
                aiTemperature: backendRole.aiTemperature,
                gender: backendRole.gender,
                menstruationCycle: backendRole.menstruationCycle,
                temperature: backendRole.temperature,
              );
            } else {
              _roles.add(backendRole);
            }
          } catch (e) {
            debugPrint('RoleService: Error parsing backend role: $e');
          }
        }
        await _saveRoles();
        debugPrint(
          'RoleService: Synced ${rolesJson.length} roles from backend',
        );
        return true;
      }
    } catch (e) {
      debugPrint('RoleService: Backend fetch failed: $e');
    }
    return false;
  }

  /// 同步单个角色到后端
  static Future<bool> syncRoleToBackend(Role role) async {
    try {
      final response =
          await SecureBackendClient.post('$_backendUrl/api/roles', {
            'id': role.id,
            'name': role.name,
            'description': role.description,
            'system_prompt': role.systemPrompt,
            'avatar_url': role.avatarUrl,
            'persona': role.description,
            'core_memory': role.coreMemory,
            'ai_model': role.aiModel,
            'ai_api_url': role.aiApiUrl,
            'ai_api_key': role.aiApiKey,
            'ai_temperature': role.aiTemperature,
            'gender': role.gender,
            'menstruation_cycle': role.menstruationCycle,
            'temperature': role.temperature,
          });
      return response.isSuccess;
    } catch (e) {
      debugPrint('RoleService: Sync to backend failed: $e');
      return false;
    }
  }

  /// 同步所有角色到后端
  static Future<void> syncAllToBackend() async {
    for (final role in _roles) {
      await syncRoleToBackend(role);
    }
    debugPrint('RoleService: Synced ${_roles.length} roles to backend');
  }
}
