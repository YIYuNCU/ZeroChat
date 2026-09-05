import 'package:flutter/foundation.dart';
import 'storage_service.dart';
import 'settings_service.dart';
import 'background_runtime_service.dart';
import 'secure_websocket_client.dart';

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
  static const String _hashStorageKey = 'scheduled_tasks_hash';
  static String _localHash = '';
  static bool _hasValidLocalCache = false;

  /// in-flight 去重与 TTL 节流：启动路径两处拉取不会重复往返。
  static Future<bool>? _inFlightFetch;
  static bool _fetchAgain = false;
  static DateTime? _lastFetchAt;
  static const Duration _fetchThrottle = Duration(seconds: 30);

  /// 初始化任务服务
  static Future<void> init() async {
    await _loadTasks();
    await fetchFromBackend();
    debugPrint('TaskService initialized with ${_tasks.length} tasks');
  }

  /// 仅加载本地缓存（无网络请求），用于启动加速
  static Future<void> loadLocalOnly() async {
    await _loadTasks();
    debugPrint('TaskService local cache loaded: ${_tasks.length} tasks');
  }

  // ========== 任务管理 ==========

  static Future<void> _loadTasks() async {
    _localHash = StorageService.getString(_hashStorageKey) ?? '';
    final jsonList = StorageService.getJsonList(
      StorageService.keyScheduledTasks,
    );
    _hasValidLocalCache = jsonList != null;
    if (jsonList != null) {
      _tasks.clear();
      for (final json in jsonList) {
        try {
          final task = ScheduledTask.fromJson(json);
          if (!task.isCompleted) {
            _tasks.add(task);
          }
        } catch (e) {
          _hasValidLocalCache = false;
          debugPrint('Error loading task: $e');
        }
      }
    }
    if (!_hasValidLocalCache) {
      await _clearHash();
    }
  }

  static Future<void> _saveTasks() async {
    final jsonList = _tasks.map((t) => t.toJson()).toList();
    await StorageService.setJsonList(
      StorageService.keyScheduledTasks,
      jsonList,
    );
  }

  static Future<void> _clearHash() async {
    _localHash = '';
    await StorageService.remove(_hashStorageKey);
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
    // 尝试同步到后端，失败时仅本地保存
    String? backendId;
    try {
      final data = await SecureWebSocketClient.instance
          .request('tasks_create', {
            'chat_id': chatId,
            'role_id': roleId,
            'message': message,
            'ai_prompt': aiPrompt ?? '',
            'trigger_time': triggerTime.toIso8601String(),
            'repeat': null,
          });
      backendId = data['id']?.toString();
    } catch (e) {
      debugPrint('TaskService: Backend create failed, saving locally: $e');
    }

    final task = ScheduledTask(
      id: backendId ?? DateTime.now().millisecondsSinceEpoch.toString(),
      chatId: chatId,
      roleId: roleId,
      message: message,
      aiPrompt: aiPrompt,
      triggerTime: triggerTime,
      type: TaskType.reminder,
      isCompleted: false,
    );

    _tasks.removeWhere((t) => t.id == task.id);
    _tasks.add(task);
    await _clearHash();
    await _saveTasks();

    await BackgroundRuntimeService.applyEnabled(
      SettingsService.instance.backgroundRuntimeEnabled,
    );

    debugPrint(
      'TaskService: Reminder created${backendId != null ? ' on backend' : ' locally'} for ${task.triggerTime.toIso8601String()}',
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
      await SecureWebSocketClient.instance.request('tasks_delete', {
        'task_id': taskId,
      });
    } catch (e) {
      debugPrint('TaskService: Delete backend task failed: $e');
    }
    _tasks.removeWhere((t) => t.id == taskId);
    await _clearHash();
    await _saveTasks();
  }

  /// 取消所有任务
  static Future<void> cancelAllTasks() async {
    final ids = _tasks.map((t) => t.id).toList();
    for (final id in ids) {
      try {
        await SecureWebSocketClient.instance.request('tasks_delete', {
          'task_id': id,
        });
      } catch (_) {}
    }
    _tasks.clear();
    await _clearHash();
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

  /// 从后端拉取任务
  /// 带 in-flight 去重与 TTL 节流；[force] 为 true 时跳过节流。
  static Future<bool> fetchFromBackend({bool force = false}) async {
    final inFlight = _inFlightFetch;
    if (inFlight != null) {
      if (force) _fetchAgain = true;
      return inFlight;
    }
    if (!force && _lastFetchAt != null) {
      if (DateTime.now().difference(_lastFetchAt!) < _fetchThrottle) {
        return false;
      }
    }
    final future = _drainFetches();
    _inFlightFetch = future;
    try {
      return await future;
    } finally {
      _inFlightFetch = null;
    }
  }

  static Future<bool> _drainFetches() async {
    var changed = false;
    do {
      _fetchAgain = false;
      changed = await _doFetchFromBackend() || changed;
    } while (_fetchAgain);
    return changed;
  }

  static Future<bool> _doFetchFromBackend() async {
    _lastFetchAt = DateTime.now();
    try {
      final data = await SecureWebSocketClient.instance.request(
        'tasks_list',
        _localHash.isEmpty || !_hasValidLocalCache
            ? const <String, dynamic>{}
            : {'client_hash': _localHash},
      );
      final responseHash = data['hash']?.toString() ?? '';
      if (data['not_modified'] == true) {
        if (responseHash.isNotEmpty && responseHash != _localHash) {
          _localHash = responseHash;
          await StorageService.setString(_hashStorageKey, _localHash);
        }
        return false;
      }
      if (data['tasks'] is List) {
        final remoteTasks = <ScheduledTask>[];
        for (final raw in data['tasks'] as List) {
          if (raw is! Map) continue;
          final map = Map<String, dynamic>.from(raw);
          final triggerTime = DateTime.tryParse(
            map['trigger_time']?.toString() ?? '',
          );
          if (triggerTime == null) continue;

          remoteTasks.add(
            ScheduledTask(
              id: map['id']?.toString() ?? '',
              chatId:
                  map['chat_id']?.toString() ??
                  map['role_id']?.toString() ??
                  '',
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
        _hasValidLocalCache = true;
        _localHash = responseHash;
        if (_localHash.isNotEmpty) {
          await StorageService.setString(_hashStorageKey, _localHash);
        }
        debugPrint(
          'TaskService: Synced ${remoteTasks.length} tasks from backend',
        );
        return true;
      }
    } catch (e) {
      debugPrint('TaskService: Fetch from backend failed: $e');
    }
    return false;
  }
}
