import 'package:flutter/foundation.dart';
import 'storage_service.dart';
import 'settings_service.dart';
import 'secure_backend_client.dart';
import 'background_runtime_service.dart';

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
  static final List<ScheduledTask> _tasks = [];

  // 安静时间设置（复用 ProactiveConfig 的逻辑，但保留全局设置作为备用）
  static bool _quietTimeEnabled = false;
  static int _quietTimeStart = 23;
  static int _quietTimeEnd = 7;

  /// 初始化任务服务
  static Future<void> init() async {
    await _loadTasks();
    await _loadQuietTime();
    await fetchFromBackend();
    debugPrint('TaskService initialized with ${_tasks.length} tasks');
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

  // ========== 公开 API ==========

  /// 添加提醒任务（结构化创建）
  static Future<ScheduledTask> addReminder({
    required String chatId,
    required String roleId,
    required String message,
    required DateTime triggerTime,
    String? aiPrompt,
  }) async {
    final response = await SecureBackendClient.post('$_backendUrl/api/tasks', {
      'chat_id': chatId,
      'role_id': roleId,
      'message': message,
      'ai_prompt': aiPrompt ?? '',
      'trigger_time': triggerTime.toIso8601String(),
      'repeat': null,
    });

    if (!response.isSuccess || response.data is! Map<String, dynamic>) {
      throw Exception('创建后端定时任务失败: HTTP ${response.statusCode}');
    }

    final data = response.data as Map<String, dynamic>;
    final task = ScheduledTask(
      id: data['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      chatId: data['chat_id']?.toString() ?? chatId,
      roleId: data['role_id']?.toString() ?? roleId,
      message: data['message']?.toString() ?? message,
      aiPrompt: data['ai_prompt']?.toString(),
      triggerTime:
          DateTime.tryParse(data['trigger_time']?.toString() ?? '') ??
          triggerTime,
      type: TaskType.reminder,
      isCompleted: data['enabled'] == false,
    );

    _tasks.removeWhere((t) => t.id == task.id);
    _tasks.add(task);
    await _saveTasks();

    // 创建任务后确保后台保活服务可用，以便持续检查后端任务触发结果
    await BackgroundRuntimeService.applyEnabled(
      SettingsService.instance.backgroundRuntimeEnabled,
    );

    debugPrint(
      'TaskService: Reminder created on backend for ${task.triggerTime.toIso8601String()}',
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
    try {
      await SecureBackendClient.delete('$_backendUrl/api/tasks/$taskId');
    } catch (e) {
      debugPrint('TaskService: Delete backend task failed: $e');
    }
    _tasks.removeWhere((t) => t.id == taskId);
    await _saveTasks();
  }

  /// 取消所有任务
  static Future<void> cancelAllTasks() async {
    final ids = _tasks.map((t) => t.id).toList();
    for (final id in ids) {
      try {
        await SecureBackendClient.delete('$_backendUrl/api/tasks/$id');
      } catch (_) {}
    }
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

  /// 获取后端 URL
  static String get _backendUrl => SettingsService.instance.backendUrl;

  /// 从后端拉取任务
  static Future<bool> fetchFromBackend() async {
    try {
      final response = await SecureBackendClient.get('$_backendUrl/api/tasks');
      if (response.statusCode == 200) {
        final data = response.data;
        if (data['tasks'] is List) {
          final remoteTasks = <ScheduledTask>[];
          for (final raw in data['tasks'] as List) {
            if (raw is! Map) continue;
            final map = Map<String, dynamic>.from(raw);
            final triggerTime =
                DateTime.tryParse(map['trigger_time']?.toString() ?? '');
            if (triggerTime == null) continue;

            remoteTasks.add(
              ScheduledTask(
                id: map['id']?.toString() ?? '',
                chatId:
                    map['chat_id']?.toString() ?? map['role_id']?.toString() ?? '',
                roleId: map['role_id']?.toString() ?? '',
                message: map['message']?.toString() ?? '',
                aiPrompt: map['ai_prompt']?.toString(),
                triggerTime: triggerTime,
                type: TaskType.reminder,
                isCompleted: map['enabled'] == false,
              ),
            );
          }

          _tasks
            ..clear()
            ..addAll(remoteTasks);
          await _saveTasks();
          debugPrint(
            'TaskService: Synced ${remoteTasks.length} tasks from backend',
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
