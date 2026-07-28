import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:android_intent_plus/android_intent.dart';

import 'notification_service.dart';

/// 设备闹钟/日历服务
///
/// 处理服务端 `device_alarm_request` 信令：AI 通过 set_alarm 工具请求在
/// 用户设备上设置系统闹钟或写入日历事件。落地策略：
/// - alarm：Android 走系统闹钟 Intent（ACTION_SET_ALARM）；其它平台降级为本地精确通知。
/// - calendar_event：Android 走日历 Intent（ACTION_INSERT，打开日历 App 预填事件）；
///   其它平台降级为本地精确通知。
///
/// 走系统 Intent 而非直接读写日历数据库，避免引入重量级三方依赖与日历读写权限，
/// 由用户在系统 App 中确认保存。
class DeviceAlarmService {
  DeviceAlarmService._();

  /// 处理一条 device_alarm_request 信令
  ///
  /// [event] 为解密后的服务端推送，实际字段位于 event['payload'] 之下。
  static Future<void> handleRequest(Map<String, dynamic> event) async {
    final dynamic rawPayload = event['payload'];
    final payload = rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : event;

    final title = (payload['title'] ?? '').toString().trim();
    final kind = (payload['kind'] ?? 'alarm').toString().trim();
    final note = (payload['note'] ?? '').toString().trim();
    final triggerTime =
        DateTime.tryParse((payload['trigger_time'] ?? '').toString());

    if (title.isEmpty || triggerTime == null) {
      debugPrint('DeviceAlarmService: invalid request, ignored');
      return;
    }
    if (triggerTime.isBefore(DateTime.now())) {
      debugPrint('DeviceAlarmService: trigger time in the past, ignored');
      return;
    }

    if (kind == 'calendar_event') {
      final ok = await _addCalendarEvent(title, note, triggerTime);
      if (!ok) {
        await _fallbackNotification(title, note, triggerTime);
      }
      return;
    }

    // 默认按闹钟处理
    final ok = await _setSystemAlarm(title, triggerTime);
    if (!ok) {
      await _fallbackNotification(title, note, triggerTime);
    }
  }

  /// Android 系统闹钟 Intent。成功返回 true；非 Android 或失败返回 false。
  static Future<bool> _setSystemAlarm(String title, DateTime time) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.HOUR': time.hour,
          'android.intent.extra.alarm.MINUTES': time.minute,
          'android.intent.extra.alarm.MESSAGE': title,
          // 打开时钟 App 让用户确认，不直接静默创建
          'android.intent.extra.alarm.SKIP_UI': false,
        },
      );
      await intent.launch();
      debugPrint('DeviceAlarmService: system alarm intent launched');
      return true;
    } catch (e) {
      debugPrint('DeviceAlarmService: system alarm failed: $e');
      return false;
    }
  }

  /// Android 日历事件 Intent（ACTION_INSERT，打开日历 App 预填事件）。
  /// 成功返回 true；非 Android 或失败返回 false。
  static Future<bool> _addCalendarEvent(
    String title,
    String note,
    DateTime time,
  ) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final begin = time.millisecondsSinceEpoch;
      final end = time.add(const Duration(hours: 1)).millisecondsSinceEpoch;
      final intent = AndroidIntent(
        action: 'android.intent.action.INSERT',
        // Events.CONTENT_URI
        data: 'content://com.android.calendar/events',
        arguments: <String, dynamic>{
          'title': title,
          if (note.isNotEmpty) 'description': note,
          'beginTime': begin,
          'endTime': end,
        },
      );
      await intent.launch();
      debugPrint('DeviceAlarmService: calendar insert intent launched');
      return true;
    } catch (e) {
      debugPrint('DeviceAlarmService: calendar event failed: $e');
      return false;
    }
  }

  /// 降级：应用内精确定时通知
  static Future<void> _fallbackNotification(
    String title,
    String note,
    DateTime time,
  ) async {
    final id = time.millisecondsSinceEpoch ~/ 1000 & 0x7fffffff;
    final ok = await NotificationService.instance.scheduleReminder(
      id: id,
      title: title,
      body: note.isEmpty ? '到时间啦' : note,
      triggerTime: time,
    );
    debugPrint('DeviceAlarmService: fallback notification scheduled=$ok');
  }
}
