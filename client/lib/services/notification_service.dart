import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 通知服务
/// 处理本地通知和应用角标
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  static NotificationService get instance => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _tzInitialized = false;
  int _lastBadgeCount = 0;

  /// 当前是否在聊天页面（避免重复通知）
  String? _currentChatId;

  /// 初始化通知服务
  Future<void> init() async {
    if (_initialized) return;

    // Android 初始化设置
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    // iOS 初始化设置
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    _initialized = true;
    debugPrint('NotificationService: Initialized');
  }

  /// 设置当前聊天ID（在聊天页面时不显示该聊天的通知）
  void setCurrentChat(String? chatId) {
    _currentChatId = chatId;
  }

  /// 同步角标（从外部未读数更新）
  Future<void> syncBadge(int totalUnread) async {
    if (totalUnread == _lastBadgeCount) return;
    _lastBadgeCount = totalUnread;
    await setBadgeCount(totalUnread);
  }

  /// 显示消息通知
  Future<void> showMessageNotification({
    required String chatId,
    required String senderName,
    required String message,
    String? avatarUrl,
  }) async {
    // 如果用户正在查看该聊天，不显示通知
    if (_currentChatId == chatId) {
      debugPrint('NotificationService: Skipping notification for current chat');
      return;
    }

    try {
      // Android 通知详情（带分组）
      final androidDetails = AndroidNotificationDetails(
        'zerochat_messages',
        '消息通知',
        channelDescription: 'ZeroChat 消息通知',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        category: AndroidNotificationCategory.message,
        groupKey: 'zerochat_chat_$chatId',
        styleInformation: BigTextStyleInformation(
          message,
          contentTitle: senderName,
          summaryText: '新消息',
        ),
      );

      // iOS 通知详情
      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        threadIdentifier: 'zerochat_chat_$chatId',
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // 使用 chatId 的 hashCode 作为通知 ID（确保同一聊天覆盖之前的通知）
      await _notifications.show(
        chatId.hashCode,
        senderName,
        message.length > 50 ? '${message.substring(0, 50)}...' : message,
        details,
        payload: chatId,
      );

      debugPrint('NotificationService: Showed notification for $senderName');
    } catch (e) {
      debugPrint('NotificationService: Error showing notification: $e');
    }
  }

  /// 显示连接断开通知
  Future<void> showConnectionLostNotification() async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'zerochat_connection',
        '连接状态',
        channelDescription: 'ZeroChat 连接状态通知',
        importance: Importance.low,
        priority: Priority.defaultPriority,
        showWhen: true,
        ongoing: false,
        autoCancel: true,
      );

      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: false,
        presentSound: false,
      );

      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        -1, // 固定 ID 用于连接状态
        '连接已断开',
        'ZeroChat 与服务器的连接已断开，正在尝试重连...',
        details,
      );
    } catch (e) {
      debugPrint('NotificationService: Error showing connection notification: $e');
    }
  }

  /// 清除连接断开通知
  Future<void> clearConnectionLostNotification() async {
    await _notifications.cancel(-1);
  }

  /// 使用指定数量更新角标
  Future<void> setBadgeCount(int count) async {
    try {
      final supported = await AppBadgePlus.isSupported();
      if (!supported) return;

      if (count > 0) {
        await AppBadgePlus.updateBadge(count);
      } else {
        await AppBadgePlus.updateBadge(0);
      }
      debugPrint('NotificationService: Badge set to $count');
    } catch (e) {
      debugPrint('NotificationService: Error setting badge: $e');
    }
  }

  /// 在指定时间调度一条本地提醒通知（用于 set_alarm 的降级/日历失败兜底）
  /// 返回是否调度成功。
  Future<bool> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime triggerTime,
  }) async {
    if (!_initialized) {
      await init();
    }
    if (triggerTime.isBefore(DateTime.now())) {
      debugPrint('NotificationService: reminder time is in the past, skipped');
      return false;
    }
    try {
      if (!_tzInitialized) {
        tzdata.initializeTimeZones();
        _tzInitialized = true;
      }

      const androidDetails = AndroidNotificationDetails(
        'zerochat_reminders',
        '定时提醒',
        channelDescription: 'ZeroChat 定时闹钟/提醒',
        importance: Importance.max,
        priority: Priority.high,
        category: AndroidNotificationCategory.alarm,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final scheduled = tz.TZDateTime.from(triggerTime, tz.local);
      await _notifications.zonedSchedule(
        id,
        title,
        body,
        scheduled,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
      debugPrint('NotificationService: scheduled reminder at $scheduled');
      return true;
    } catch (e) {
      debugPrint('NotificationService: scheduleReminder failed: $e');
      return false;
    }
  }

  /// 清除所有通知
  Future<void> clearAllNotifications() async {
    await _notifications.cancelAll();
    await AppBadgePlus.updateBadge(0);
    debugPrint('NotificationService: Cleared all notifications');
  }

  /// 清除指定聊天的通知
  Future<void> clearChatNotification(String chatId) async {
    await _notifications.cancel(chatId.hashCode);
    debugPrint('NotificationService: Cleared notification for $chatId');
  }

  /// 通知点击回调
  void _onNotificationTapped(NotificationResponse response) {
    final chatId = response.payload;
    if (chatId != null) {
      debugPrint('NotificationService: Notification tapped for chat $chatId');
      // TODO: 导航到对应聊天页面
      // 这需要和 Navigator 集成
    }
  }
}
