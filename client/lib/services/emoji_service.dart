import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/emoji_item.dart';
import 'secure_websocket_client.dart';
import 'storage_service.dart';

class EmojiService {
  static EmojiService? _instance;
  static EmojiService get instance => _instance ??= EmojiService._();

  EmojiService._();

  static const _cacheTtl = Duration(seconds: 30);
  final Map<String, List<String>> _categoryCache = {};
  final Map<String, List<EmojiItem>> _emojiCache = {};
  final Map<String, String> _hashCache = {};
  final Map<String, DateTime> _cacheAt = {};

  bool _fresh(String key) =>
      _cacheAt[key] != null &&
      DateTime.now().difference(_cacheAt[key]!) < _cacheTtl;

  void _remember(String key, String hash) {
    if (hash.isNotEmpty) {
      _hashCache[key] = hash;
      unawaited(StorageService.setString('emoji_hash_$key', hash));
    }
    _cacheAt[key] = DateTime.now();
  }

  void _invalidate(String prefix) {
    _hashCache.removeWhere((key, _) => key == prefix || key.startsWith(prefix));
    _cacheAt.removeWhere((key, _) => key == prefix || key.startsWith(prefix));
  }

  void _loadCategoryCache(String key) {
    if (_categoryCache.containsKey(key)) return;
    final raw = StorageService.getJsonList('emoji_cache_$key');
    if (raw == null) return;
    _categoryCache[key] = raw
        .map((item) => item['value']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();
    final hash = StorageService.getString('emoji_hash_$key');
    if (hash != null && hash.isNotEmpty) _hashCache[key] = hash;
  }

  void _loadEmojiCache(String key, {required bool ai}) {
    if (_emojiCache.containsKey(key)) return;
    final raw = StorageService.getJsonList('emoji_cache_$key');
    if (raw == null) return;
    _emojiCache[key] = raw
        .map(
          (item) =>
              ai ? EmojiItem.fromAiJson(item) : EmojiItem.fromUserJson(item),
        )
        .toList();
    final hash = StorageService.getString('emoji_hash_$key');
    if (hash != null && hash.isNotEmpty) _hashCache[key] = hash;
  }

  Future<List<String>> getAiCategories(String roleId) async {
    final key = 'ai_categories:$roleId';
    _loadCategoryCache(key);
    if (_fresh(key) && _categoryCache[key] != null) return _categoryCache[key]!;
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_categories_list',
      {
        'role_id': roleId,
        if (_hashCache[key] != null) 'client_hash': _hashCache[key],
      },
    );
    if (resp['not_modified'] == true && _categoryCache[key] != null) {
      _remember(key, resp['hash']?.toString() ?? '');
      return _categoryCache[key]!;
    }
    final raw = resp['categories'];
    if (raw is! List) {
      return [];
    }
    final value = raw.map((e) => e.toString()).toList();
    _categoryCache[key] = value;
    await StorageService.setJsonList(
      'emoji_cache_$key',
      value.map((e) => {'value': e}).toList(),
    );
    _remember(key, resp['hash']?.toString() ?? '');
    return value;
  }

