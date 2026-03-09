import 'package:flutter/foundation.dart';
import '../models/moment_post.dart';
import 'storage_service.dart';
import 'settings_service.dart';
import 'secure_backend_client.dart';

/// 朋友圈服务
/// 管理朋友圈动态的增删查改
class MomentsService extends ChangeNotifier {
  static final MomentsService _instance = MomentsService._internal();
  factory MomentsService() => _instance;
  MomentsService._internal();

  static MomentsService get instance => _instance;

  static const String _storageKey = 'moments_posts';

  List<MomentPost> _posts = [];

  String _normalizeContent(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool _isLikelyDuplicatePost(MomentPost a, MomentPost b) {
    if (a.authorId != b.authorId) return false;
    if (_normalizeContent(a.content) != _normalizeContent(b.content)) {
      return false;
    }
    if (a.imageUrls.length != b.imageUrls.length) return false;
    for (var i = 0; i < a.imageUrls.length; i++) {
      if (a.imageUrls[i].trim() != b.imageUrls[i].trim()) return false;
    }
    final seconds = a.createdAt.difference(b.createdAt).inSeconds.abs();
    return seconds <= 180;
  }

  void _dedupePostsInMemory() {
    final deduped = <MomentPost>[];
    for (final post in _posts) {
      final exists = deduped.any((kept) => _isLikelyDuplicatePost(kept, post));
      if (!exists) {
        deduped.add(post);
      }
    }
    _posts = deduped;
    _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// 获取所有动态（按时间倒序）
  List<MomentPost> get posts => List.unmodifiable(_posts);

  /// 未读数量（预留）
  int _unreadCount = 0;
  int get unreadCount => _unreadCount;

  /// 初始化
  static Future<void> init() async {
    await instance._loadPosts();
    debugPrint('MomentsService: Loaded ${instance._posts.length} posts');
  }

  /// 加载动态
  Future<void> _loadPosts() async {
    final jsonList = StorageService.getJsonList(_storageKey);
    if (jsonList != null) {
      _posts = jsonList.map((json) => MomentPost.fromJson(json)).toList();
      _dedupePostsInMemory();
    }
  }

  /// 保存动态
  Future<void> _savePosts() async {
    final jsonList = _posts.map((p) => p.toJson()).toList();
    await StorageService.setJsonList(_storageKey, jsonList);
  }

  /// 发布动态（用户）
  Future<MomentPost> publishPost({
    required String content,
    List<String> imageUrls = const [],
    String? stickerPath,
  }) async {
    final type = stickerPath != null
        ? MomentType.textWithSticker
        : imageUrls.isNotEmpty
        ? MomentType.textWithImages
        : MomentType.text;

    final post = MomentPost(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      authorId: 'me',
      authorName: '我',
      content: content,
      imageUrls: imageUrls,
      stickerPath: stickerPath,
      createdAt: DateTime.now(),
      type: type,
    );

    _posts.insert(0, post);
    _dedupePostsInMemory();
    await _savePosts();
    notifyListeners();

    // 自动同步到后端
    await publishToBackend(post);
    debugPrint(
      'MomentsService: Published user post ${post.id} (synced to backend)',
    );
    return post;
  }

  /// 发布动态（AI 角色）- 预留入口
  Future<MomentPost> publishAIPost({
    required String roleId,
    required String roleName,
    String? roleAvatarUrl,
    required String content,
    String? stickerPath,
  }) async {
    final type = stickerPath != null
        ? MomentType.textWithSticker
        : MomentType.text;

    final post = MomentPost(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      authorId: roleId,
      authorName: roleName,
      authorAvatarUrl: roleAvatarUrl,
      content: content,
      stickerPath: stickerPath,
      createdAt: DateTime.now(),
      type: type,
    );

    _posts.insert(0, post);
    _dedupePostsInMemory();
    _unreadCount++;
    await _savePosts();
    notifyListeners();

    // 自动同步到后端
    await publishToBackend(post);
    debugPrint(
      'MomentsService: Published AI post from $roleName (synced to backend)',
    );
    return post;
  }

  /// 删除动态
  Future<void> deletePost(String postId) async {
    _posts.removeWhere((p) => p.id == postId);
    await _savePosts();
    notifyListeners();

    debugPrint('MomentsService: Deleted post $postId');
  }

  /// 点赞/取消点赞
  Future<void> toggleLike(String postId) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    final isLiking = !post.isLikedByMe;
    if (post.isLikedByMe) {
      _posts[index] = post.removeLike('me');
    } else {
      _posts[index] = post.addLike('me');
    }

    await _savePosts();
    notifyListeners();

    // 自动同步到后端
    if (isLiking) {
      await SecureBackendClient.post(
        '$_backendUrl/api/moments/$postId/like?user_id=me&user_name=我',
        {},
      );
    } else {
      await SecureBackendClient.delete(
        '$_backendUrl/api/moments/$postId/like/me',
      );
    }
  }

  /// AI 点赞
  Future<void> aiLike(String postId, String roleId) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];
    if (!post.likedBy.contains(roleId)) {
      _posts[index] = post.addLike(roleId);
      // 如果是用户的帖子被点赞，增加未读
      if (post.authorId == 'me') {
        _unreadCount++;
      }
      await _savePosts();
      notifyListeners();
    }
  }

  /// 添加评论
  Future<void> addComment(
    String postId, {
    required String authorId,
    required String authorName,
    required String content,
    String? replyToId,
    String? replyToName,
  }) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final comment = MomentComment(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      authorId: authorId,
      authorName: authorName,
      content: content,
      createdAt: DateTime.now(),
      replyToId: replyToId,
      replyToName: replyToName,
    );

    final post = _posts[index];
    _posts[index] = post.addComment(comment);
    // 如果是用户的帖子被评论，或被回复，增加未读
    if (post.authorId == 'me' || replyToId == 'me') {
      _unreadCount++;
    }
    await _savePosts();

    // 自动同步到后端
    await SecureBackendClient.post('$_backendUrl/api/moments/$postId/comment', {
      'author_id': authorId,
      'author_name': authorName,
      'content': content,
      'reply_to': replyToName,
    });

    notifyListeners();
  }

  /// 清除未读
  void clearUnread() {
    _unreadCount = 0;
    notifyListeners();
  }

  /// 获取指定用户/角色的动态
  List<MomentPost> getPostsByAuthor(String authorId) {
    return _posts.where((p) => p.authorId == authorId).toList();
  }

  /// 清空所有动态
  Future<void> clearAll() async {
    _posts.clear();
    _unreadCount = 0;
    await _savePosts();
    notifyListeners();
  }

  // ========== 后端同步 ==========

  /// 获取后端 URL
  String get _backendUrl => SettingsService.instance.backendUrl;

  /// 从后端获取朋友圈列表
  Future<bool> fetchFromBackend() async {
    try {
      final secureResponse = await SecureBackendClient.get(
        '$_backendUrl/api/moments',
      );
      final response = secureResponse.isSuccess
          ? secureResponse.data as Map<String, dynamic>?
          : null;
      if (response != null && response['moments'] != null) {
        final List<dynamic> momentsJson = response['moments'];
        for (final json in momentsJson) {
          try {
            final backendPost = MomentPost(
              id: json['id'] ?? '',
              authorId: json['author_id'] ?? '',
              authorName: json['author_name'] ?? '',
              content: json['content'] ?? '',
              imageUrls: List<String>.from(json['image_urls'] ?? []),
              createdAt: DateTime.parse(
                json['created_at'] ?? DateTime.now().toIso8601String(),
              ),
              type: MomentType.text,
              likedBy:
                  (json['liked_by'] as List<dynamic>?)
                      ?.map((l) => l['name']?.toString() ?? '')
                      .toList() ??
                  [],
            );

            final existingById = _posts.indexWhere((p) => p.id == backendPost.id);
            if (existingById != -1) {
              _posts[existingById] = backendPost;
              continue;
            }

            final duplicateIndex = _posts.indexWhere(
              (p) => _isLikelyDuplicatePost(p, backendPost),
            );
            if (duplicateIndex != -1) {
              // Replace local temp-id copy with backend canonical record.
              _posts[duplicateIndex] = backendPost;
            } else {
              _posts.add(backendPost);
            }
          } catch (e) {
            debugPrint('MomentsService: Error parsing backend moment: $e');
          }
        }
        _dedupePostsInMemory();
        await _savePosts();
        notifyListeners();
        debugPrint(
          'MomentsService: Synced ${momentsJson.length} moments from backend',
        );
        return true;
      }
    } catch (e) {
      debugPrint('MomentsService: Backend fetch failed: $e');
    }
    return false;
  }

  /// 发布动态到后端
  Future<bool> publishToBackend(MomentPost post) async {
    try {
      final response =
          await SecureBackendClient.post('$_backendUrl/api/moments', {
            'author_id': post.authorId,
            'author_name': post.authorName,
            'content': post.content,
            'image_urls': post.imageUrls,
          });
      if (response.isSuccess && response.data is Map<String, dynamic>) {
        final payload = response.data as Map<String, dynamic>;
        final serverId = payload['id']?.toString();
        if (serverId != null && serverId.isNotEmpty) {
          final localIndex = _posts.indexWhere((p) => p.id == post.id);
          if (localIndex != -1) {
            final localPost = _posts[localIndex];
            final serverPost = localPost.copyWith(
              id: serverId,
              createdAt:
                  DateTime.tryParse(payload['created_at']?.toString() ?? '') ??
                  localPost.createdAt,
            );

            final duplicateServerIdIndex = _posts.indexWhere(
              (p) => p.id == serverId,
            );
            if (duplicateServerIdIndex != -1 &&
                duplicateServerIdIndex != localIndex) {
              _posts.removeAt(duplicateServerIdIndex);
              final adjustedLocalIndex =
                  duplicateServerIdIndex < localIndex
                  ? localIndex - 1
                  : localIndex;
              _posts[adjustedLocalIndex] = serverPost;
            } else {
              _posts[localIndex] = serverPost;
            }

            _dedupePostsInMemory();
            await _savePosts();
            notifyListeners();
          }
        }
      }
      return response.isSuccess;
    } catch (e) {
      debugPrint('MomentsService: Publish to backend failed: $e');
      return false;
    }
  }
}
