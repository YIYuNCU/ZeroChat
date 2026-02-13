import '../models/message.dart';

/// 消息快照（收藏时的消息副本）
/// 不依赖原消息，独立存储
class MessageSnapshot {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final bool isFromUser;

  /// 引用信息（如有）
  final String? quotedContent;

  const MessageSnapshot({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.type,
    required this.timestamp,
    required this.isFromUser,
    this.quotedContent,
  });

  /// 从 Message 创建快照
  factory MessageSnapshot.fromMessage(
    Message message, {
    required String senderName,
  }) {
    return MessageSnapshot(
      id: message.id,
      senderId: message.senderId,
      senderName: senderName,
      content: message.content,
      type: message.type,
      timestamp: message.timestamp,
      isFromUser: message.senderId == 'me',
      quotedContent: message.quotedPreviewText,
    );
  }

  factory MessageSnapshot.fromJson(Map<String, dynamic> json) {
    return MessageSnapshot(
      id: json['id'] as String,
      senderId: json['sender_id'] as String,
      senderName: json['sender_name'] as String,
      content: json['content'] as String,
      type: MessageType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MessageType.text,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      isFromUser: json['is_from_user'] as bool? ?? false,
      quotedContent: json['quoted_content'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'sender_name': senderName,
      'content': content,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'is_from_user': isFromUser,
      'quoted_content': quotedContent,
    };
  }
}

/// 收藏合集
/// 一次收藏操作生成一个合集，包含多条消息快照
class FavoriteCollection {
  final String id;
  final String chatId;
  final String chatName;
  final String userName;
  final String roleName;
  final DateTime createdAt;
  final List<MessageSnapshot> messages;
  final List<String> tags;

  const FavoriteCollection({
    required this.id,
    required this.chatId,
    required this.chatName,
    required this.userName,
    required this.roleName,
    required this.createdAt,
    required this.messages,
    this.tags = const [],
  });

  /// 获取标题
  String get title => '$userName 与 $roleName 的聊天记录';

  /// 获取预览（前两条消息）
  List<String> get preview {
    final result = <String>[];
    for (var i = 0; i < messages.length && i < 2; i++) {
      final msg = messages[i];
      final prefix = msg.isFromUser ? userName : roleName;
      final content = msg.content.length > 30
          ? '${msg.content.substring(0, 30)}...'
          : msg.content;
      result.add('$prefix：$content');
    }
    return result;
  }

  factory FavoriteCollection.fromJson(Map<String, dynamic> json) {
    return FavoriteCollection(
      id: json['id'] as String,
      chatId: json['chat_id'] as String,
      chatName: json['chat_name'] as String,
      userName: json['user_name'] as String,
      roleName: json['role_name'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      messages: (json['messages'] as List<dynamic>)
          .map((m) => MessageSnapshot.fromJson(m as Map<String, dynamic>))
          .toList(),
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chat_id': chatId,
      'chat_name': chatName,
      'user_name': userName,
      'role_name': roleName,
      'created_at': createdAt.toIso8601String(),
      'messages': messages.map((m) => m.toJson()).toList(),
      'tags': tags,
    };
  }

  FavoriteCollection copyWith({
    String? id,
    String? chatId,
    String? chatName,
    String? userName,
    String? roleName,
    DateTime? createdAt,
    List<MessageSnapshot>? messages,
    List<String>? tags,
  }) {
    return FavoriteCollection(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      chatName: chatName ?? this.chatName,
      userName: userName ?? this.userName,
      roleName: roleName ?? this.roleName,
      createdAt: createdAt ?? this.createdAt,
      messages: messages ?? this.messages,
      tags: tags ?? this.tags,
    );
  }

  /// 添加标签
  FavoriteCollection addTag(String tag) {
    if (tags.contains(tag)) return this;
    return copyWith(tags: [...tags, tag]);
  }

  /// 移除标签
  FavoriteCollection removeTag(String tag) {
    return copyWith(tags: tags.where((t) => t != tag).toList());
  }
}
