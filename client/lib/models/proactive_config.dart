/// 星期名称（ISO 1=周一 .. 7=周日）
const List<String> kWeekdayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

bool _isValidDate(String value) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return false;
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day;
}

/// 一条安静时间规则（可自定义循环：每天 / 每周自选星期 / 指定日期一次）。
class QuietRule {
  final int startMinute;
  final int endMinute;
  final String repeatType;
  final List<int> weekdays;
  final String? date;

  static const String repeatDaily = 'daily';
  static const String repeatWeekly = 'weekly';
  static const String repeatOnce = 'once';

  const QuietRule({
    required this.startMinute,
    required this.endMinute,
    this.repeatType = repeatDaily,
    this.weekdays = const [],
    this.date,
  });

  bool get isWeekly => repeatType == repeatWeekly;
  bool get isOnce => repeatType == repeatOnce;

  factory QuietRule.fromJson(Map<String, dynamic> json) {
    final startMinute = (json['start_minute'] as num?)?.toInt() ?? 0;
    final endMinute = (json['end_minute'] as num?)?.toInt() ?? 0;
    final repeatType = json['repeat_type']?.toString() ?? repeatDaily;
    final rawWeekdays = json['weekdays'];
    var weekdays = rawWeekdays is List
        ? rawWeekdays
              .whereType<num>()
              .map((item) => item.toInt())
              .where((day) => day >= 1 && day <= 7)
              .toSet()
              .toList()
        : <int>[];
    weekdays.sort();
    final date = json['date']?.toString();
    return QuietRule(
      startMinute: startMinute,
      endMinute: endMinute,
      repeatType: repeatType,
      weekdays: repeatType == repeatWeekly ? weekdays : const [],
      date: repeatType == repeatOnce && date != null && date.isNotEmpty
          ? date
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'start_minute': startMinute,
    'end_minute': endMinute,
    'repeat_type': repeatType,
    'weekdays': isWeekly ? weekdays : const <int>[],
    if (isOnce) 'date': date,
  };

  QuietRule copyWith({
    int? startMinute,
    int? endMinute,
    String? repeatType,
    List<int>? weekdays,
    String? date,
  }) {
    final nextRepeatType = repeatType ?? this.repeatType;
    return QuietRule(
      startMinute: startMinute ?? this.startMinute,
      endMinute: endMinute ?? this.endMinute,
      repeatType: nextRepeatType,
      weekdays: weekdays ?? this.weekdays,
      date: nextRepeatType == repeatOnce ? (date ?? this.date) : null,
    );
  }

  String get label {
    final range = '${formatMinute(startMinute)} - ${formatMinute(endMinute)}';
    switch (repeatType) {
      case repeatDaily:
        return '每天 $range';
      case repeatWeekly:
        final names = weekdays.map((day) => kWeekdayNames[day - 1]).join('、');
        return '每周$names $range';
      case repeatOnce:
        final shortDate = date == null || date!.length < 10
            ? ''
            : '${date!.substring(5, 7)}-${date!.substring(8, 10)}';
        return '$shortDate $range';
      default:
        return range;
    }
  }

  static String formatMinute(int value) {
    final hour = value ~/ 60;
    final minute = value % 60;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }
}

/// 校验安静规则列表。
/// 结构：时间范围合法；weekly 需有有效星期；once 需有合法日期。
/// 重叠：同一星期几上的非 once 规则不得重叠或首尾相接（once 为单次例外）。
String? validateQuietRules(List<QuietRule> rules) {
  final buckets = <int, List<({int start, int end})>>{};
  for (final rule in rules) {
    if (rule.startMinute < 0 ||
        rule.startMinute >= 24 * 60 ||
        rule.endMinute < 0 ||
        rule.endMinute >= 24 * 60) {
      return '安静时间必须在 00:00 到 23:59 之间';
    }
    if (rule.startMinute == rule.endMinute) {
      return '安静时间的开始和结束不能相同';
    }

    if (rule.isWeekly) {
      if (rule.weekdays.isEmpty) {
        return '每周规则需要选择至少一个星期';
      }
      if (rule.weekdays.any((day) => day < 1 || day > 7)) {
        return '星期取值需在 1-7（1=周一 .. 7=周日）';
      }
      if (rule.weekdays.toSet().length != rule.weekdays.length) {
        return '星期不能重复选择';
      }
    }
    if (rule.isOnce) {
      final value = rule.date;
      if (value == null || value.isEmpty || !_isValidDate(value)) {
        return '指定日期规则需要有效日期（YYYY-MM-DD）';
      }
    }
    if (rule.isOnce) continue; // 单次例外不参与跨规则重叠校验

    final days = rule.isWeekly ? rule.weekdays : [1, 2, 3, 4, 5, 6, 7];
    for (final day in days) {
      final spans = buckets.putIfAbsent(day, () => []);
      if (rule.startMinute < rule.endMinute) {
        spans.add((start: rule.startMinute, end: rule.endMinute));
      } else {
        spans.add((start: rule.startMinute, end: 24 * 60));
        final nextDay = day % 7 + 1;
        buckets
            .putIfAbsent(nextDay, () => [])
            .add((start: 0, end: rule.endMinute));
      }
    }
  }

  for (final spans in buckets.values) {
    final sorted = [...spans]..sort((a, b) => a.start.compareTo(b.start));
    for (var index = 1; index < sorted.length; index++) {
      if (sorted[index].start <= sorted[index - 1].end) {
        return '安静时间不能重叠或首尾相接';
      }
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

  /// 角色安静规则（精确到分钟，支持每天/每周/指定日期循环）。
  final List<QuietRule> quietRules;

  const ProactiveConfig({
    this.enabled = false,
    this.triggerPrompt = '请你模拟角色，给用户发消息，想知道用户在做什么',
    this.minIntervalMinutes = 60,
    this.maxIntervalMinutes = 240,
    this.nextTriggerTime,
    this.quietRules = const [
      QuietRule(startMinute: 23 * 60, endMinute: 7 * 60),
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
    final rawRules = json['quiet_periods'];
    final quietRules = rawRules is List
        ? rawRules
              .whereType<Map>()
              .map(
                (item) => QuietRule.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
        : [
            QuietRule(
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
      quietRules: quietRules,
    );
  }

  /// 转换为 JSON（本地存储）
  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'trigger_prompt': triggerPrompt,
      'min_interval_minutes': minIntervalMinutes,
      'max_interval_minutes': maxIntervalMinutes,
      'next_trigger_time': nextTriggerTime?.toIso8601String(),
      'quiet_periods': quietRules.map((rule) => rule.toJson()).toList(),
    };
  }

  /// 转换为服务端配置。下次触发时间由服务端调度器维护。
  Map<String, dynamic> toBackendJson() {
    return {
      'enabled': enabled,
      'trigger_prompt': triggerPrompt,
      'min_interval_minutes': minIntervalMinutes,
      'max_interval_minutes': maxIntervalMinutes,
      'quiet_periods': quietRules.map((rule) => rule.toJson()).toList(),
    };
  }

  /// 复制并修改
  ProactiveConfig copyWith({
    bool? enabled,
    String? triggerPrompt,
    int? minIntervalMinutes,
    int? maxIntervalMinutes,
    DateTime? nextTriggerTime,
    List<QuietRule>? quietRules,
  }) {
    return ProactiveConfig(
      enabled: enabled ?? this.enabled,
      triggerPrompt: triggerPrompt ?? this.triggerPrompt,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      maxIntervalMinutes: maxIntervalMinutes ?? this.maxIntervalMinutes,
      nextTriggerTime: nextTriggerTime ?? this.nextTriggerTime,
      quietRules: quietRules ?? this.quietRules,
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
      quietRules: quietRules,
    );
  }
}