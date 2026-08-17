class QuietPeriod {
  final int startMinute;
  final int endMinute;

  const QuietPeriod({required this.startMinute, required this.endMinute});

  factory QuietPeriod.fromJson(Map<String, dynamic> json) {
    return QuietPeriod(
      startMinute: (json['start_minute'] as num?)?.toInt() ?? 0,
      endMinute: (json['end_minute'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'start_minute': startMinute,
    'end_minute': endMinute,
  };

  QuietPeriod copyWith({int? startMinute, int? endMinute}) => QuietPeriod(
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
  );

  String get label =>
      '${formatMinute(startMinute)} - ${formatMinute(endMinute)}';

  static String formatMinute(int value) {
    final hour = value ~/ 60;
    final minute = value % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
}

String? validateQuietPeriods(List<QuietPeriod> periods) {
  final spans = <({int start, int end})>[];
  for (final period in periods) {
    if (period.startMinute < 0 ||
        period.startMinute >= 24 * 60 ||
        period.endMinute < 0 ||
        period.endMinute >= 24 * 60) {
      return '安静时间必须在 00:00 到 23:59 之间';
    }
    if (period.startMinute == period.endMinute) {
      return '安静时间的开始和结束不能相同';
    }
    if (period.startMinute < period.endMinute) {
      spans.add((start: period.startMinute, end: period.endMinute));
    } else {
      spans.add((start: 0, end: period.endMinute));
      spans.add((start: period.startMinute, end: 24 * 60));
    }
  }
  spans.sort((left, right) => left.start.compareTo(right.start));
  for (var index = 1; index < spans.length; index++) {
    if (spans[index].start <= spans[index - 1].end) {
      return '安静时间不能重叠或首尾相接';
    }
  }
  return null;
}

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

  /// 角色安静时段，精确到分钟。
  final List<QuietPeriod> quietPeriods;

  const ProactiveConfig({
    this.enabled = false,
    this.triggerPrompt = '请你模拟角色，给用户发消息，想知道用户在做什么',
    this.minIntervalMinutes = 60,
    this.maxIntervalMinutes = 240,
    this.nextTriggerTime,
    this.quietPeriods = const [
      QuietPeriod(startMinute: 23 * 60, endMinute: 7 * 60),
    ],
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
    final rawPeriods = json['quiet_periods'];
    final quietPeriods = rawPeriods is List
        ? rawPeriods
              .whereType<Map>()
              .map(
                (item) => QuietPeriod.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
        : [
            QuietPeriod(
              startMinute:
                  ((json['quiet_hours_start'] as num?)?.toInt() ?? 23) * 60,
              endMinute: ((json['quiet_hours_end'] as num?)?.toInt() ?? 7) * 60,
            ),
          ];
    return ProactiveConfig(
      enabled: json['enabled'] as bool? ?? false,
      triggerPrompt:
          json['trigger_prompt'] as String? ?? '请你模拟角色，给用户发消息，想知道用户在做什么',
      minIntervalMinutes: minMinutes.clamp(1, 1440),
      maxIntervalMinutes: maxMinutes.clamp(1, 1440),
      nextTriggerTime: json['next_trigger_time'] != null
          ? DateTime.parse(json['next_trigger_time'] as String)
          : null,
      quietPeriods: quietPeriods,
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
      'quiet_periods': quietPeriods.map((period) => period.toJson()).toList(),
    };
  }

  /// 转换为服务端配置。下次触发时间由服务端调度器维护。
  Map<String, dynamic> toBackendJson() {
    return {
      'enabled': enabled,
      'trigger_prompt': triggerPrompt,
      'min_interval_minutes': minIntervalMinutes,
      'max_interval_minutes': maxIntervalMinutes,
      'quiet_periods': quietPeriods.map((period) => period.toJson()).toList(),
    };
  }

  /// 复制并修改
  ProactiveConfig copyWith({
    bool? enabled,
    String? triggerPrompt,
    int? minIntervalMinutes,
    int? maxIntervalMinutes,
    DateTime? nextTriggerTime,
    List<QuietPeriod>? quietPeriods,
  }) {
    return ProactiveConfig(
      enabled: enabled ?? this.enabled,
      triggerPrompt: triggerPrompt ?? this.triggerPrompt,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      maxIntervalMinutes: maxIntervalMinutes ?? this.maxIntervalMinutes,
      nextTriggerTime: nextTriggerTime ?? this.nextTriggerTime,
      quietPeriods: quietPeriods ?? this.quietPeriods,
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
      quietPeriods: quietPeriods,
    );
  }
}
