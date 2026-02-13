/// 收藏的消息
class FavoriteMessage {
  final String id;
  final String messageId; // 原消息 ID
  final String chatId; // 所属聊天 ID
  final String chatName; // 所属聊天名称
  final String content; // 消息内容
  final String senderName; // 发送者名称
  final bool isFromAI; // 是否来自 AI
  final bool isSticker; // 是否是表情包
  final String? stickerPath; // 表情包路径（如果是表情包）
  final DateTime messageTime; // 原消息时间
  final DateTime favoriteTime; // 收藏时间

  const FavoriteMessage({
    required this.id,
    required this.messageId,
    required this.chatId,
    required this.chatName,
    required this.content,
    required this.senderName,
    required this.isFromAI,
    this.isSticker = false,
    this.stickerPath,
    required this.messageTime,
    required this.favoriteTime,
  });

  factory FavoriteMessage.fromJson(Map<String, dynamic> json) {
    return FavoriteMessage(
      id: json['id'] as String,
      messageId: json['message_id'] as String,
      chatId: json['chat_id'] as String,
      chatName: json['chat_name'] as String,
      content: json['content'] as String,
      senderName: json['sender_name'] as String,
      isFromAI: json['is_from_ai'] as bool? ?? false,
      isSticker: json['is_sticker'] as bool? ?? false,
      stickerPath: json['sticker_path'] as String?,
      messageTime: DateTime.parse(json['message_time'] as String),
      favoriteTime: DateTime.parse(json['favorite_time'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'message_id': messageId,
      'chat_id': chatId,
      'chat_name': chatName,
      'content': content,
      'sender_name': senderName,
      'is_from_ai': isFromAI,
      'is_sticker': isSticker,
      'sticker_path': stickerPath,
      'message_time': messageTime.toIso8601String(),
      'favorite_time': favoriteTime.toIso8601String(),
    };
  }
}
