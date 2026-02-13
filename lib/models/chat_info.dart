/// 聊天信息模型
/// 存储聊天列表中的元数据
class ChatInfo {
  final String id;
  final String name;
  final String? avatarUrl;
  final String lastMessage;
  final DateTime lastMessageTime;
  final int unreadCount;
  final bool isPinned;
  final bool isGroup;
  final List<String>? memberIds; // 群聊成员ID列表

  ChatInfo({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.lastMessage = '',
    DateTime? lastMessageTime,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isGroup = false,
    this.memberIds,
  }) : lastMessageTime = lastMessageTime ?? DateTime.now();

  ChatInfo copyWith({
    String? id,
    String? name,
    String? avatarUrl,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    bool? isPinned,
    bool? isGroup,
    List<String>? memberIds,
  }) {
    return ChatInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned ?? this.isPinned,
      isGroup: isGroup ?? this.isGroup,
      memberIds: memberIds ?? this.memberIds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'avatar_url': avatarUrl,
      'last_message': lastMessage,
      'last_message_time': lastMessageTime.toIso8601String(),
      'unread_count': unreadCount,
      'is_pinned': isPinned,
      'is_group': isGroup,
      'member_ids': memberIds,
    };
  }

  factory ChatInfo.fromJson(Map<String, dynamic> json) {
    return ChatInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      lastMessage: json['last_message'] as String? ?? '',
      lastMessageTime: json['last_message_time'] != null
          ? DateTime.parse(json['last_message_time'] as String)
          : DateTime.now(),
      unreadCount: json['unread_count'] as int? ?? 0,
      isPinned: json['is_pinned'] as bool? ?? false,
      isGroup: json['is_group'] as bool? ?? false,
      memberIds: (json['member_ids'] as List<dynamic>?)?.cast<String>(),
    );
  }
}
