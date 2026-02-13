import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/chat_controller.dart';
import 'storage_service.dart';
import 'settings_service.dart';

/// 定时任务类型
enum TaskType {
  reminder, // 用户创建的提醒
  proactive, // 主动消息（由系统调度）
}

/// 定时任务模型
class ScheduledTask {
  final String id;
  final String chatId;
  final String roleId; // 所属角色
  final String message; // 提醒内容
  final String? aiPrompt; // AI 生成消息的提示词
  final DateTime triggerTime;
  final TaskType type;
  final bool isRecurring;
  final String? recurringPattern;
  bool isCompleted;

  ScheduledTask({
    required this.id,
    required this.chatId,
    required this.roleId,
    required this.message,
    this.aiPrompt,
    required this.triggerTime,
    this.type = TaskType.reminder,
    this.isRecurring = false,
    this.recurringPattern,
    this.isCompleted = false,
  });

  factory ScheduledTask.fromJson(Map<String, dynamic> json) {
    return ScheduledTask(
      id: json['id'] as String,
      chatId: json['chat_id'] as String,
      roleId: json['role_id'] as String? ?? json['chat_id'] as String,
      message: json['message'] as String,
      aiPrompt: json['ai_prompt'] as String?,
      triggerTime: DateTime.parse(json['trigger_time'] as String),
      type: TaskType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => TaskType.reminder,
      ),
      isRecurring: json['is_recurring'] as bool? ?? false,
      recurringPattern: json['recurring_pattern'] as String?,
      isCompleted: json['is_completed'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chat_id': chatId,
      'role_id': roleId,
      'message': message,
      'ai_prompt': aiPrompt,
      'trigger_time': triggerTime.toIso8601String(),
      'type': type.name,
      'is_recurring': isRecurring,
      'recurring_pattern': recurringPattern,
      'is_completed': isCompleted,
    };
  }
}

/// 定时任务服务
/// 管理定时提醒，支持 AI 风格消息发送
class TaskService {
  static final Map<String, Timer> _activeTimers = {};
  static final List<ScheduledTask> _tasks = [];

  // 安静时间设置（复用 ProactiveConfig 的逻辑，但保留全局设置作为备用）
  static bool _quietTimeEnabled = false;
  static int _quietTimeStart = 23;
  static int _quietTimeEnd = 7;

  // 安静时间内待发送的任务队列
  static final List<ScheduledTask> _pendingTasks = [];

  /// 初始化任务服务
  static Future<void> init() async {
    await _loadTasks();
    await _loadQuietTime();
    await _coldStartCompensation();
    _scheduleAllTasks();
    _startQuietTimeChecker();
    debugPrint('TaskService initialized with ${_tasks.length} tasks');
  }

  /// 冷启动补偿：检查已过期任务并立即执行
  static Future<void> _coldStartCompensation() async {
    final now = DateTime.now();
    final expiredTasks = _tasks
        .where((t) => !t.isCompleted && t.triggerTime.isBefore(now))
        .toList();

    for (final task in expiredTasks) {
      debugPrint('TaskService: Cold-start compensation for task ${task.id}');
      await _deliverMessageAsAI(task);
      task.isCompleted = true;
    }

    if (expiredTasks.isNotEmpty) {
      await _saveTasks();
    }
  }

  // ========== 安静时间管理 ==========

  static Future<void> _loadQuietTime() async {
    _quietTimeEnabled =
        StorageService.getBool(StorageService.keyQuietTimeEnabled) ?? false;
    _quietTimeStart =
        StorageService.getInt(StorageService.keyQuietTimeStart) ?? 23;
    _quietTimeEnd = StorageService.getInt(StorageService.keyQuietTimeEnd) ?? 7;
  }

