import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/message_store.dart';
import 'moments_service.dart';
import 'secure_websocket_client.dart';
import 'task_service.dart';

class RealtimeSyncService {
  RealtimeSyncService._();

  static bool _initialized = false;
  static StreamSubscription<Map<String, dynamic>>? _subscription;

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

    debugPrint('RealtimeSyncService initialized');
  }

  static bool _isChatPush(String type) {
    return type == 'proactive_message' ||
        type == 'task_message' ||
        type == 'chat_message';
  }

  static bool _isTaskPush(String type) {
    return type == 'task_message' || type == 'task_triggered';
  }

  static bool _isMomentPush(String type) {
    return type == 'moment_post' || type == 'moment_comment';
  }

  static Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _initialized = false;
  }
}
