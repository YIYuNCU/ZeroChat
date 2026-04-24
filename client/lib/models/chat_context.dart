/// 聊天上下文模型
/// 管理单个聊天会话的状态
class ChatContext {
  /// 聊天 ID
  final String chatId;

  /// 是否群聊
  final bool isGroup;

  /// 群聊成员角色 ID 列表
  final List<String> memberIds;

  /// 最后消息时间
  DateTime lastMessageTime;

  /// 消息计数
  int messageCount;

  /// 是否正在处理 AI 响应
  bool isProcessing;

  /// 最后发言的角色 ID（用于群聊调度）
  String? lastSpeakerRoleId;

  /// 各角色连续发言次数（用于群聊调度）
  final Map<String, int> consecutiveSpeakCount;

  ChatContext({
    required this.chatId,
    this.isGroup = false,
    List<String>? memberIds,
    DateTime? lastMessageTime,
    this.messageCount = 0,
    this.isProcessing = false,
    this.lastSpeakerRoleId,
    Map<String, int>? consecutiveSpeakCount,
  }) : memberIds = memberIds ?? [],
       lastMessageTime = lastMessageTime ?? DateTime.now(),
       consecutiveSpeakCount = consecutiveSpeakCount ?? {};

  /// 复制并修改
  ChatContext copyWith({
    String? chatId,
    bool? isGroup,
    List<String>? memberIds,
    DateTime? lastMessageTime,
    int? messageCount,
    bool? isProcessing,
    String? lastSpeakerRoleId,
    Map<String, int>? consecutiveSpeakCount,
  }) {
    return ChatContext(
      chatId: chatId ?? this.chatId,
      isGroup: isGroup ?? this.isGroup,
      memberIds: memberIds ?? this.memberIds,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      messageCount: messageCount ?? this.messageCount,
      isProcessing: isProcessing ?? this.isProcessing,
      lastSpeakerRoleId: lastSpeakerRoleId ?? this.lastSpeakerRoleId,
      consecutiveSpeakCount:
          consecutiveSpeakCount ?? this.consecutiveSpeakCount,
    );
  }

  /// 重置角色连续发言计数
  void resetConsecutiveCount(String roleId) {
    consecutiveSpeakCount.clear();
    consecutiveSpeakCount[roleId] = 1;
  }

  /// 增加角色连续发言计数
  void incrementConsecutiveCount(String roleId) {
    if (lastSpeakerRoleId == roleId) {
      consecutiveSpeakCount[roleId] = (consecutiveSpeakCount[roleId] ?? 0) + 1;
    } else {
      resetConsecutiveCount(roleId);
    }
    lastSpeakerRoleId = roleId;
  }

  /// 获取角色连续发言次数
  int getConsecutiveCount(String roleId) {
    return consecutiveSpeakCount[roleId] ?? 0;
  }
}
