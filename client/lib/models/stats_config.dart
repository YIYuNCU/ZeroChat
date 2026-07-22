// 数值系统配置模型（角色独立）
// 用于配置 AI 角色回复中的「数值」部分：是否启用、有哪些数值、每个数值的上下限与作用

/// 单个数值定义
class StatItem {
  /// 唯一键（用于状态存储与解析匹配）
  final String key;

  /// 展示名称
  final String name;

  /// 下限
  final double min;

  /// 上限
  final double max;

  /// 初始值（缺省取 min）
  final double? initial;

  /// 数值的作用/含义
  final String description;

  const StatItem({
    required this.key,
    this.name = '',
    this.min = 0,
    this.max = 100,
    this.initial,
    this.description = '',
  });

  factory StatItem.fromJson(Map<String, dynamic> json) {
    return StatItem(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      min: (json['min'] as num?)?.toDouble() ?? 0,
      max: (json['max'] as num?)?.toDouble() ?? 100,
      initial: (json['initial'] as num?)?.toDouble(),
      description: json['description'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'name': name,
      'min': min,
      'max': max,
      'initial': initial,
      'description': description,
    };
  }

  StatItem copyWith({
    String? key,
    String? name,
    double? min,
    double? max,
    double? initial,
    String? description,
  }) {
    return StatItem(
      key: key ?? this.key,
      name: name ?? this.name,
      min: min ?? this.min,
      max: max ?? this.max,
      initial: initial ?? this.initial,
      description: description ?? this.description,
    );
  }
}

/// 数值系统配置
class StatsConfig {
  /// 是否启用数值系统
  final bool enabled;

  /// 数值定义列表
  final List<StatItem> stats;

  const StatsConfig({
    this.enabled = false,
    this.stats = const [],
  });

  factory StatsConfig.defaultConfig() => const StatsConfig();

  factory StatsConfig.fromJson(Map<String, dynamic> json) {
    final rawStats = json['stats'] as List<dynamic>?;
    return StatsConfig(
      enabled: json['enabled'] as bool? ?? false,
      stats: rawStats
              ?.whereType<Map<String, dynamic>>()
              .map(StatItem.fromJson)
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'stats': stats.map((s) => s.toJson()).toList(),
    };
  }

  StatsConfig copyWith({
    bool? enabled,
    List<StatItem>? stats,
  }) {
    return StatsConfig(
      enabled: enabled ?? this.enabled,
      stats: stats ?? this.stats,
    );
  }
}
