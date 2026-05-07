import 'package:flutter/foundation.dart';
import '../models/message.dart';
import 'storage_service.dart';
import 'role_service.dart';
import 'secure_websocket_client.dart';

/// 记忆服务
/// 管理短期记忆和核心记忆
class MemoryService {
  /// 短期记忆：按会话ID存储的对话历史
  static final Map<String, List<Message>> _shortTermMemory = {};

  /// 核心记忆：重要的长期记忆
  static List<String> _coreMemory = [];

  /// 向量记忆数量（后端向量记忆库）
  static int vectorMemoryCount = 0;

  /// 短期记忆的最大条数（每个会话）
  static int maxShortTermSize = 100;
  static const String _jsonMemoryKeyPrefix = 'json_memory_';

  /// 初始化记忆服务
  static Future<void> init() async {
    await _loadCoreMemory();
    await refreshCoreMemoryFromBackend();
    debugPrint(
      'MemoryService initialized with ${_coreMemory.length} core memories',
    );
  }

  /// 仅加载本地缓存（无网络请求），用于启动加速
  static Future<void> loadLocalOnly() async {
    await _loadCoreMemory();
    debugPrint(
      'MemoryService local cache loaded: ${_coreMemory.length} core memories',
    );
  }

  // ========== 核心记忆持久化 ==========

  /// 加载核心记忆
  static Future<void> _loadCoreMemory() async {
    final list = StorageService.getStringList(StorageService.keyCoreMemory);
    if (list != null) {
      _coreMemory = List.from(list);
    }
  }

