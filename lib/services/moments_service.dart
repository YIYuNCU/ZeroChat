import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import '../models/moment_post.dart';
import 'storage_service.dart';
import 'secure_websocket_client.dart';

/// 朋友圈服务
/// 管理朋友圈动态的增删查改
class MomentsService extends ChangeNotifier {
  static final MomentsService _instance = MomentsService._internal();
  factory MomentsService() => _instance;
  MomentsService._internal();

  static MomentsService get instance => _instance;

  static const String _storageKey = 'moments_posts';
  static const String _hashStorageKey = 'moments_posts_hash';

  List<MomentPost> _posts = [];
  String _localHash = '';

  MomentPost? _parseBackendMoment(Map<String, dynamic> json) {
    try {
      final commentsRaw = json['comments'];
      final comments = <MomentComment>[];
      if (commentsRaw is List) {
        for (final item in commentsRaw) {
          if (item is! Map) continue;
          final map = Map<String, dynamic>.from(item);
          comments.add(
            MomentComment(
              id:
                  map['id']?.toString() ??
                  DateTime.now().millisecondsSinceEpoch.toString(),
              authorId: map['author_id']?.toString() ?? '',
              authorName: map['author_name']?.toString() ?? '',
              content: map['content']?.toString() ?? '',
              createdAt:
                  DateTime.tryParse(map['created_at']?.toString() ?? '') ??
                  DateTime.now(),
              replyToId: map['reply_to_id']?.toString(),
              replyToName: map['reply_to_name']?.toString(),
            ),
          );
        }
      }

      final likedByRaw = json['liked_by'];
      final likedBy = <String>[];
      if (likedByRaw is List) {
        for (final like in likedByRaw) {
          if (like is Map) {
            final id = like['id']?.toString() ?? '';
            final name = like['name']?.toString() ?? '';
            final value = id.isNotEmpty ? id : name;
            if (value.isNotEmpty) likedBy.add(value);
          } else {
            final value = like?.toString() ?? '';
            if (value.isNotEmpty) likedBy.add(value);
          }
        }
      }

      return MomentPost(
        id: json['id']?.toString() ?? '',
        authorId: json['author_id']?.toString() ?? '',
        authorName: json['author_name']?.toString() ?? '',
        content: json['content']?.toString() ?? '',
        imageUrls: List<String>.from(json['image_urls'] ?? const []),
        createdAt:
            DateTime.tryParse(json['created_at']?.toString() ?? '') ??
            DateTime.now(),
        type: MomentType.text,
        likedBy: likedBy,
        comments: comments,
      );
    } catch (e) {
      debugPrint('MomentsService: Error parsing backend moment: $e');
      return null;
    }
  }

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
    _localHash = StorageService.getString(_hashStorageKey) ?? '';
    if (jsonList != null) {
      _posts = jsonList.map((json) => MomentPost.fromJson(json)).toList();
      _dedupePostsInMemory();
      if (_localHash.isEmpty) {
        _localHash = _computePostsHashFromJson(jsonList);
      }
    }
  }

  /// 保存动态
  Future<void> _savePosts({String? hash}) async {
    final jsonList = _posts.map((p) => p.toJson()).toList();
    await StorageService.setJsonList(_storageKey, jsonList);
    _localHash = hash ?? _computePostsHashFromJson(jsonList);
    await StorageService.setString(_hashStorageKey, _localHash);
  }

  String _computePostsHashFromJson(List<Map<String, dynamic>> jsonList) {
    final normalized = jsonEncode(jsonList);
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  Future<String?> _fetchBackendHash({int limit = 50}) async {
    try {
      final response = await SecureWebSocketClient.instance.request(
        'moments_hash',
        {'limit': limit},
      );
      final hash = response['hash']?.toString();
      if (hash != null && hash.isNotEmpty) {
        return hash;
      }
    } catch (e) {
      debugPrint('MomentsService: Fetch backend hash failed: $e');
    }
    return null;
  }

  /// 进入朋友圈时调用：仅在 hash 不一致时同步数据
  Future<bool> syncIfHashMismatch({int limit = 50}) async {
    final backendHash = await _fetchBackendHash(limit: limit);
    if (backendHash == null || backendHash.isEmpty) {
      return false;
    }
    if (_localHash == backendHash) {
      return false;
    }
    return fetchFromBackend(limit: limit, expectedHash: backendHash);
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

    final backendPost = await publishToBackend(post);
    debugPrint(
      'MomentsService: Published user post ${post.id} (synced to backend)',
    );
    return backendPost ?? post;
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

    final backendPost = await publishToBackend(post);
    if (backendPost != null) {
      _unreadCount++;
      notifyListeners();
    }
    debugPrint(
      'MomentsService: Published AI post from $roleName (synced to backend)',
    );
    return backendPost ?? post;
  }

  /// 删除动态
  Future<void> deletePost(String postId) async {
    try {
      await SecureWebSocketClient.instance.request('moments_delete', {
        'post_id': postId,
      });
      await fetchFromBackend();
      debugPrint('MomentsService: Deleted post $postId from backend');
    } catch (e) {
      debugPrint('MomentsService: Delete post failed: $e');
    }
  }

  /// 点赞/取消点赞
  Future<void> toggleLike(String postId) async {
    final index = _posts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final post = _posts[index];

    try {
      if (!post.isLikedByMe) {
        await SecureWebSocketClient.instance.request('moments_like', {
          'post_id': postId,
          'user_id': 'me',
          'user_name': '我',
        });
      } else {
        await SecureWebSocketClient.instance.request('moments_unlike', {
          'post_id': postId,
          'user_id': 'me',
        });
      }
      await fetchFromBackend();
    } catch (e) {
      debugPrint('MomentsService: Toggle like failed: $e');
    }
  }

  /// AI 点赞
  Future<void> aiLike(String postId, String roleId, String roleName) async {
    final post = _posts.where((p) => p.id == postId).firstOrNull;
    if (post == null || post.likedBy.contains(roleId)) return;

    try {
      await SecureWebSocketClient.instance.request('moments_like', {
        'post_id': postId,
        'user_id': roleId,
        'user_name': roleName,
      });
      if (post.authorId == 'me') {
        _unreadCount++;
      }
      await fetchFromBackend();
    } catch (e) {
      debugPrint('MomentsService: AI like failed: $e');
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
    final post = _posts.where((p) => p.id == postId).firstOrNull;
    if (post == null) return;

    try {
      await SecureWebSocketClient.instance.request('moments_comment', {
        'post_id': postId,
        'author_id': authorId,
        'author_name': authorName,
        'content': content,
        'reply_to_id': replyToId,
        'reply_to_name': replyToName,
      });

      if (post.authorId == 'me' || replyToId == 'me') {
        _unreadCount++;
      }
      await fetchFromBackend();
    } catch (e) {
      debugPrint('MomentsService: Add comment failed: $e');
    }
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

  /// 从后端获取朋友圈列表
  Future<bool> fetchFromBackend({int limit = 50, String? expectedHash}) async {
    try {
      final response = await SecureWebSocketClient.instance.request(
        'moments_list',
        {'limit': limit},
      );
      if (response['moments'] != null) {
        final List<dynamic> momentsJson = response['moments'];
        final responseHash = response['hash']?.toString();
        final backendPosts = <MomentPost>[];

        for (final json in momentsJson) {
          if (json is! Map<String, dynamic>) {
            continue;
          }
          final parsed = _parseBackendMoment(json);
          if (parsed != null && parsed.id.isNotEmpty) {
            backendPosts.add(parsed);
          }
        }

        _posts = backendPosts;
        _dedupePostsInMemory();
        await _savePosts(hash: expectedHash ?? responseHash);
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
  Future<MomentPost?> publishToBackend(MomentPost post) async {
    try {
      final payload = await SecureWebSocketClient.instance.request(
        'moments_create',
        {
          'author_id': post.authorId,
          'author_name': post.authorName,
          'content': post.content,
          'image_urls': post.imageUrls,
        },
      );
      final serverPost = _parseBackendMoment(payload);
      await fetchFromBackend();
      return serverPost;
    } catch (e) {
      debugPrint('MomentsService: Publish to backend failed: $e');
      return null;
    }
  }
}
