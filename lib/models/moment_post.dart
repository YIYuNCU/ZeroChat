/// 朋友圈动态模型
/// 支持用户和 AI 角色发布
class MomentPost {
  final String id;
  final String authorId; // 'me' 为用户，否则为角色 ID
  final String authorName;
  final String? authorAvatarUrl;
  final String content;
  final List<String> imageUrls; // 图片列表（预留）
  final String? stickerPath; // 表情包路径（可选）
  final DateTime createdAt;
  final MomentType type;

  /// 点赞者 ID 列表
  final List<String> likedBy;

  /// 评论列表（预留）
  final List<MomentComment> comments;

  const MomentPost({
    required this.id,
    required this.authorId,
    required this.authorName,
    this.authorAvatarUrl,
    required this.content,
    this.imageUrls = const [],
    this.stickerPath,
    required this.createdAt,
    this.type = MomentType.text,
    this.likedBy = const [],
    this.comments = const [],
  });

  /// 是否为用户发布
  bool get isFromUser => authorId == 'me';

  /// 是否已被当前用户点赞
  bool get isLikedByMe => likedBy.contains('me');

  factory MomentPost.fromJson(Map<String, dynamic> json) {
    return MomentPost(
      id: json['id'] as String,
      authorId: json['author_id'] as String,
      authorName: json['author_name'] as String,
      authorAvatarUrl: json['author_avatar_url'] as String?,
      content: json['content'] as String,
      imageUrls: (json['image_urls'] as List<dynamic>?)?.cast<String>() ?? [],
      stickerPath: json['sticker_path'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      type: MomentType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MomentType.text,
      ),
      likedBy: (json['liked_by'] as List<dynamic>?)?.cast<String>() ?? [],
      comments:
          (json['comments'] as List<dynamic>?)
              ?.map((c) => MomentComment.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'author_id': authorId,
      'author_name': authorName,
      'author_avatar_url': authorAvatarUrl,
      'content': content,
      'image_urls': imageUrls,
      'sticker_path': stickerPath,
      'created_at': createdAt.toIso8601String(),
      'type': type.name,
      'liked_by': likedBy,
      'comments': comments.map((c) => c.toJson()).toList(),
    };
  }

  MomentPost copyWith({
    String? id,
    String? authorId,
    String? authorName,
    String? authorAvatarUrl,
    String? content,
    List<String>? imageUrls,
    String? stickerPath,
    DateTime? createdAt,
    MomentType? type,
    List<String>? likedBy,
    List<MomentComment>? comments,
  }) {
    return MomentPost(
      id: id ?? this.id,
      authorId: authorId ?? this.authorId,
      authorName: authorName ?? this.authorName,
      authorAvatarUrl: authorAvatarUrl ?? this.authorAvatarUrl,
      content: content ?? this.content,
      imageUrls: imageUrls ?? this.imageUrls,
      stickerPath: stickerPath ?? this.stickerPath,
      createdAt: createdAt ?? this.createdAt,
      type: type ?? this.type,
      likedBy: likedBy ?? this.likedBy,
      comments: comments ?? this.comments,
    );
  }

  /// 添加点赞
  MomentPost addLike(String userId) {
    if (likedBy.contains(userId)) return this;
    return copyWith(likedBy: [...likedBy, userId]);
  }

  /// 移除点赞
  MomentPost removeLike(String userId) {
    return copyWith(likedBy: likedBy.where((id) => id != userId).toList());
  }

  /// 添加评论
  MomentPost addComment(MomentComment comment) {
    return copyWith(comments: [...comments, comment]);
  }
}

/// 朋友圈类型
enum MomentType {
  text, // 纯文本
  textWithSticker, // 文本 + 表情包
  textWithImages, // 文本 + 图片（预留）
}

/// 朋友圈评论（预留）
class MomentComment {
  final String id;
  final String authorId;
  final String authorName;
  final String content;
  final DateTime createdAt;
  final String? replyToId; // 回复的评论 ID（可选）
  final String? replyToName; // 回复的人名称

  const MomentComment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.content,
    required this.createdAt,
    this.replyToId,
    this.replyToName,
  });

  factory MomentComment.fromJson(Map<String, dynamic> json) {
    return MomentComment(
      id: json['id'] as String,
      authorId: json['author_id'] as String,
      authorName: json['author_name'] as String,
      content: json['content'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      replyToId: json['reply_to_id'] as String?,
      replyToName: json['reply_to_name'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'author_id': authorId,
      'author_name': authorName,
      'content': content,
      'created_at': createdAt.toIso8601String(),
      'reply_to_id': replyToId,
      'reply_to_name': replyToName,
    };
  }
}
