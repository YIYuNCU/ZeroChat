import 'package:flutter/foundation.dart';

import 'secure_websocket_client.dart';
import 'storage_service.dart';

/// 工具调用历史查询服务。
///
/// 明细（工具名/参数/结果）不随聊天消息本体存储/传输，服务端按 request_id
/// 落在每角色的 memory.sqlite 里。这里按需向服务端查询，并把结果缓存到本地
/// （StorageService，即 SharedPreferences 的 JSON 存取），避免用户重复展开
/// 同一条消息的卡片时反复请求服务器。
class ToolCallService {
  static const int _memoryCacheLimit = 200;

  /// 进程内内存缓存：命中率最高的一层，避免同一会话里反复读本地存储。
  static final Map<String, List<Map<String, dynamic>>> _memoryCache = {};

  static String _cacheKey(String roleId, String requestId) =>
      'tool_calls_cache_${roleId}_$requestId';

  /// 获取某次 AI 回复的工具调用记录。
  /// 命中内存缓存或本地缓存时不发起网络请求。
  static Future<List<Map<String, dynamic>>> getToolCalls({
    required String roleId,
    required String requestId,
  }) async {
    if (requestId.isEmpty) return const <Map<String, dynamic>>[];
    final cacheKey = _cacheKey(roleId, requestId);

    final memoryHit = _memoryCache[cacheKey];
    if (memoryHit != null) return memoryHit;

    final localHit = StorageService.getJsonList(cacheKey);
    if (localHit != null) {
      _rememberInMemory(cacheKey, localHit);
      return localHit;
    }

    try {
      final response = await SecureWebSocketClient.instance.request(
        'tool_calls_get',
        {'role_id': roleId, 'request_id': requestId},
      );
      final raw = response['tool_calls'];
      final calls = <Map<String, dynamic>>[];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            calls.add(Map<String, dynamic>.from(item));
          }
        }
      }
      // 只有 has_tool_calls 为真的消息才会展示入口，所以空结果意味着服务端暂时
      // 没有这条记录（例如落库失败后又被修复）。空结果不能写入本地缓存，否则
      // 之后即使服务端有了记录，这条消息的卡片也永远是空的。
      if (calls.isNotEmpty) {
        await StorageService.setJsonList(cacheKey, calls);
        _rememberInMemory(cacheKey, calls);
      }
      return calls;
    } catch (e) {
      debugPrint('ToolCallService: fetch failed for $requestId: $e');
      return const <Map<String, dynamic>>[];
    }
  }

  static void _rememberInMemory(String key, List<Map<String, dynamic>> calls) {
    if (_memoryCache.length >= _memoryCacheLimit) {
      // 简单的先进先出淘汰，足以应对单次会话内的展开操作量级。
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[key] = calls;
  }
}
