import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'notification_service.dart';
import 'role_service.dart';
import 'secure_websocket_client.dart';
import 'settings_service.dart';
import 'storage_service.dart';

/// 后台运行服务
/// Android: 启动前台服务，保证应用切到后台后仍保持运行。
class BackgroundRuntimeService {
  BackgroundRuntimeService._();

  static final FlutterBackgroundService _service = FlutterBackgroundService();
  static bool _initialized = false;

  static const String _eventAppForeground = 'appForeground';
  static const String _eventAppBackground = 'appBackground';
  static const String _eventRequestStart = 'pendingRequestStart';
  static const String _eventRequestComplete = 'pendingRequestComplete';
  static const Duration _requestTimeout = Duration(seconds: 45);
  static const Duration _backgroundWsKeepAliveInterval = Duration(minutes: 4);

  static Duration _resolveBackgroundTaskPollInterval() {
    final seconds = SettingsService.instance.backgroundPollIntervalSeconds;
    return Duration(seconds: seconds.clamp(15, 120));
  }

  static Future<void> init({required bool enabled}) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      _initialized = true;
      return;
    }

    if (!_initialized) {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: _onStart,
          autoStart: false,
          isForegroundMode: true,
          autoStartOnBoot: true,
          foregroundServiceTypes: const [AndroidForegroundType.dataSync],
          foregroundServiceNotificationId: 8899,
          initialNotificationTitle: 'ZeroChat 正在后台运行',
          initialNotificationContent: '保持任务调度与消息能力',
        ),
        iosConfiguration: IosConfiguration(),
      );
      _initialized = true;
    }

    await applyEnabled(enabled);
    debugPrint('BackgroundRuntimeService: Initialized, enabled=$enabled');
  }

  static Future<void> applyEnabled(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;

    try {
      final isRunning = await _service.isRunning();
      if (enabled) {
        final notificationStatus = await Permission.notification.status;
        final canShowForegroundNotification =
            !notificationStatus.isDenied &&
            !notificationStatus.isPermanentlyDenied &&
            !notificationStatus.isRestricted;

        if (!canShowForegroundNotification) {
          debugPrint(
            'BackgroundRuntimeService: Skip start, notification permission not granted',
          );
          return;
        }

        if (!isRunning) {
          await _service.startService();
        }
        return;
      }

      if (isRunning) {
        _service.invoke('stopService');
      }
    } catch (e, st) {
      debugPrint('BackgroundRuntimeService: applyEnabled failed: $e');
      debugPrint('$st');
    }
  }

  static void notifyAppLifecycle({required bool inForeground}) {
    if (!_initialized || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _service.invoke(inForeground ? _eventAppForeground : _eventAppBackground);
  }

  static void registerPendingRequest({
    required String requestId,
    required String chatId,
    required String baselineMessageId,
  }) {
    if (!_initialized || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _service.invoke(_eventRequestStart, {
      'request_id': requestId,
      'chat_id': chatId,
      'baseline_message_id': baselineMessageId,
      'started_at': DateTime.now().toIso8601String(),
    });
  }

  static void completePendingRequest(String requestId) {
    if (!_initialized || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _service.invoke(_eventRequestComplete, {'request_id': requestId});
  }

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    WidgetsFlutterBinding.ensureInitialized();

    var appInForeground = false;
    var bootstrapReady = false;
    final pendingRequests = <String, _PendingRequestState>{};
    Timer? requestWatchTimer;
    Timer? backgroundTaskPollTimer;
    Timer? websocketKeepAliveTimer;
    final notifiedTaskMessageIds = <String>{};
    var taskNotifyBaseline = DateTime.now();

    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }

    Future<void>(() async {
      try {
        await StorageService.init();
        await SettingsService.init();
        await RoleService.init();
        await NotificationService.instance.init();
        bootstrapReady = true;
      } catch (e, st) {
        debugPrint('BackgroundRuntimeService: bootstrap failed: $e');
        debugPrint('$st');
      }
    });

    void stopRequestWatchIfIdle() {
      if (pendingRequests.isNotEmpty) {
        return;
      }
      requestWatchTimer?.cancel();
      requestWatchTimer = null;
    }

    void startRequestWatchIfNeeded() {
      if (requestWatchTimer != null) {
        return;
      }
      requestWatchTimer = Timer.periodic(const Duration(seconds: 8), (
        timer,
      ) async {
        if (pendingRequests.isEmpty) {
          stopRequestWatchIfIdle();
          return;
        }
        if (appInForeground || !bootstrapReady) {
          return;
        }

        await _waitPendingRequestsAndNotify(pendingRequests: pendingRequests);
        stopRequestWatchIfIdle();
      });
    }

    void stopBackgroundTaskPoll() {
      backgroundTaskPollTimer?.cancel();
      backgroundTaskPollTimer = null;
    }

    void stopBackgroundWebsocketKeepAlive() {
      websocketKeepAliveTimer?.cancel();
      websocketKeepAliveTimer = null;
    }

    void startBackgroundWebsocketKeepAliveIfNeeded() {
      if (websocketKeepAliveTimer != null) {
        return;
      }

      websocketKeepAliveTimer = Timer.periodic(
        _backgroundWsKeepAliveInterval,
        (timer) async {
          if (appInForeground || !bootstrapReady) {
            return;
          }

          try {
            await SecureWebSocketClient.instance.ensureConnected();
            await SecureWebSocketClient.instance.request(
              'health',
              const <String, dynamic>{},
              timeout: const Duration(seconds: 6),
            );
          } catch (e) {
            debugPrint('BackgroundRuntimeService: websocket keepalive failed: $e');
          }
        },
      );
    }

    void startBackgroundTaskPollIfNeeded() {
      if (backgroundTaskPollTimer != null) {
        return;
      }
      final pollInterval = _resolveBackgroundTaskPollInterval();
      backgroundTaskPollTimer = Timer.periodic(pollInterval, (
        timer,
      ) async {
        if (appInForeground || !bootstrapReady) {
          return;
        }

        taskNotifyBaseline = await _pollTaskMessagesAndNotify(
          baseline: taskNotifyBaseline,
          notifiedTaskMessageIds: notifiedTaskMessageIds,
        );
      });
    }

    service.on(_eventAppForeground).listen((event) {
      appInForeground = true;
      stopBackgroundTaskPoll();
      stopBackgroundWebsocketKeepAlive();
    });

    service.on(_eventAppBackground).listen((event) {
      appInForeground = false;
      // 切后台后开始持续检查后端任务消息，避免错过提醒
      taskNotifyBaseline = DateTime.now();
      startBackgroundTaskPollIfNeeded();
      startBackgroundWebsocketKeepAliveIfNeeded();
      unawaited(() async {
        if (!bootstrapReady) {
          return;
        }
        try {
          await SecureWebSocketClient.instance.ensureConnected();
          await SecureWebSocketClient.instance.request(
            'health',
            const <String, dynamic>{},
            timeout: const Duration(seconds: 6),
          );
        } catch (e) {
          debugPrint('BackgroundRuntimeService: immediate keepalive failed: $e');
        }
      }());
    });

    service.on(_eventRequestStart).listen((event) {
      final args = event ?? const <String, dynamic>{};
      final requestId = args['request_id']?.toString() ?? '';
      final chatId = args['chat_id']?.toString() ?? '';
      final baselineMessageId = args['baseline_message_id']?.toString() ?? '';
      final startedAtRaw = args['started_at']?.toString() ?? '';
      final startedAt = DateTime.tryParse(startedAtRaw) ?? DateTime.now();

      if (requestId.isEmpty || chatId.isEmpty) {
        return;
      }

      pendingRequests[requestId] = _PendingRequestState(
        requestId: requestId,
        chatId: chatId,
        baselineMessageId: baselineMessageId,
        startedAt: startedAt,
      );
      startRequestWatchIfNeeded();
    });

    service.on(_eventRequestComplete).listen((event) {
      final args = event ?? const <String, dynamic>{};
      final requestId = args['request_id']?.toString() ?? '';
      if (requestId.isEmpty) {
        return;
      }
      pendingRequests.remove(requestId);
      stopRequestWatchIfIdle();
    });

    service.on('stopService').listen((event) {
      requestWatchTimer?.cancel();
      backgroundTaskPollTimer?.cancel();
      websocketKeepAliveTimer?.cancel();
      unawaited(SecureWebSocketClient.instance.close());
      service.stopSelf();
    });

    Timer.periodic(const Duration(minutes: 5), (timer) async {
      if (service is AndroidServiceInstance) {
        await service.setForegroundNotificationInfo(
          title: 'ZeroChat 正在后台运行',
          content:
              '最后保活时间: ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
        );
      }
    });
  }

  static Future<DateTime> _pollTaskMessagesAndNotify({
    required DateTime baseline,
    required Set<String> notifiedTaskMessageIds,
  }) async {
    var latestSeen = baseline;

    try {
      final data = await SecureWebSocketClient.instance.request('chat_snapshot', {
        'client_md5': 'bg_task_poll',
      });
      if (data['need_sync'] != true) {
        return latestSeen;
      }
      final chats = data['chats'];
      if (chats is! Map) {
        return latestSeen;
      }

      for (final entry in chats.entries) {
        final chatId = entry.key.toString();
        final rawList = entry.value;
        if (rawList is! List) {
          continue;
        }

        for (final item in rawList) {
          if (item is! Map) {
            continue;
          }

          final map = Map<String, dynamic>.from(item);
          final messageId = map['id']?.toString() ?? '';
          final senderId = map['sender_id']?.toString() ?? '';
          final content = map['content']?.toString() ?? '';
          final timestamp =
              DateTime.tryParse(map['timestamp']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);

          if (timestamp.isAfter(latestSeen)) {
            latestSeen = timestamp;
          }

          // 只处理后端任务触发写入的消息，避免与正常聊天通知重复
          final isTaskMessage = messageId.contains('_task_');
          if (!isTaskMessage) {
            continue;
          }
          if (senderId == 'me' || content.isEmpty) {
            continue;
          }
          if (timestamp.isBefore(baseline.subtract(const Duration(seconds: 1)))) {
            continue;
          }
          if (notifiedTaskMessageIds.contains(messageId)) {
            continue;
          }

          final role = RoleService.getRoleById(chatId);
          await NotificationService.instance.showMessageNotification(
            chatId: chatId,
            senderName: role?.name ?? 'AI',
            message: content,
          );
          notifiedTaskMessageIds.add(messageId);
        }
      }
    } catch (e) {
      debugPrint('BackgroundRuntimeService: task websocket sync failed: $e');
    }

    return latestSeen;
  }

  static Future<void> _waitPendingRequestsAndNotify({
    required Map<String, _PendingRequestState> pendingRequests,
  }) async {
    try {
      final data = await SecureWebSocketClient.instance.request('chat_snapshot', {
        'client_md5': 'bg_poll',
      });
      if (data['need_sync'] != true) {
        return;
      }
      final chats = data['chats'];
      if (chats is! Map) {
        return;
      }

      final doneRequestIds = <String>[];
      for (final state in pendingRequests.values) {
        final isTimedOut =
            DateTime.now().difference(state.startedAt) > _requestTimeout;
        if (isTimedOut) {
          final role = RoleService.getRoleById(state.chatId);
          await NotificationService.instance.showMessageNotification(
            chatId: state.chatId,
            senderName: role?.name ?? 'AI',
            message: '请求超时，请稍后重试',
          );
          doneRequestIds.add(state.requestId);
          continue;
        }

        final rawList = chats[state.chatId];
        if (rawList is! List || rawList.isEmpty) {
          continue;
        }

        Map<String, dynamic>? latest;
        for (final item in rawList) {
          if (item is! Map) continue;
          latest = Map<String, dynamic>.from(item);
        }
        if (latest == null) {
          continue;
        }

        final latestId = latest['id']?.toString() ?? '';
        final senderId = latest['sender_id']?.toString() ?? '';
        final content = latest['content']?.toString() ?? '';
        final timestamp =
            DateTime.tryParse(latest['timestamp']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);

        final isNewResponse =
            latestId.isNotEmpty &&
            latestId != state.baselineMessageId &&
            senderId != 'me' &&
            content.isNotEmpty &&
            !timestamp.isBefore(
              state.startedAt.subtract(const Duration(seconds: 3)),
            );

        if (!isNewResponse) {
          continue;
        }

        final role = RoleService.getRoleById(state.chatId);
        await NotificationService.instance.showMessageNotification(
          chatId: state.chatId,
          senderName: role?.name ?? 'AI',
          message: content,
        );
        doneRequestIds.add(state.requestId);
      }

      for (final id in doneRequestIds) {
        pendingRequests.remove(id);
      }
    } catch (e) {
      debugPrint('BackgroundRuntimeService: pending websocket sync failed: $e');
    }
  }
}

class _PendingRequestState {
  final String requestId;
  final String chatId;
  final String baselineMessageId;
  final DateTime startedAt;

  const _PendingRequestState({
    required this.requestId,
    required this.chatId,
    required this.baselineMessageId,
    required this.startedAt,
  });
}
