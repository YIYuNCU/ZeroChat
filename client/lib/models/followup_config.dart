/// 无回复续写配置模型
/// AI 说完话后，若用户在设定时长内未回复，则由 AI 主动继续跟进（角色独立）。
/// 续写的具体时长/内容由 AI 通过 continue_if_no_reply 工具自行决定，
/// 此处仅配置是否启用、以及最大连续续写次数。
class FollowupConfig {
  /// 是否启用无回复续写
  final bool enabled;

  /// 最大连续续写次数，超过后 AI 需自然收尾
  final int maxChain;

  const FollowupConfig({
    this.enabled = true,
    this.maxChain = 3,
  });

  /// 默认配置
  factory FollowupConfig.defaultConfig() => const FollowupConfig();

  /// 从 JSON 创建
  factory FollowupConfig.fromJson(Map<String, dynamic> json) {
    return FollowupConfig(
      enabled: json['enabled'] as bool? ?? true,
      maxChain: ((json['max_chain'] as num?)?.round() ?? 3).clamp(1, 10),
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'max_chain': maxChain,
    };
  }

  /// 转换为服务端配置
  Map<String, dynamic> toBackendJson() => toJson();

  /// 复制并修改
  FollowupConfig copyWith({
    bool? enabled,
    int? maxChain,
  }) {
    return FollowupConfig(
      enabled: enabled ?? this.enabled,
      maxChain: maxChain ?? this.maxChain,
    );
  }
}
