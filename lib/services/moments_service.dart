import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/moment_post.dart';
import 'storage_service.dart';
import 'settings_service.dart';

/// 朋友圈服务
/// 管理朋友圈动态的增删查改
class MomentsService extends ChangeNotifier {
  static final MomentsService _instance = MomentsService._internal();
  factory MomentsService() => _instance;
  MomentsService._internal();

  static MomentsService get instance => _instance;

  static const String _storageKey = 'moments_posts';

  List<MomentPost> _posts = [];

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
      // 按时间倒序
      _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
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
      await _httpPost(
        '$_backendUrl/api/moments/$postId/like?user_id=me&user_name=我',
        {},
      );
    } else {
      await _httpDelete('$_backendUrl/api/moments/$postId/like/me');
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
    await _httpPost('$_backendUrl/api/moments/$postId/comment', {
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
      final response = await _httpGet('$_backendUrl/api/moments');
      if (response != null && response['moments'] != null) {
        final List<dynamic> momentsJson = response['moments'];
        for (final json in momentsJson) {
          try {
            // 检查本地是否已存在
            final existingIndex = _posts.indexWhere((p) => p.id == json['id']);
            if (existingIndex == -1) {
              // 转换后端格式到本地格式
              final post = MomentPost(
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
              _posts.add(post);
            }
          } catch (e) {
            debugPrint('MomentsService: Error parsing backend moment: $e');
          }
        }
        // 按时间倒序
        _posts.sort((a, b) => b.createdAt.compareTo(a.createdAt));
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
      final response = await _httpPost('$_backendUrl/api/moments', {
        'author_id': post.authorId,
        'author_name': post.authorName,
        'content': post.content,
        'image_urls': post.imageUrls,
      });
      return response != null;
    } catch (e) {
      debugPrint('MomentsService: Publish to backend failed: $e');
      return false;
    }
  }

  /// HTTP GET
  Future<Map<String, dynamic>?> _httpGet(String url) async {
    try {
      final uri = Uri.parse(url);
      final request = await HttpClient().getUrl(uri);
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(const Utf8Decoder()).join();
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('HTTP GET error: $e');
    }
    return null;
  }

  /// HTTP POST
  Future<Map<String, dynamic>?> _httpPost(
    String url,
    Map<String, dynamic> data,
  ) async {
    try {
      final uri = Uri.parse(url);
      final request = await HttpClient().postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(data));
      final response = await request.close();
      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = await response.transform(const Utf8Decoder()).join();
        return jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('HTTP POST error: $e');
    }
    return null;
  }

  /// HTTP DELETE
  Future<bool> _httpDelete(String url) async {
    try {
      final uri = Uri.parse(url);
      final request = await HttpClient().deleteUrl(uri);
      final response = await request.close();
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('HTTP DELETE error: $e');
    }
    return false;
  }
}
