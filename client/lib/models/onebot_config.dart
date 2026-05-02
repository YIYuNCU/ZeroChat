/// OneBot V11 接口配置模型
/// 用于配置角色的 OneBot 消息接收接口
class OneBotConfig {
  /// 是否启用 OneBot 接口
  final bool enabled;

  /// 鉴权密钥
  final String secret;

  /// 机器人自身 QQ 号（用于判断群聊是否 @了机器人）
  final int selfId;

  /// 主用户 QQ 号（与默认前端用户视为同一人）
  final int mainUserId;

  /// 用户白名单（QQ号列表），为空则不处理私聊
  final List<int> allowedUsers;

  /// 群聊白名单（群号列表），为空则不处理群聊
  final List<int> allowedGroups;

  const OneBotConfig({
    this.enabled = false,
    this.secret = '',
    this.selfId = 0,
    this.mainUserId = 0,
    this.allowedUsers = const [],
    this.allowedGroups = const [],
  });

  factory OneBotConfig.defaultConfig() => const OneBotConfig();

  factory OneBotConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return OneBotConfig.defaultConfig();
    return OneBotConfig(
      enabled: json['enabled'] as bool? ?? false,
      secret: json['secret'] as String? ?? '',
      selfId: int.tryParse(json['self_id']?.toString() ?? '') ?? 0,
      mainUserId: int.tryParse(json['main_user_id']?.toString() ?? '') ?? 0,
      allowedUsers: (json['allowed_users'] as List<dynamic>?)
              ?.map((e) => int.tryParse(e.toString()) ?? 0)
              .where((e) => e > 0)
              .toList() ??
          [],
      allowedGroups: (json['allowed_groups'] as List<dynamic>?)
              ?.map((e) => int.tryParse(e.toString()) ?? 0)
              .where((e) => e > 0)
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'secret': secret,
      'self_id': selfId,
      'main_user_id': mainUserId,
      'allowed_users': allowedUsers,
      'allowed_groups': allowedGroups,
    };
  }

  OneBotConfig copyWith({
    bool? enabled,
    String? secret,
    int? selfId,
    int? mainUserId,
    List<int>? allowedUsers,
    List<int>? allowedGroups,
  }) {
    return OneBotConfig(
      enabled: enabled ?? this.enabled,
      secret: secret ?? this.secret,
      selfId: selfId ?? this.selfId,
      mainUserId: mainUserId ?? this.mainUserId,
      allowedUsers: allowedUsers ?? this.allowedUsers,
      allowedGroups: allowedGroups ?? this.allowedGroups,
    );
  }
}