  Future<bool> addAiCategory(String roleId, String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_category_create',
      {'role_id': roleId, 'category': category},
    );
    _invalidate('ai_categories:$roleId');
    return resp['success'] == true;
  }

  Future<bool> deleteAiCategory(String roleId, String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_category_delete',
      {'role_id': roleId, 'category': category},
    );
    _invalidate('ai_categories:$roleId');
    return resp['success'] == true;
  }

  Future<List<EmojiItem>> getAiEmojis(String roleId, String category) async {
    final key = 'ai_emojis:$roleId:$category';
    _loadEmojiCache(key, ai: true);
    if (_fresh(key) && _emojiCache[key] != null) return _emojiCache[key]!;
    final resp = await SecureWebSocketClient.instance
        .request('role_emojis_list', {
          'role_id': roleId,
          'category': category,
          if (_hashCache[key] != null) 'client_hash': _hashCache[key],
        });
    if (resp['not_modified'] == true && _emojiCache[key] != null) {
      _remember(key, resp['hash']?.toString() ?? '');
      return _emojiCache[key]!;
    }
    final raw = resp['emojis'];
    if (raw is! List) {
      return [];
    }
    final value = raw
        .whereType<Map>()
        .map((e) => EmojiItem.fromAiJson(e.cast<String, dynamic>()))
        .toList();
    _emojiCache[key] = value;
    await StorageService.setJsonList(
      'emoji_cache_$key',
      value.map((e) => e.toJson()).toList(),
    );
    _remember(key, resp['hash']?.toString() ?? '');
    return value;
  }

  Future<EmojiItem?> uploadAiEmoji({
    required String roleId,
    required String category,
    required String filePath,
  }) async {
    final bytes = await File(filePath).readAsBytes();
    final filename = filePath.split(RegExp(r'[\\/]')).last;
    final resp = await SecureWebSocketClient.instance
        .request('role_emoji_upload', {
          'role_id': roleId,
          'category': category,
          'filename': filename,
          'content_base64': base64Encode(bytes),
        });
    if (resp['emoji'] is! Map) {
      return null;
    }
    _invalidate('ai_emojis:$roleId:$category');
    return EmojiItem.fromAiJson((resp['emoji'] as Map).cast<String, dynamic>());
  }

  Future<bool> deleteAiEmoji({
    required String roleId,
    required String category,
    required String filename,
  }) async {
    final resp = await SecureWebSocketClient.instance.request(
      'role_emoji_delete',
      {'role_id': roleId, 'category': category, 'filename': filename},
    );
    _invalidate('ai_emojis:$roleId:$category');
    return resp['success'] == true;
  }

  Future<List<String>> getUserCategories() async {
    const key = 'user_categories';
    _loadCategoryCache(key);
    if (_fresh(key) && _categoryCache[key] != null) return _categoryCache[key]!;
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_categories_list',
      {if (_hashCache[key] != null) 'client_hash': _hashCache[key]},
    );
    if (resp['not_modified'] == true && _categoryCache[key] != null) {
      _remember(key, resp['hash']?.toString() ?? '');
      return _categoryCache[key]!;
    }
    final raw = resp['categories'];
    if (raw is! List) {
      return [];
    }
    final value = raw.map((e) => e.toString()).toList();
    _categoryCache[key] = value;
    await StorageService.setJsonList(
      'emoji_cache_$key',
      value.map((e) => {'value': e}).toList(),
    );
    _remember(key, resp['hash']?.toString() ?? '');
    return value;
  }

  Future<bool> addUserCategory(String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_category_create',
      {'category': category},
    );
    _invalidate('user_categories');
    return resp['success'] == true;
  }

  Future<bool> deleteUserCategory(String category) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_category_delete',
      {'category': category},
    );
    _invalidate('user_categories');
    return resp['success'] == true;
  }

  Future<List<EmojiItem>> getUserEmojis({String? category}) async {
    final key = 'user_emojis:${category ?? '_all'}';
    _loadEmojiCache(key, ai: false);
    if (_fresh(key) && _emojiCache[key] != null) return _emojiCache[key]!;
    final resp = await SecureWebSocketClient.instance
        .request('user_emojis_list', {
          'category': category,
          if (_hashCache[key] != null) 'client_hash': _hashCache[key],
        });
    if (resp['not_modified'] == true && _emojiCache[key] != null) {
      _remember(key, resp['hash']?.toString() ?? '');
      return _emojiCache[key]!;
    }
    final raw = resp['emojis'];
    if (raw is! List) {
      return [];
    }
    final value = raw
        .whereType<Map>()
        .map((e) => EmojiItem.fromUserJson(e.cast<String, dynamic>()))
        .toList();
    _emojiCache[key] = value;
    await StorageService.setJsonList(
      'emoji_cache_$key',
      value.map((e) => e.toJson()).toList(),
    );
    _remember(key, resp['hash']?.toString() ?? '');
    return value;
  }

  Future<EmojiItem?> uploadUserEmoji({
    required String category,
    required String tag,
    required String filePath,
  }) async {
    final bytes = await File(filePath).readAsBytes();
    final filename = filePath.split(RegExp(r'[\\/]')).last;
    final resp = await SecureWebSocketClient.instance
        .request('user_emoji_upload', {
          'category': category,
          'tag': tag,
          'filename': filename,
          'content_base64': base64Encode(bytes),
        });
    if (resp['emoji'] is! Map) {
      return null;
    }
    _invalidate('user_emojis:');
    return EmojiItem.fromUserJson(
      (resp['emoji'] as Map).cast<String, dynamic>(),
    );
  }

  Future<bool> deleteUserEmoji(String emojiId) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_delete',
      {'emoji_id': emojiId},
    );
    _invalidate('user_emojis:');
    return resp['success'] == true;
  }

  Future<String?> resolveUserEmojiTag(String emojiId) async {
    final resp = await SecureWebSocketClient.instance.request(
      'user_emoji_resolve_tag',
      {'emoji_id': emojiId},
    );
    if (resp['found'] != true) {
      return null;
    }
    return resp['tag']?.toString();
  }

  String _normalizeEmojiPath(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('/api/emojis/')) {
      return trimmed.replaceFirst('/api/emojis/', '/files/emojis/');
    }
    if (trimmed.startsWith('/api/user-emojis/')) {
      return trimmed.replaceFirst('/api/user-emojis/', '/files/user-emojis/');
    }
    return trimmed;
  }

  String withBase(String relativeUrl, String baseUrl) {
    final normalized = _normalizeEmojiPath(relativeUrl);
    final uri = Uri.tryParse(normalized);
    final emojiPath = uri?.path ?? normalized;
    final isEmojiPath =
        emojiPath.startsWith('/files/emojis/') ||
        emojiPath.startsWith('/files/user-emojis/');
    final safeBase = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (uri != null && uri.hasScheme && isEmojiPath && safeBase.isNotEmpty) {
      var resolved = '$safeBase$emojiPath';
      if (uri.hasQuery) resolved = '$resolved?${uri.query}';
      if (uri.hasFragment) resolved = '$resolved#${uri.fragment}';
      return resolved;
    }
    if (normalized.startsWith('http://') ||
        normalized.startsWith('https://') ||
        normalized.startsWith('ws-emoji://') ||
        normalized.startsWith('data:') ||
        normalized.startsWith('file://')) {
      return normalized;
    }

    if (safeBase.isEmpty) {
      return normalized;
    }
    if (normalized.startsWith('/')) {
      return '$safeBase$normalized';
    }
    return '$safeBase/$normalized';
  }

  Future<String> getImageUrl(String relativeUrl) async {
    return withBase(relativeUrl, '');
  }
}
