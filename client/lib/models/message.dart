import 'dart:convert';

/// 消息模型
/// 用于表示聊天中的单条消息
class Message {
  final String id;
  final String senderId;
  final String receiverId;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final bool isRead;
  final MessageSendStatus sendStatus;

  /// 引用的消息 ID（可为空）
  final String? quotedMessageId;

  /// 引用消息的预览文本
  final String? quotedPreviewText;

  /// 生成本条消息时对应的 AI 请求 id（可为空）。
  /// 工具调用历史功能用它按需向服务端查询调用明细，明细本身不随消息存储/传输。
  final String? requestId;

  /// 本条消息生成过程中是否发生过工具调用（仅作展示入口开关，不含明细）。
  final bool hasToolCalls;

  /// 模型思考过程（仅 AI 消息可能非空，是否展示由角色设置决定）。
  final String? reasoningContent;

  Message({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    this.type = MessageType.text,
    required this.timestamp,
    this.isRead = false,
    this.sendStatus = MessageSendStatus.sent,
    this.quotedMessageId,
    this.quotedPreviewText,
    this.requestId,
    this.hasToolCalls = false,
    this.reasoningContent,
  });

  /// 创建带引用的消息
  factory Message.withQuote({
    required String id,
    required String senderId,
    required String receiverId,
    required String content,
    required Message quotedMessage,
    MessageType type = MessageType.text,
    DateTime? timestamp,
  }) {
    return Message(
      id: id,
      senderId: senderId,
      receiverId: receiverId,
      content: content,
      type: type,
      timestamp: timestamp ?? DateTime.now(),
      quotedMessageId: quotedMessage.id,
      quotedPreviewText: quotedMessage.content.length > 50
          ? '${quotedMessage.content.substring(0, 50)}...'
          : quotedMessage.content,
    );
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      senderId: json['sender_id'] as String,
      receiverId: json['receiver_id'] as String,
      content: json['content'] as String,
      type: MessageType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MessageType.text,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
      isRead: json['is_read'] as bool? ?? false,
      sendStatus: MessageSendStatus.values.firstWhere(
        (e) => e.name == (json['send_status'] as String?),
        orElse: () => MessageSendStatus.sent,
      ),
      quotedMessageId: json['quoted_message_id'] as String?,
      quotedPreviewText: json['quoted_preview_text'] as String?,
      requestId: json['request_id'] as String?,
      hasToolCalls: json['has_tool_calls'] as bool? ?? false,
      reasoningContent: json['reasoning_content'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender_id': senderId,
      'receiver_id': receiverId,
      'content': content,
      'type': type.name,
      'timestamp': timestamp.toIso8601String(),
      'is_read': isRead,
      'send_status': sendStatus.name,
      'quoted_message_id': quotedMessageId,
      'quoted_preview_text': quotedPreviewText,
      if (requestId != null) 'request_id': requestId,
      'has_tool_calls': hasToolCalls,
      if (reasoningContent != null && reasoningContent!.isNotEmpty)
        'reasoning_content': reasoningContent,
    };
  }

  /// 序列化为存储字符串（使用 JSON）
  String toStorageString() {
    return jsonEncode(toJson());
  }

  /// 从存储字符串反序列化
  factory Message.fromStorageString(String str) {
    return Message.fromJson(jsonDecode(str) as Map<String, dynamic>);
  }

  /// 复制并修改
  Message copyWith({
    String? id,
    String? senderId,
    String? receiverId,
    String? content,
    MessageType? type,
    DateTime? timestamp,
    bool? isRead,
    MessageSendStatus? sendStatus,
    String? quotedMessageId,
    String? quotedPreviewText,
    String? requestId,
    bool? hasToolCalls,
    String? reasoningContent,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      sendStatus: sendStatus ?? this.sendStatus,
      quotedMessageId: quotedMessageId ?? this.quotedMessageId,
      quotedPreviewText: quotedPreviewText ?? this.quotedPreviewText,
      requestId: requestId ?? this.requestId,
      hasToolCalls: hasToolCalls ?? this.hasToolCalls,
      reasoningContent: reasoningContent ?? this.reasoningContent,
    );
  }

  /// 是否有引用
  bool get hasQuote => quotedMessageId != null;

  /// 是否携带可用于查询工具调用历史的 request_id
  bool get hasRequestId => requestId != null && requestId!.isNotEmpty;

  /// 是否有可展示的思考过程
  bool get hasReasoning =>
      reasoningContent != null && reasoningContent!.trim().isNotEmpty;
}

/// 消息类型枚举
enum MessageType {
  text, // 文本消息
  image, // 图片消息
  voice, // 语音消息
  video, // 视频消息
  file, // 文件消息
  sticker, // 表情包消息
}

enum MessageSendStatus {
  /// 已写入本地、正在同步到后端（在途）。
  sending,

  /// 已成功同步到后端。
  sent,

  /// 同步最终失败，可手动重发。
  failed,
}
