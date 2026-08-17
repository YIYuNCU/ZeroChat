import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/chat_controller.dart';
import '../core/message_store.dart';
import 'device_alarm_service.dart';
import 'moments_service.dart';
import 'role_service.dart';
import 'secure_websocket_client.dart';
import 'task_service.dart';

class RealtimeSyncService {
  RealtimeSyncService._();

  static bool _initialized = false;
  static StreamSubscription<Map<String, dynamic>>? _subscription;
  static StreamSubscription<void>? _reconnectSubscription;

  static DateTime _lastChatSync = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _lastTaskSync = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _lastMomentSync = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _chatSyncMinGap = Duration(milliseconds: 600);
  static const Duration _taskSyncMinGap = Duration(seconds: 2);
  static const Duration _momentSyncMinGap = Duration(seconds: 2);

  static void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;

    _subscription = SecureWebSocketClient.instance.serverPushStream.listen(
      (event) async {
        final type =
            (event['event_type'] ?? event['type'] ?? '').toString().trim();
        if (type.isEmpty) {
          return;
        }

        if (_isChatPush(type)) {
          final now = DateTime.now();
          if (now.difference(_lastChatSync) >= _chatSyncMinGap) {
            _lastChatSync = now;
            await MessageStore.instance.syncFromBackendSnapshot();
          }
          return;
        }

        if (type == 'device_alarm_request') {
          await DeviceAlarmService.handleRequest(event);
          return;
        }

        if (_isTaskPush(type)) {
          final now = DateTime.now();
          if (now.difference(_lastTaskSync) >= _taskSyncMinGap) {
            _lastTaskSync = now;
            await TaskService.fetchFromBackend();
          }
          return;
        }

        if (_isMomentPush(type)) {
          final now = DateTime.now();
          if (now.difference(_lastMomentSync) >= _momentSyncMinGap) {
            _lastMomentSync = now;
            await MomentsService.instance.fetchFromBackend();
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('RealtimeSyncService: push stream error: $error');
      },
    );

    // 重连成功后主动做一次全量对账，补齐离线/后台期间产生的消息、任务和动态。
    _reconnectSubscription =
        SecureWebSocketClient.instance.onReconnectedStream.listen(
      (_) => resyncAll(),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('RealtimeSyncService: reconnect stream error: $error');
      },
    );

    debugPrint('RealtimeSyncService initialized');
  }

  /// 全量对账：拉取聊天快照、任务、动态。用于重连或前台恢复后补齐离线期间的更新。
  static Future<void> resyncAll() async {
    final now = DateTime.now();
    _lastChatSync = now;
    _lastTaskSync = now;
    _lastMomentSync = now;
    try {
      final proactiveMigrationComplete =
          await RoleService.migrateProactiveConfigsToBackendIfNeeded();
      if (proactiveMigrationComplete) {
        await RoleService.syncIfHashMismatch(force: true);
      }
      // 先排空发件箱，让离线期间未同步的用户消息到达服务端，
      // 再做快照对比，避免快照把未同步消息判为差异并覆盖丢弃。
      await MessageStore.instance.drainOutbox();
      await MessageStore.instance.syncFromBackendSnapshot();
      // 快照对账之后再补齐弱网/后台/重启期间生成成功却漏收的异步聊天回复：
      // 凭持久化的 pending task_id 向服务端恢复缓存推送并渲染。放在快照之后，
      // 避免刚渲染、尚未回传服务端的 AI 分段被快照合并判为差异而覆盖丢弃。
      await ChatController.instance.recoverPendingChatTasks();
      await TaskService.fetchFromBackend();
      await MomentsService.instance.syncIfHashMismatch(force: true);
      debugPrint('RealtimeSyncService: full resync completed');
    } catch (e) {
      debugPrint('RealtimeSyncService: full resync failed: $e');
    }
  }

  static bool _isChatPush(String type) {
    return type == 'proactive_message' ||
        type == 'task_message' ||
        type == 'chat_message';
  }

  static bool _isTaskPush(String type) {
    return type == 'task_message' ||
        type == 'task_triggered' ||
        type == 'task_created';
  }

  static bool _isMomentPush(String type) {
    return type == 'moment_post' ||
        type == 'moment_comment' ||
        type == 'moment_like';
  }

  static Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _reconnectSubscription?.cancel();
    _reconnectSubscription = null;
    _initialized = false;
  }
}