  static Future<void> setQuietTime({
    required bool enabled,
    int startHour = 23,
    int endHour = 7,
  }) async {
    _quietTimeEnabled = enabled;
    _quietTimeStart = startHour;
    _quietTimeEnd = endHour;
    await StorageService.setBool(StorageService.keyQuietTimeEnabled, enabled);
    await StorageService.setInt(StorageService.keyQuietTimeStart, startHour);
    await StorageService.setInt(StorageService.keyQuietTimeEnd, endHour);
    debugPrint('Quiet time set: $enabled ($startHour:00 - $endHour:00)');
  }

  static bool isQuietTime() {
    if (!_quietTimeEnabled) return false;
    final now = DateTime.now();
    final hour = now.hour;

    if (_quietTimeStart <= _quietTimeEnd) {
      return hour >= _quietTimeStart && hour < _quietTimeEnd;
    } else {
      return hour >= _quietTimeStart || hour < _quietTimeEnd;
    }
  }

  static Map<String, dynamic> getQuietTimeSettings() {
    return {
      'enabled': _quietTimeEnabled,
      'start_hour': _quietTimeStart,
      'end_hour': _quietTimeEnd,
    };
  }

  static void _startQuietTimeChecker() {
    Timer.periodic(const Duration(minutes: 1), (timer) {
      if (!isQuietTime() && _pendingTasks.isNotEmpty) {
        _processPendingTasks();
      }
    });
  }

  static Future<void> _processPendingTasks() async {
    final tasksToProcess = List<ScheduledTask>.from(_pendingTasks);
    _pendingTasks.clear();

    for (final task in tasksToProcess) {
      await _deliverMessageAsAI(task);
    }
  }

  // ========== 任务管理 ==========

  static Future<void> _loadTasks() async {
    final jsonList = StorageService.getJsonList(
      StorageService.keyScheduledTasks,
    );
    if (jsonList != null) {
      _tasks.clear();
      for (final json in jsonList) {
        try {
          final task = ScheduledTask.fromJson(json);
          if (!task.isCompleted) {
            _tasks.add(task);
          }
        } catch (e) {
          debugPrint('Error loading task: $e');
        }
      }
    }
  }

  static Future<void> _saveTasks() async {
    final jsonList = _tasks.map((t) => t.toJson()).toList();
    await StorageService.setJsonList(
      StorageService.keyScheduledTasks,
      jsonList,
    );
  }

  static void _scheduleAllTasks() {
    for (final task in _tasks) {
      if (!task.isCompleted) {
        _scheduleTask(task);
      }
    }
  }

  static void _scheduleTask(ScheduledTask task) {
    final now = DateTime.now();
    final delay = task.triggerTime.difference(now);

    if (delay.isNegative) {
      // 已过期，标记完成（冷启动已处理）
      task.isCompleted = true;
      _saveTasks();
      return;
    }

    _activeTimers[task.id]?.cancel();
    _activeTimers[task.id] = Timer(delay, () {
      _triggerTask(task);
    });

    debugPrint('Task scheduled: ${task.id} in ${delay.inSeconds}s');
  }

  static Future<void> _triggerTask(ScheduledTask task) async {
    if (isQuietTime()) {
      _pendingTasks.add(task);
      debugPrint('Task deferred due to quiet time: ${task.id}');
    } else {
      await _deliverMessageAsAI(task);
    }

    task.isCompleted = true;
    _activeTimers.remove(task.id);
    await _saveTasks();
  }

  /// 以 AI 角色身份发送提醒消息（通过 ChatController）
  static Future<void> _deliverMessageAsAI(ScheduledTask task) async {
    await ChatController.instance.sendScheduledTaskMessage(
      chatId: task.chatId,
      roleId: task.roleId,
      taskContent: task.message,
      customPrompt: task.aiPrompt,
    );

    debugPrint('TaskService: Message sent for task ${task.id}');
  }

  // ========== 公开 API ==========

