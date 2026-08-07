import 'dart:async';
import 'dart:ui';

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
  static bool _desiredEnabled = false;
  static bool _watchdogRecovering = false;
  static Timer? _serviceWatchdogTimer;

  static const String _eventAppForeground = 'appForeground';
  static const String _eventAppBackground = 'appBackground';
  static const String _eventRequestStart = 'pendingRequestStart';
  static const String _eventRequestComplete = 'pendingRequestComplete';
  static const Duration _requestTimeout = Duration(seconds: 45);

  static Duration _resolveServiceWatchdogInterval() {
    final seconds = SettingsService.instance.backgroundWatchdogIntervalSeconds;
    return Duration(seconds: seconds.clamp(10, 120));
  }

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

    _desiredEnabled = enabled;
    await applyEnabled(enabled);

    if (_desiredEnabled) {
      _startServiceWatchdogIfNeeded();
    } else {
      _stopServiceWatchdog();
    }

    debugPrint('BackgroundRuntimeService: Initialized, enabled=$enabled');
  }

  static Future<void> applyEnabled(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _desiredEnabled = enabled;

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
        _startServiceWatchdogIfNeeded();
        return;
      }

      if (isRunning) {
        _service.invoke('stopService');
      }
      _stopServiceWatchdog();
    } catch (e, st) {
      debugPrint('BackgroundRuntimeService: applyEnabled failed: $e');
      debugPrint('$st');
    }
  }

  static void _startServiceWatchdogIfNeeded() {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    if (_serviceWatchdogTimer != null) {
      return;
    }

    final watchdogInterval = _resolveServiceWatchdogInterval();
    _serviceWatchdogTimer = Timer.periodic(watchdogInterval, (
      timer,
    ) async {
      if (!_desiredEnabled || !_initialized) {
        return;
      }
      if (_watchdogRecovering) {
        return;
      }

      try {
        final running = await _service.isRunning();
        if (running) {
          return;
        }

        _watchdogRecovering = true;
        debugPrint('BackgroundRuntimeService: watchdog detected stopped service, recovering...');
        await applyEnabled(true);
      } catch (e) {
        debugPrint('BackgroundRuntimeService: watchdog recovery failed: $e');
      } finally {
        _watchdogRecovering = false;
      }
    });
  }

  static void _stopServiceWatchdog() {
    _serviceWatchdogTimer?.cancel();
    _serviceWatchdogTimer = null;
  }

  static void notifyAppLifecycle({required bool inForeground}) {
    if (!_initialized || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    if (!inForeground && _desiredEnabled) {
      unawaited(applyEnabled(true));
    }

    _service.invoke(inForeground ? _eventAppForeground : _eventAppBackground);

    // 回到前台时验证主进程 WebSocket 连接
    if (inForeground) {
      unawaited(_verifyForegroundConnection());
    }
  }

  static Future<void> _verifyForegroundConnection() async {
    try {
      if (!SecureWebSocketClient.instance.isConnected) {
        debugPrint('BackgroundRuntimeService: foreground check - reconnecting WebSocket');
        await SecureWebSocketClient.instance.ensureConnected();
      } else {
        // 快速健康检查确认连接有效
        await SecureWebSocketClient.instance.request(
          'health',
          const <String, dynamic>{},
          timeout: Duration(seconds: 4),
        );
      }
    } catch (e) {
      debugPrint('BackgroundRuntimeService: foreground connection verify failed: $e');
    }
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

  /// 是否已获得电池优化豁免（Android）。非 Android 恒为 true。
  static Future<bool> isBatteryOptimizationExempt() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (e) {
      debugPrint('BackgroundRuntimeService: check battery exemption failed: $e');
      return false;
    }
  }

  /// 请求电池优化豁免（Android）。返回请求后是否处于已授予状态。
  /// 该豁免可阻止 OEM 系统杀死前台服务，是保活可靠性的关键杠杆。
  static Future<bool> requestBatteryOptimizationExemption() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      if (await Permission.ignoreBatteryOptimizations.isGranted) {
        return true;
      }
      final status = await Permission.ignoreBatteryOptimizations.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('BackgroundRuntimeService: request battery exemption failed: $e');
      return false;
    }
  }

  @pragma('vm:entry-point')
  static void _onStart(ServiceInstance service) {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    var appInForeground = false;
    var bootstrapReady = false;
    final pendingRequests = <String, _PendingRequestState>{};
    Timer? requestWatchTimer;
    Timer? backgroundTaskPollTimer;
    Timer? foregroundNotificationTimer;
    StreamSubscription<Map<String, dynamic>>? serverPushSubscription;
    final notifiedTaskMessageIds = <String>{};
    final notifiedTaskMessageOrder = <String>[];
    const maxNotifiedTaskMessageIds = 800;
    var taskNotifyBaseline = DateTime.now();

    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
    }

    // 处理服务端实时推送：后台隔离直接把 task/proactive 消息转成通知，
    // 无需等待轮询。与轮询共用 notifiedTaskMessageIds 去重。
    Future<void> handleServerPush(Map<String, dynamic> event) async {
      if (appInForeground || !bootstrapReady) {
        return;
      }
      final type =
          (event['event_type'] ?? event['type'] ?? '').toString().trim();
      if (type != 'task_message' && type != 'proactive_message') {
        return;
      }

      final chatId = (event['chat_id'] ?? event['role_id'] ?? '').toString();
      final messageId = (event['message_id'] ?? event['id'] ?? '').toString();
      final content = (event['content'] ?? '').toString();
      final senderId = (event['sender_id'] ?? '').toString();

      if (chatId.isEmpty || content.isEmpty || senderId == 'me') {
        return;
      }
      if (messageId.isNotEmpty && notifiedTaskMessageIds.contains(messageId)) {
        return;
      }

      final role = RoleService.getRoleById(chatId);
      await NotificationService.instance.showMessageNotification(
        chatId: chatId,
        senderName: role?.name ?? 'AI',
        message: content,
      );
      if (messageId.isNotEmpty) {
        _rememberNotifiedMessageId(
          messageId,
          notifiedTaskMessageIds,
          notifiedTaskMessageOrder,
          maxNotifiedTaskMessageIds,
        );
      }
    }

    Future<void>(() async {
      try {
        await StorageService.init();
        await SettingsService.init();
        await RoleService.init();
        await NotificationService.instance.init();
        bootstrapReady = true;

        serverPushSubscription =
            SecureWebSocketClient.instance.serverPushStream.listen(
          (event) => unawaited(handleServerPush(event)),
          onError: (Object e, StackTrace st) {
            debugPrint('BackgroundRuntimeService: server push error: $e');
          },
        );
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

    // 连接健康由 SecureWebSocketClient 自带的心跳 + pong 看门狗 +
    // 重连退避 + connectivity 监听器负责（该客户端在此隔离同样运行），
    // 后台服务不再重复维护连接性监听与独立保活定时器。

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
          notifiedTaskMessageOrder: notifiedTaskMessageOrder,
          maxNotifiedTaskMessageIds: maxNotifiedTaskMessageIds,
        );
      });
    }

    service.on(_eventAppForeground).listen((event) {
      appInForeground = true;
      SecureWebSocketClient.instance.setForeground(true);
      stopBackgroundTaskPoll();
    });

    service.on(_eventAppBackground).listen((event) {
      appInForeground = false;
      SecureWebSocketClient.instance.setForeground(false);
      // 切后台后启动兜底轮询，覆盖 socket 断开（Doze）期间漏收的推送。
      taskNotifyBaseline = DateTime.now().subtract(
        _resolveBackgroundTaskPollInterval(),
      );
      startBackgroundTaskPollIfNeeded();
      // 立即确保连接就绪；连接健康随后由 WS 客户端自带机制维护。
      unawaited(() async {
        if (!bootstrapReady) {
          return;
        }
        try {
          await SecureWebSocketClient.instance.ensureConnected();
        } catch (e) {
          debugPrint('BackgroundRuntimeService: immediate reconnect failed: $e');
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
      foregroundNotificationTimer?.cancel();
      serverPushSubscription?.cancel();
      unawaited(SecureWebSocketClient.instance.close());
      service.stopSelf();
    });

    foregroundNotificationTimer = Timer.periodic(const Duration(minutes: 5), (timer) async {
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
    required List<String> notifiedTaskMessageOrder,
    required int maxNotifiedTaskMessageIds,
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

          // 只处理后端任务/主动触发写入的消息，避免与正常聊天通知重复
          final isBackgroundMessage = messageId.contains('_task_') || messageId.contains('_proactive');
          if (!isBackgroundMessage) {
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
          _rememberNotifiedMessageId(
            messageId,
            notifiedTaskMessageIds,
            notifiedTaskMessageOrder,
            maxNotifiedTaskMessageIds,
          );
        }
      }
    } catch (e) {
      debugPrint('BackgroundRuntimeService: task websocket sync failed: $e');
    }

    return latestSeen;
  }

  static void _rememberNotifiedMessageId(
    String messageId,
    Set<String> ids,
    List<String> order,
    int maxSize,
  ) {
    if (messageId.isEmpty || !ids.add(messageId)) return;
    order.add(messageId);
    while (order.length > maxSize) {
      ids.remove(order.removeAt(0));
    }
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