  /// 从后端记忆数据库刷新核心记忆
  static Future<void> refreshCoreMemoryFromBackend({String? roleId}) async {
    try {
      final rid = roleId ?? RoleService.getCurrentRole().id;
      final response = await SecureWebSocketClient.instance.request(
        'roles_memory_get',
        {'role_id': rid},
      );
      final dynamic raw = response['core_memory'];
      if (raw is List) {
        _coreMemory = raw.map((e) => e.toString()).toList();
      } else if (raw is String && raw.trim().isNotEmpty) {
        _coreMemory = raw
            .split(RegExp(r'[\n；;]'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } else {
        _coreMemory = [];
      }
      // 读取向量记忆数量
      if (response['vector_memory_count'] is int) {
        vectorMemoryCount = response['vector_memory_count'] as int;
      }
      await _saveCoreMemory();
      debugPrint('MemoryService: Core memory refreshed from backend for role $rid, vector memories: $vectorMemoryCount');
    } catch (e) {
      debugPrint('MemoryService: Refresh core memory from backend failed: $e');
    }
  }

  /// 保存核心记忆
  static Future<void> _saveCoreMemory() async {
    await StorageService.setStringList(
      StorageService.keyCoreMemory,
      _coreMemory,
    );
  }

  // ========== 短期记忆管理 ==========

  /// 添加消息到指定会话的短期记忆
  static void addToShortTermMemory(String chatId, Message message) {
    _shortTermMemory[chatId] ??= [];
    _shortTermMemory[chatId]!.add(message);

    // 超出限制时移除最旧的消息
    while (_shortTermMemory[chatId]!.length > maxShortTermSize) {
      _shortTermMemory[chatId]!.removeAt(0);
    }
  }

  /// 获取指定会话的短期记忆
  static List<Message> getShortTermMemory(String chatId) {
    return List.unmodifiable(_shortTermMemory[chatId] ?? []);
  }

  /// 获取指定会话最近 N 条消息
  static List<Message> getRecentMessages(String chatId, int count) {
    final messages = _shortTermMemory[chatId] ?? [];
    final start = messages.length > count ? messages.length - count : 0;
    return messages.sublist(start);
  }

  /// 获取指定会话最近 N 轮对话（一轮 = 用户消息 + AI回复）
  static List<Message> getRecentRounds(String chatId, int rounds) {
    final messages = _shortTermMemory[chatId] ?? [];
    // 每轮2条消息
    final messageCount = rounds * 2;
    final start = messages.length > messageCount
        ? messages.length - messageCount
        : 0;
    return messages.sublist(start);
  }

  /// 将消息列表转换为 API 历史格式
  static List<Map<String, String>> toApiHistory(List<Message> messages) {
    return messages.map((m) {
      return {
        'role': m.senderId == 'me' ? 'user' : 'assistant',
        'content': m.content,
      };
    }).toList();
  }

  /// 清空指定会话的短期记忆
  static void clearShortTermMemory(String chatId) {
    _shortTermMemory[chatId]?.clear();
  }

  /// 清空所有会话的短期记忆
  static void clearAllShortTermMemory() {
    _shortTermMemory.clear();
  }

  // ========== 核心记忆管理 ==========

  /// 添加核心记忆
  static Future<void> addToCoreMemory(String memory) async {
    if (memory.trim().isNotEmpty && !_coreMemory.contains(memory)) {
      _coreMemory.add(memory);
      await _saveCoreMemory();
      debugPrint('Added to core memory: $memory');
      // 同步到后端
      await _syncCoreMemoryToBackend();
    }
  }

  /// 获取核心记忆
  static List<String> getCoreMemory() {
    return List.unmodifiable(_coreMemory);
  }

  /// 移除核心记忆
  static Future<void> removeFromCoreMemory(String memory) async {
    _coreMemory.remove(memory);
    await _saveCoreMemory();
    await _syncCoreMemoryToBackend();
  }

  /// 清空核心记忆
  static Future<void> clearCoreMemory() async {
    _coreMemory.clear();
    await _saveCoreMemory();
    // 同步到后端
    await _syncCoreMemoryToBackend();
  }

  // ========== 工具方法 ==========

  /// 清空所有记忆
  static Future<void> clearAllMemory() async {
    _shortTermMemory.clear();
    _coreMemory.clear();
    await _saveCoreMemory();
  }

  /// 获取会话数量
  static int get chatCount => _shortTermMemory.length;

  /// 获取核心记忆数量
  static int get coreMemoryCount => _coreMemory.length;

  // ========== 前端 JSON 记忆管理 ==========

  static String _jsonMemoryKey(String roleId) => '$_jsonMemoryKeyPrefix$roleId';

  static List<Map<String, dynamic>> getJsonMemoryEntries(String roleId) {
    return StorageService.getJsonList(_jsonMemoryKey(roleId)) ??
        <Map<String, dynamic>>[];
  }

  static Future<void> appendJsonMemoryPair({
    required String roleId,
    required String userContent,
    required String assistantContent,
    String? requestId,
    String? taskId,
    String? jsonMemory,
  }) async {
    final rid = (requestId ?? '').trim().isNotEmpty
        ? requestId!.trim()
        : 'req_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    final list = getJsonMemoryEntries(roleId);
    final payloadContent = (jsonMemory ?? '').trim();

    list.add({
      'role': 'user',
      'content': payloadContent.isNotEmpty ? payloadContent : userContent,
      'timestamp': now,
      'task_id': taskId,
      'request_id': rid,
      'json_memory': payloadContent.isNotEmpty ? payloadContent : null,
    });
    list.add({
      'role': 'assistant',
      'content': assistantContent,
      'timestamp': now,
      'task_id': taskId,
      'request_id': rid,
      'json_memory': payloadContent.isNotEmpty ? payloadContent : null,
    });

    await StorageService.setJsonList(_jsonMemoryKey(roleId), list);
  }

  /// 检查是否应该自动总结核心记忆（每20轮）
  static bool shouldAutoSummarize(String chatId) {
    final messages = _shortTermMemory[chatId] ?? [];
    // 每 40 条消息（20轮对话）触发一次
    return messages.isNotEmpty && messages.length % 40 == 0;
  }

  /// 获取用于AI总结的近期对话
  static String getRecentChatForSummary(String chatId, {int rounds = 20}) {
    final messages = getRecentRounds(chatId, rounds);
    if (messages.isEmpty) return '';

    final buffer = StringBuffer();
    for (final msg in messages) {
      final sender = msg.senderId == 'me' ? '用户' : 'AI';
      buffer.writeln('$sender: ${msg.content}');
    }
    return buffer.toString();
  }

  /// 从AI总结结果中添加记忆（替换式：用AI总结替换现有核心记忆）
  static Future<void> addSummaryToCoreMemory(String summary) async {
    // 清空现有核心记忆，用新的AI总结替换
    _coreMemory.clear();
    final lines = summary.split('\n').where((line) => line.trim().isNotEmpty);
    for (final line in lines) {
      // 清理行首的标记符号
      final cleaned = line.replaceFirst(RegExp(r'^[-•*]\s*'), '').trim();
      if (cleaned.isNotEmpty && cleaned.length > 3) {
        _coreMemory.add(cleaned);
      }
    }
    await _saveCoreMemory();
    // 同步到后端
    await _syncCoreMemoryToBackend();
  }

  /// 清空后端向量记忆库
  static Future<bool> clearVectorMemory() async {
    try {
      final roleId = RoleService.getCurrentRole().id;
      final response = await SecureWebSocketClient.instance.request(
        'vector_memory_clear',
        {'role_id': roleId},
      );
      final bool success = response['success'] == true;
      if (success) {
        vectorMemoryCount = 0;
      }
      debugPrint('MemoryService: Vector memory cleared for role $roleId');
      return success;
    } catch (e) {
      debugPrint('MemoryService: Clear vector memory failed: $e');
      return false;
    }
  }

  /// 同步核心记忆到后端
  static Future<void> _syncCoreMemoryToBackend() async {
    try {
      final roleId = RoleService.getCurrentRole().id;

      await SecureWebSocketClient.instance.request('roles_memory_update', {
        'role_id': roleId,
        'core_memory': _coreMemory,
      });
      debugPrint(
        'MemoryService: Core memory synced to backend for role $roleId',
      );
    } catch (e) {
      debugPrint('MemoryService: Backend sync error: $e');
    }
  }

}
