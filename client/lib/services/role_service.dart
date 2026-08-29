import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../models/onebot_config.dart';
import '../models/proactive_config.dart';
import '../models/followup_config.dart';
import '../models/role.dart';
import '../models/stats_config.dart';
import '../core/message_store.dart';
import 'avatar_cache_service.dart';
import 'sticker_service.dart';
import 'storage_service.dart';
import 'memory_service.dart';
import 'chat_list_service.dart';
import 'secure_websocket_client.dart';

/// 角色管理服务
/// 管理 AI 角色的创建、切换和持久化
class RoleService {
  static final List<Role> _roles = [];
  static String _currentRoleId = 'default';
  static const String _toolRolePrefix = '1000000000';
  static const String _proactiveConfigMigrationKey =
      'proactive_config_server_sync_v1';

  /// 本地角色列表 hash（与后端 roles_hash 比对，避免无变化时全量拉取）
  static String _localRolesHash = '';

  /// 进行中的角色同步（in-flight 去重）
  static Future<bool>? _inFlightSync;

  /// 上次成功发起角色同步的时间（TTL 节流）
  static DateTime? _lastSyncAt;
  static const Duration _syncThrottle = Duration(seconds: 30);

  static String _normalizeAvatarUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('/api/roles/') && trimmed.endsWith('/avatar/file')) {
      return trimmed
          .replaceFirst('/api/roles/', '/files/roles/')
          .replaceFirst('/avatar/file', '/avatar');
    }
    return trimmed;
  }

  static bool isToolRoleId(String? roleId) {
    return (roleId ?? '').startsWith(_toolRolePrefix);
  }

  /// 初始化角色服务
  static Future<void> init() async {
    await _loadRoles();
    // 启动阶段只做本地初始化；后端同步由 main.dart 在后台触发。
    debugPrint('RoleService initialized with ${_roles.length} roles');
  }

  /// 加载角色列表
  static Future<void> _loadRoles() async {
    final jsonList = StorageService.getJsonList(StorageService.keyRoles);
    if (jsonList != null) {
      _roles.clear();
      for (final json in jsonList) {
        try {
          final role = Role.fromJson(json);
          _roles.add(
            role.copyWith(avatarUrl: _normalizeAvatarUrl(role.avatarUrl ?? '')),
          );
        } catch (e) {
          debugPrint('Error loading role: $e');
        }
      }
    }
    _currentRoleId =
        StorageService.getString(StorageService.keyCurrentRoleId) ?? 'default';
    if (!_roles.any((r) => r.id == _currentRoleId)) {
      _currentRoleId = _roles.isNotEmpty ? _roles.first.id : 'default';
    }
    _localRolesHash =
        StorageService.getString(StorageService.keyRolesHash) ?? '';
  }

  /// 保存角色列表
  /// [backendHash] 若提供（来自后端同步），直接采用；否则本地计算。
  static Future<void> _saveRoles({String? backendHash}) async {
    final jsonList = _roles.map((r) => r.toJson()).toList();
    await StorageService.setJsonList(StorageService.keyRoles, jsonList);
    await StorageService.setString(
      StorageService.keyCurrentRoleId,
      _currentRoleId,
    );
    _localRolesHash = (backendHash != null && backendHash.isNotEmpty)
        ? backendHash
        : _computeRolesHash(jsonList);
    await StorageService.setString(
      StorageService.keyRolesHash,
      _localRolesHash,
    );
  }

  /// 计算角色列表的稳定 SHA256（与后端 compute_roles_hash 对应）
  /// 注意：本地哈希仅用于"本地是否变化"的判定，不要求与后端逐字节相等；
  /// 后端一致性由 syncIfHashMismatch 从后端下发的 hash 覆盖保证。
  static String _computeRolesHash(List<Map<String, dynamic>> jsonList) {
    final canonical = jsonEncode(jsonList);
    return sha256.convert(utf8.encode(canonical)).toString();
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
      await MemoryService.refreshCoreMemoryFromBackend(roleId: roleId);
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

  /// 仅更新本地角色对象并持久化（不触发后端 upsert）。
  /// 用于调用方已通过更专用的接口（如 roles_memory_update）把该字段写入后端，
  /// 只需同步本地缓存，避免多余的整角色 upsert 往返。
  static Future<void> updateRoleLocal(Role role) async {
    final index = _roles.indexWhere((r) => r.id == role.id);
    if (index != -1) {
      _roles[index] = role;
      await _saveRoles();
    }
  }

  /// 是否允许删除该角色（默认角色与工具角色受保护）
  static bool canDeleteRole(String roleId) {
    return roleId != 'default' && !isToolRoleId(roleId);
  }

  /// 删除角色（好友），并清理所有相关本地数据
  /// 返回 true 表示删除成功，false 表示该角色受保护不可删除
  static Future<bool> deleteRole(String roleId) async {
    if (!canDeleteRole(roleId)) {
      debugPrint('Cannot delete protected role: $roleId');
      return false;
    }
    _roles.removeWhere((r) => r.id == roleId);
    // 如果删除的是当前角色，切换到默认角色
    if (_currentRoleId == roleId) {
      _currentRoleId = 'default';
    }
    await _saveRoles();

    // 清理该角色的所有本地数据
    // 1. 短期记忆
    MemoryService.clearShortTermMemory(roleId);
    // 2. 聊天记录（持久化的消息）
    try {
      await MessageStore.instance.removeChatData(roleId);
    } catch (e) {
      debugPrint('RoleService: clearMessages failed for $roleId: $e');
    }
    // 3. 从聊天列表移除
    ChatListService.instance.removeFromList(roleId);
    // 4. 前端 JSON 记忆
    try {
      await MemoryService.clearJsonMemory(roleId);
    } catch (e) {
      debugPrint('RoleService: clearJsonMemory failed for $roleId: $e');
    }
    // 5. 头像磁盘缓存（含 role_<id>_avatar 及其 moments 变体）
    try {
      await AvatarCacheService.evictByPrefix('role_${roleId}_avatar');
    } catch (e) {
      debugPrint('RoleService: avatar evict failed for $roleId: $e');
    }
    // 6. 表情包目录 stickers/<roleId>/
    try {
      await StickerService.clearRoleStickers(roleId);
    } catch (e) {
      debugPrint('RoleService: clearRoleStickers failed for $roleId: $e');
    }

    // 自动从后端删除（失败不影响本地已删除状态）
    try {
      await SecureWebSocketClient.instance.request('roles_delete', {
        'role_id': roleId,
      });
      debugPrint('Deleted role: $roleId (synced to backend)');
    } catch (e) {
      debugPrint(
        'Deleted role: $roleId (backend delete failed: $e, local only)',
      );
    }
    return true;
  }

  /// 复制角色（好友）
  /// 后端从源角色复制出一个新角色，继承全部设定但不带旧记忆。
  /// 成功返回新角色，失败返回 null。
  static Future<Role?> cloneRole(String sourceId, {String? newName}) async {
    try {
      final response = await SecureWebSocketClient.instance
          .request('roles_clone', {
            'role_id': sourceId,
            if (newName != null && newName.trim().isNotEmpty)
              'new_name': newName.trim(),
          });
      final roleJson = response['role'];
      if (roleJson is! Map) {
        debugPrint('RoleService: cloneRole returned no role');
        return null;
      }
      final json = Map<String, dynamic>.from(roleJson);
      final cloned = Role.fromJson(json).copyWith(
        avatarUrl: _normalizeAvatarUrl(json['avatar_url']?.toString() ?? ''),
      );
      _roles.removeWhere((r) => r.id == cloned.id);
      _roles.add(cloned);
      await _saveRoles();
      debugPrint('RoleService: Cloned role ${cloned.id} from $sourceId');
      return cloned;
    } catch (e) {
      debugPrint('RoleService: cloneRole failed: $e');
      return null;
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
    int maxContextRounds = 60,
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

  /// 从后端获取角色列表
  static Future<bool> fetchFromBackend() async {
    try {
      final response = await SecureWebSocketClient.instance.request(
        'roles_list',
        const <String, dynamic>{},
      );
      if (response['roles'] != null) {
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
              avatarUrl: _normalizeAvatarUrl(
                json['avatar_url']?.toString() ?? '',
              ),
              avatarHash: json['avatar_hash'] ?? '',
              chatBackgroundUrl: json['chat_background_url'] ?? '',
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
              maxContextRounds: 60,
              coreMemory: coreMemory,
              onebotConfig: json['onebot_config'] != null
                  ? OneBotConfig.fromJson(
                      json['onebot_config'] as Map<String, dynamic>,
                    )
                  : null,
              statsConfig: json['stats_config'] != null
                  ? StatsConfig.fromJson(
                      json['stats_config'] as Map<String, dynamic>,
                    )
                  : null,
              showAction: json['show_action'] as bool? ?? true,
              showSound: json['show_sound'] as bool? ?? true,
              showPsychology: json['show_psychology'] as bool? ?? true,
              showStats: json['show_stats'] as bool? ?? true,
              showNoReply: json['show_no_reply'] as bool? ?? false,
              archived: json['archived'] as bool? ?? false,
              proactiveConfig: json['proactive_config'] is Map
                  ? ProactiveConfig.fromJson(
                      Map<String, dynamic>.from(
                        json['proactive_config'] as Map,
                      ),
                    )
                  : const ProactiveConfig(),
              followupConfig: json['followup_config'] is Map
                  ? FollowupConfig.fromJson(
                      Map<String, dynamic>.from(
                        json['followup_config'] as Map,
                      ),
                    )
                  : const FollowupConfig(),
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
                chatBackgroundUrl: backendRole.chatBackgroundUrl.isNotEmpty
                    ? backendRole.chatBackgroundUrl
                    : existing.chatBackgroundUrl,
                coreMemory: backendRole.coreMemory,
                aiModel: backendRole.aiModel,
                aiApiUrl: backendRole.aiApiUrl,
                aiApiKey: backendRole.aiApiKey,
                aiTemperature: backendRole.aiTemperature,
                gender: backendRole.gender,
                menstruationCycle: backendRole.menstruationCycle,
                temperature: backendRole.temperature,
                onebotConfig: backendRole.onebotConfig,
                statsConfig: backendRole.statsConfig,
                showAction: backendRole.showAction,
                showPsychology: backendRole.showPsychology,
                showStats: backendRole.showStats,
                showNoReply: backendRole.showNoReply,
                archived: backendRole.archived,
                proactiveConfig: backendRole.proactiveConfig,
                followupConfig: backendRole.followupConfig,
              );
            } else {
              _roles.add(backendRole);
            }
          } catch (e) {
            debugPrint('RoleService: Error parsing backend role: $e');
          }
        }
        // 采用后端下发的 hash（若有），保证与后端 roles_hash 一致
        final backendHash = response['hash']?.toString();
        await _saveRoles(backendHash: backendHash);
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

  /// 仅在后端 hash 与本地不一致时才全量拉取角色。
  /// 带 in-flight 去重与 TTL 节流，避免频繁触发（如每次进聊天页）造成的多余往返。
  static Future<bool> syncIfHashMismatch({bool force = false}) async {
    // 复用进行中的同步
    final inFlight = _inFlightSync;
    if (inFlight != null) {
      return inFlight;
    }
    // TTL 节流（force 时跳过）
    if (!force && _lastSyncAt != null) {
      final elapsed = DateTime.now().difference(_lastSyncAt!);
      if (elapsed < _syncThrottle) {
        return false;
      }
    }

    final future = _doSyncIfHashMismatch();
    _inFlightSync = future;
    try {
      return await future;
    } finally {
      _inFlightSync = null;
    }
  }

  static Future<bool> _doSyncIfHashMismatch() async {
    _lastSyncAt = DateTime.now();
    try {
      final response = await SecureWebSocketClient.instance.request(
        'roles_hash',
        const <String, dynamic>{},
      );
      final backendHash = response['hash']?.toString() ?? '';
      if (backendHash.isNotEmpty && backendHash == _localRolesHash) {
        debugPrint('RoleService: roles hash matched, skip full fetch');
        return false;
      }
    } catch (e) {
      // hash 探测失败则退回到全量拉取（保持原有行为）
      debugPrint(
        'RoleService: roles_hash probe failed, fallback to full fetch: $e',
      );
    }
    return fetchFromBackend();
  }

  /// 同步单个角色到后端
  static Future<bool> syncRoleToBackend(Role role) async {
    try {
      await SecureWebSocketClient.instance.request('roles_upsert', {
        'role': {
          'id': role.id,
          'name': role.name,
          'description': role.description,
          'system_prompt': role.systemPrompt,
          'avatar_url': role.avatarUrl,
          'chat_background_url': role.chatBackgroundUrl,
          'persona': role.description,
          'core_memory': role.coreMemory,
          'ai_model': role.aiModel,
           'ai_api_url': role.aiApiUrl,
           'ai_api_key': role.aiApiKey,
           'ai_temperature': role.aiTemperature,
           'ai_timeout_seconds': role.aiTimeoutSeconds,
           'ai_reasoning_effort': role.aiReasoningEffort,
           'ai_stream': role.aiStream,
           'gender': role.gender,
          'menstruation_cycle': role.menstruationCycle,
          'temperature': role.temperature,
          'onebot_config': role.onebotConfig.toJson(),
          'stats_config': role.statsConfig.toJson(),
          'show_action': role.showAction,
          'show_sound': role.showSound,
          'show_psychology': role.showPsychology,
          'show_stats': role.showStats,
          'show_no_reply': role.showNoReply,
          'archived': role.archived,
          'max_context_rounds': role.maxContextRounds,
          'allow_web_search': role.allowWebSearch,
          'proactive_config': role.proactiveConfig.toBackendJson(),
          'followup_config': role.followupConfig.toBackendJson(),
        },
      });
      return true;
    } catch (e) {
      debugPrint('RoleService: Sync to backend failed: $e');
      return false;
    }
  }

  /// 首次升级时以旧客户端的本地配置为准，避免服务端默认关闭状态覆盖用户设置。
  static Future<bool> migrateProactiveConfigsToBackendIfNeeded() async {
    if (StorageService.getBool(_proactiveConfigMigrationKey) == true) {
      return true;
    }

    for (final role in _roles.where((item) => !isToolRoleId(item.id))) {
      try {
        await SecureWebSocketClient.instance.request('roles_upsert', {
          'role': {
            'id': role.id,
            'name': role.name,
            'proactive_config': role.proactiveConfig.toBackendJson(),
          },
        });
      } catch (e) {
        debugPrint(
          'RoleService: proactive config migration deferred for ${role.id}: $e',
        );
        return false;
      }
    }

    await StorageService.setBool(_proactiveConfigMigrationKey, true);
    debugPrint('RoleService: proactive configs migrated to backend');
    return true;
  }

  /// 同步所有角色到后端
  static Future<void> syncAllToBackend() async {
    for (final role in _roles) {
      await syncRoleToBackend(role);
    }
    debugPrint('RoleService: Synced ${_roles.length} roles to backend');
  }
}
