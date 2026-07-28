import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'notification_service.dart';

/// 设备闹钟/日历服务
///
/// 处理服务端 `device_alarm_request` 信令：AI 通过 set_alarm 工具请求在
/// 用户设备上设置系统闹钟或写入日历事件。落地策略：
/// - alarm：Android 走系统闹钟 Intent（ACTION_SET_ALARM）；其它平台降级为本地精确通知。
/// - calendar_event：通过 device_calendar 写入系统日历；失败降级为本地精确通知。
class DeviceAlarmService {
  DeviceAlarmService._();

  static final DeviceCalendarPlugin _calendarPlugin = DeviceCalendarPlugin();
  static bool _tzInitialized = false;

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
          // 直接创建，跳过闹钟 UI；仍会打开时钟 App
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

  /// 写入系统日历事件。成功返回 true。
  static Future<bool> _addCalendarEvent(
    String title,
    String note,
    DateTime time,
  ) async {
    try {
      var perm = await _calendarPlugin.hasPermissions();
      if (perm.isSuccess != true || perm.data != true) {
        perm = await _calendarPlugin.requestPermissions();
        if (perm.isSuccess != true || perm.data != true) {
          debugPrint('DeviceAlarmService: calendar permission denied');
          return false;
        }
      }

      final calendarsResult = await _calendarPlugin.retrieveCalendars();
      final calendars = calendarsResult.data;
      if (calendars == null || calendars.isEmpty) {
        return false;
      }
      // 优先选可写的默认日历，否则第一个可写日历
      final writable = calendars.where((c) => c.isReadOnly != true).toList();
      if (writable.isEmpty) {
        return false;
      }
      final calendar = writable.firstWhere(
        (c) => c.isDefault == true,
        orElse: () => writable.first,
      );

      if (!_tzInitialized) {
        tzdata.initializeTimeZones();
        _tzInitialized = true;
      }
      final start = tz.TZDateTime.from(time, tz.local);
      final end = start.add(const Duration(hours: 1));

      final event = Event(
        calendar.id,
        title: title,
        start: start,
        end: end,
        description: note.isEmpty ? null : note,
      );

      final result = await _calendarPlugin.createOrUpdateEvent(event);
      final ok = result?.isSuccess == true && (result?.data?.isNotEmpty ?? false);
      debugPrint('DeviceAlarmService: calendar event created=$ok');
      return ok;
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