  /// 添加提醒任务（结构化创建）
  static Future<ScheduledTask> addReminder({
    required String chatId,
    required String roleId,
    required String message,
    required DateTime triggerTime,
    String? aiPrompt,
  }) async {
    final task = ScheduledTask(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      chatId: chatId,
      roleId: roleId,
      message: message,
      aiPrompt: aiPrompt,
      triggerTime: triggerTime,
      type: TaskType.reminder,
    );

    _tasks.add(task);
    _scheduleTask(task);
    await _saveTasks();

    // 自动同步到后端
    await _syncTaskToBackend(task);

    debugPrint(
      'TaskService: Reminder added for ${triggerTime.toIso8601String()} (synced to backend)',
    );
    return task;
  }

  /// 解析简单时间表达式（可选备用）
  static DateTime? parseSimpleTime(String text) {
    final now = DateTime.now();

    // 匹配 "X小时后" 或 "X分钟后"
    final hourMatch = RegExp(r'(\d+)\s*小时后').firstMatch(text);
    if (hourMatch != null) {
      final hours = int.parse(hourMatch.group(1)!);
      return now.add(Duration(hours: hours));
    }

    final minuteMatch = RegExp(r'(\d+)\s*分钟后').firstMatch(text);
    if (minuteMatch != null) {
      final minutes = int.parse(minuteMatch.group(1)!);
      return now.add(Duration(minutes: minutes));
    }

    // 匹配 "HH:MM" 格式
    final timeMatch = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
    if (timeMatch != null) {
      final hour = int.parse(timeMatch.group(1)!);
      final minute = int.parse(timeMatch.group(2)!);
      var target = DateTime(now.year, now.month, now.day, hour, minute);
      if (target.isBefore(now)) {
        target = target.add(const Duration(days: 1));
      }
      return target;
    }

    return null;
  }

  /// 取消任务
  static Future<void> cancelTask(String taskId) async {
    _activeTimers[taskId]?.cancel();
    _activeTimers.remove(taskId);
    _tasks.removeWhere((t) => t.id == taskId);
    await _saveTasks();
  }

  /// 取消所有任务
  static Future<void> cancelAllTasks() async {
    for (final timer in _activeTimers.values) {
      timer.cancel();
    }
    _activeTimers.clear();
    _tasks.clear();
    await _saveTasks();
  }

  /// 获取所有活跃任务
  static List<ScheduledTask> getActiveTasks() {
    return _tasks.where((t) => !t.isCompleted).toList();
  }

  /// 获取指定聊天的任务
  static List<ScheduledTask> getTasksForChat(String chatId) {
    return _tasks.where((t) => t.chatId == chatId && !t.isCompleted).toList();
  }

  // ========== 后端同步 ==========

  /// 获取后端 URL
  static String get _backendUrl => SettingsService.instance.backendUrl;

  /// 同步任务到后端
  static Future<bool> _syncTaskToBackend(ScheduledTask task) async {
    try {
      final uri = Uri.parse('$_backendUrl/api/tasks');
      final request = await HttpClient().postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'id': task.id,
          'role_id': task.roleId,
          'trigger_time': task.triggerTime.toIso8601String(),
          'message': task.message,
          'ai_prompt': task.aiPrompt,
          'enabled': !task.isCompleted,
        }),
      );
      final response = await request.close();
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      debugPrint('TaskService: Backend sync failed: $e');
      return false;
    }
  }

  /// 从后端拉取任务
  static Future<bool> fetchFromBackend() async {
    try {
      final uri = Uri.parse('$_backendUrl/api/tasks');
      final request = await HttpClient().getUrl(uri);
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(const Utf8Decoder()).join();
        final data = jsonDecode(body);
        if (data['tasks'] != null) {
          debugPrint(
            'TaskService: Fetched ${(data['tasks'] as List).length} tasks from backend',
          );
          return true;
        }
      }
    } catch (e) {
      debugPrint('TaskService: Fetch from backend failed: $e');
    }
    return false;
  }
}
