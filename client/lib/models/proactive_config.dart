/// 主动消息配置模型
/// 用于配置 AI 角色的主动消息触发行为（角色独立）
class ProactiveConfig {
  /// 是否启用主动消息
  final bool enabled;

  /// 自定义触发提示词（发送给 AI 让它生成主动消息）
  final String triggerPrompt;

  /// 最小触发间隔（分钟）
  final int minIntervalMinutes;

  /// 最大触发间隔（分钟）
  final int maxIntervalMinutes;

  /// 下次触发时间（时间戳，持久化用）
  final DateTime? nextTriggerTime;

  const ProactiveConfig({
    this.enabled = false,
    this.triggerPrompt = '请你模拟角色，给用户发消息，想知道用户在做什么',
    this.minIntervalMinutes = 60,
    this.maxIntervalMinutes = 240,
    this.nextTriggerTime,
  });

  /// 默认配置
  factory ProactiveConfig.defaultConfig() => const ProactiveConfig();

  /// 从 JSON 创建
  factory ProactiveConfig.fromJson(Map<String, dynamic> json) {
    final minMinutes =
        (json['min_interval_minutes'] as num?)?.round() ??
        (((json['min_countdown_hours'] as num?)?.toDouble() ?? 1.0) * 60)
            .round();
    final maxMinutes =
        (json['max_interval_minutes'] as num?)?.round() ??
        (((json['max_countdown_hours'] as num?)?.toDouble() ?? 4.0) * 60)
            .round();
    return ProactiveConfig(
      enabled: json['enabled'] as bool? ?? false,
      triggerPrompt:
          json['trigger_prompt'] as String? ?? '请你模拟角色，给用户发消息，想知道用户在做什么',
      minIntervalMinutes: minMinutes.clamp(1, 1440),
      maxIntervalMinutes: maxMinutes.clamp(1, 1440),
      nextTriggerTime: json['next_trigger_time'] != null
          ? DateTime.parse(json['next_trigger_time'] as String)
          : null,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'trigger_prompt': triggerPrompt,
      'min_interval_minutes': minIntervalMinutes,
      'max_interval_minutes': maxIntervalMinutes,
      'next_trigger_time': nextTriggerTime?.toIso8601String(),
    };
  }

  /// 转换为服务端配置。下次触发时间由服务端调度器维护。
  Map<String, dynamic> toBackendJson() {
    return {
      'enabled': enabled,
      'trigger_prompt': triggerPrompt,
      'min_interval_minutes': minIntervalMinutes,
      'max_interval_minutes': maxIntervalMinutes,
    };
  }

  /// 复制并修改
  ProactiveConfig copyWith({
    bool? enabled,
    String? triggerPrompt,
    int? minIntervalMinutes,
    int? maxIntervalMinutes,
    DateTime? nextTriggerTime,
  }) {
    return ProactiveConfig(
      enabled: enabled ?? this.enabled,
      triggerPrompt: triggerPrompt ?? this.triggerPrompt,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      maxIntervalMinutes: maxIntervalMinutes ?? this.maxIntervalMinutes,
      nextTriggerTime: nextTriggerTime ?? this.nextTriggerTime,
    );
  }

  /// 清除下次触发时间（强制重新随机）
  ProactiveConfig clearNextTriggerTime() {
    return ProactiveConfig(
      enabled: enabled,
      triggerPrompt: triggerPrompt,
      minIntervalMinutes: minIntervalMinutes,
      maxIntervalMinutes: maxIntervalMinutes,
      nextTriggerTime: null,
    );
  }
}
